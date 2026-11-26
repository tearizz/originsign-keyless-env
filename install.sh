#!/usr/bin/env bash
# 一键从 0 到 1：KinD + Knative/Kourier + Sigstore v1 后端（TUF/Fulcio/CTLog/Rekor/TSA/gettoken）。
#
# 用法:
#   export ACCESS_PORT=18081     # 本机 8080/18080 已被占用时
#   ./install.sh
#
# 可选环境变量:
#   CLUSTER_NAME  默认 sigstore-boot-lab（拒绝使用 "kind"）
#   ACCESS_ADDR   默认 127.0.0.1；远程访问用 0.0.0.0
#   ACCESS_PORT   默认 8080
set -euo pipefail

LAB_ROOT="$(cd "$(dirname "$0")" && pwd)"
STATE="$LAB_ROOT/.state"
KUBECONFIG="$STATE/kubeconfig"
CLUSTER_NAME="${CLUSTER_NAME:-sigstore-boot-lab}"
CTX="kind-$CLUSTER_NAME"
ACCESS_ADDR="${ACCESS_ADDR:-127.0.0.1}"
ACCESS_PORT="${ACCESS_PORT:-8080}"
MAN="$LAB_ROOT/manifests"

if [[ "$ACCESS_ADDR" == "0.0.0.0" || "$ACCESS_ADDR" == "::" ]]; then
  CONNECT_IP="127.0.0.1"
else
  CONNECT_IP="$ACCESS_ADDR"
fi

log()  { printf '\033[1;34m[install]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[error]\033[0m %s\n' "$*" >&2; exit 1; }

have() { command -v "$1" >/dev/null 2>&1; }
need() { have "$1" || die "缺少命令: $1"; }
port_open() { timeout 1 bash -c "exec 3<>/dev/tcp/$1/$2" >/dev/null 2>&1; }

kube() {
  kubectl --kubeconfig "$KUBECONFIG" --context "$CTX" "$@"
}

wait_job() { local ns="$1" name="$2" t="${3:-600}"; log "等待 Job $ns/$name"; kube -n "$ns" wait --for=condition=Complete "job/$name" --timeout="${t}s"; }
wait_ksvc() { local ns="$1" name="$2" t="${3:-300}"; log "等待 ksvc $ns/$name"; kube -n "$ns" wait --for=condition=Ready "ksvc/$name" --timeout="${t}s"; }
wait_secret() { local ns="$1" name="$2" t="${3:-180}" i; for ((i=0;i<t;i++)); do kube -n "$ns" get secret "$name" >/dev/null 2>&1 && return; sleep 1; done; die "Secret $ns/$name 未出现"; }

apply_stripped() {
  local f="$1"
  if have yq; then
    yq e 'del(.spec.template.spec.containers[]?.resources)' "$f" | { grep -v '^{}$' || true; } | kube apply -f -
  else
    kube apply -f "$f"
  fi
}

retry() { local n="$1"; shift; local i; for ((i=0;i<n;i++)); do "$@" && return; sleep 2; done; return 1; }
wait_deployments() { local ns="$1" d; for d in $(kube -n "$ns" get deploy -o name); do kube -n "$ns" rollout status "$d" --timeout=300s; done; }

# ---------- 0. 预检 ----------
log "预检"
need docker; need kind; need kubectl; need curl; need jq; need base64
have yq || warn "未安装 yq：Knative 清单未裁剪 resources，节点资源不足时 Pod 可能 Pending"
docker info >/dev/null 2>&1 || die "docker daemon 不可用"
[[ "$(uname -m)" == "x86_64" || "$(uname -m)" == "amd64" ]] || die "kind 节点镜像固定 linux/amd64"
[[ "$CLUSTER_NAME" != "kind" ]] || die "拒绝使用默认集群名 'kind'（可能是现网）"
if kind get clusters 2>/dev/null | grep -qx "$CLUSTER_NAME"; then
  die "集群 $CLUSTER_NAME 已存在；先运行 ./down.sh，或换 CLUSTER_NAME"
fi
port_open "$CONNECT_IP" "$ACCESS_PORT" && die "端口 $ACCESS_PORT 已被占用；请换 ACCESS_PORT（本机 8080/18080 已被占用）"

# ---------- 1. 集群 ----------
log "创建 KinD 集群 $CLUSTER_NAME（K8s 1.32.8）"
mkdir -p "$STATE"
kind create cluster --name "$CLUSTER_NAME" --config "$MAN/kind-config.yaml" \
  --kubeconfig "$KUBECONFIG" --wait 5m

log "创建 OIDC 匿名发现权限（Fulcio 校验 JWT 需要）"
kube create clusterrolebinding oidc-reviewer \
  --clusterrole=system:service-account-issuer-discovery \
  --group=system:unauthenticated

# ---------- 2. Knative + Kourier ----------
log "安装 Knative Serving CRDs"
kube apply -f "$MAN/knative-v1.18.0/serving-crds.yaml"
kube wait --for=condition=Established --timeout=120s \
  crd/services.serving.knative.dev crd/routes.serving.knative.dev \
  crd/revisions.serving.knative.dev crd/configurations.serving.knative.dev
sleep 8
log "安装 Knative Serving core 与 Kourier"
apply_stripped "$MAN/knative-v1.18.0/serving-core.yaml"
apply_stripped "$MAN/knative-v1.18.0/kourier.yaml"
retry 30 kube patch configmap/config-network -n knative-serving --type merge \
  --patch '{"data":{"ingress.class":"kourier.ingress.networking.knative.dev"}}'
retry 30 kube patch configmap/config-features -n knative-serving --type merge \
  --patch '{"data":{"kubernetes.podspec-fieldref":"enabled","kubernetes.podspec-volumes-emptydir":"enabled","multicontainer":"enabled"}}'
retry 30 kube patch configmap/config-defaults -n knative-serving --type merge \
  --patch '{"data":{"revision-timeout-seconds":"30","container-concurrency":"100"}}'
retry 30 kube patch configmap/config-autoscaler -n knative-serving --type merge \
  --patch '{"data":{"min-scale":"1","max-scale":"1"}}'
wait_deployments knative-serving
wait_deployments kourier-system

# ---------- 3. Sigstore 后端 ----------
log "Trillian"
kube apply -f "$MAN/release-v0.7.33/release-trillian.yaml"
wait_job trillian-system createdb
wait_ksvc trillian-system log-server
wait_ksvc trillian-system log-signer

log "Rekor v1"
kube apply -f "$MAN/release-v0.7.33/release-rekor.yaml"
wait_job rekor-system createsecret 300
wait_job rekor-system createtree
wait_ksvc rekor-system rekor

log "Fulcio"
kube apply -f "$MAN/release-v0.7.33/release-fulcio.yaml"
wait_job fulcio-system createcerts 300
wait_ksvc fulcio-system fulcio
wait_ksvc fulcio-system fulcio-grpc

log "CTLog"
kube apply -f "$MAN/release-v0.7.33/release-ctlog.yaml"
wait_job ctlog-system createtree 300
wait_job ctlog-system createctconfig 300
wait_ksvc ctlog-system ctlog

log "TSA"
kube apply -f "$MAN/release-v0.7.33/release-tsa.yaml"
wait_job tsa-system createcertchain 300
wait_ksvc tsa-system tsa

log "TUF"
kube create namespace tuf-system --dry-run=client -o yaml | kube apply -f -
while read -r ns name; do
  kube -n "$ns" get secret "$name" -o yaml \
    | sed 's/namespace: .*/namespace: tuf-system/' | kube apply -f -
done <<'SECRETS'
ctlog-system ctlog-public-key
fulcio-system fulcio-pub-key
rekor-system rekor-pub-key
tsa-system tsa-cert-chain
SECRETS
kube apply -f "$MAN/release-v0.7.33/release-tuf.yaml"
wait_job tuf-system createsecret 300
wait_ksvc tuf-system tuf
wait_secret tuf-system tuf-root

log "gettoken"
kube apply -f "$MAN/release-v0.7.33/gettoken.yaml"
wait_ksvc default gettoken

# ---------- 4. 访问入口 ----------
log "启动 kourier 端口转发 ${ACCESS_ADDR}:${ACCESS_PORT} -> kourier-internal:80"
nohup kubectl --kubeconfig "$KUBECONFIG" --context "$CTX" \
  -n kourier-system port-forward --address "$ACCESS_ADDR" \
  svc/kourier-internal "${ACCESS_PORT}:80" >"$STATE/kourier.log" 2>&1 &
echo $! > "$STATE/kourier.pid"
for ((i=0;i<60;i++)); do
  port_open "$CONNECT_IP" "$ACCESS_PORT" && break
  sleep 0.5
done
port_open "$CONNECT_IP" "$ACCESS_PORT" || { tail -n 20 "$STATE/kourier.log" >&2; die "kourier 端口转发未就绪"; }

# ---------- 5. 信任根与端点 ----------
log "导出 TUF root 与 endpoints"
rm -rf "$LAB_ROOT/tuf-cache"   # 本次部署的 root 已变化，避免旧缓存混用
kube -n tuf-system get secret tuf-root -o jsonpath='{.data.root}' | base64 -d > "$LAB_ROOT/root.json"
jq -e . "$LAB_ROOT/root.json" >/dev/null
cat > "$LAB_ROOT/endpoints.env" <<ENV
export SIGSTORE_ENV="$LAB_ROOT"
export ACCESS_ADDR="$ACCESS_ADDR"
export ACCESS_PORT="$ACCESS_PORT"
export TUF_MIRROR="http://tuf.tuf-system.svc:${ACCESS_PORT}"
export FULCIO_URL="http://fulcio.fulcio-system.svc:${ACCESS_PORT}"
export REKOR_URL="http://rekor.rekor-system.svc:${ACCESS_PORT}"
export CTLOG_URL="http://ctlog.ctlog-system.svc:${ACCESS_PORT}"
export TSA_URL="http://tsa.tsa-system.svc:${ACCESS_PORT}"
export ISSUER_URL="http://gettoken.default.svc:${ACCESS_PORT}"
export TUF_ROOT="$LAB_ROOT/tuf-cache"
export ROOT_JSON="$LAB_ROOT/root.json"
ENV
chmod 0644 "$LAB_ROOT/root.json" "$LAB_ROOT/endpoints.env"

HOST_IP="$ACCESS_ADDR"
[[ "$ACCESS_ADDR" == "0.0.0.0" || "$ACCESS_ADDR" == "::" ]] && HOST_IP="<SERVER_IP>"
cat <<HOSTS

把下面内容加到客户端 /etc/hosts（同机可用 127.0.0.1）：
$HOST_IP tuf.tuf-system.svc
$HOST_IP fulcio.fulcio-system.svc
$HOST_IP rekor.rekor-system.svc
$HOST_IP ctlog.ctlog-system.svc
$HOST_IP tsa.tsa-system.svc
$HOST_IP gettoken.default.svc

继续：
  source endpoints.env
  ./smoke-test.sh
HOSTS

"$LAB_ROOT/smoke-test.sh"
