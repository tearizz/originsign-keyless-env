#!/usr/bin/env bash
# 环境自检（curl + jq，不需要 originsign）；--e2e 额外跑 keyless sign/verify。
set -euo pipefail

LAB_ROOT="$(cd "$(dirname "$0")" && pwd)"
[[ -f "$LAB_ROOT/endpoints.env" ]] || { echo "缺少 endpoints.env；先运行 ./install.sh" >&2; exit 1; }
# shellcheck disable=SC1091
source "$LAB_ROOT/endpoints.env"

CONNECT_IP="$ACCESS_ADDR"
[[ "$ACCESS_ADDR" == "0.0.0.0" || "$ACCESS_ADDR" == "::" ]] && CONNECT_IP="127.0.0.1"

curl_svc() { # host path [curl options...]
  local host="$1" path="$2"
  shift 2
  curl -sS -m 20 --resolve "$host:$ACCESS_PORT:$CONNECT_IP" "$@" \
    "http://$host:$ACCESS_PORT$path"
}
jwt_claims() { cut -d. -f2 | tr '_-' '/+' | awk '{l=length($0)%4; if(l==2)$0=$0"=="; else if(l==3)$0=$0"="; print}' | base64 -d; }

FAILED=0
ok() { printf '  ok   %s\n' "$*"; }
bad() { printf '  FAIL %s\n' "$*" >&2; FAILED=1; }

root="$(curl_svc tuf.tuf-system.svc /root.json || true)"
targets="$(curl_svc tuf.tuf-system.svc /targets.json || true)"
jq -e '.signed._type=="root"' >/dev/null <<<"$root" && ok "TUF root.json" || bad "TUF root.json"
[[ -f "$ROOT_JSON" ]] && cmp -s <(jq -S . "$ROOT_JSON") <(jq -S . <<<"$root") \
  && ok "root.json 与 TUF 服务一致" || bad "root.json 与 TUF 服务不一致"
jq -e '.signed._type=="targets"' >/dev/null <<<"$targets" && ok "TUF targets.json" || bad "TUF targets.json"
for t in fulcio_v1.crt.pem ctfe.pub rekor.pub trusted_root.json; do
  jq -e --arg t "$t" '.signed.targets[$t] != null' >/dev/null <<<"$targets" \
    && ok "target $t" || bad "target $t 缺失"
done

[[ "$(curl_svc fulcio.fulcio-system.svc /api/v1/rootCert -w '%{http_code}' -o /tmp/fulcio-root.$$ || true)" == "200" ]] \
  && ok "Fulcio rootCert" || bad "Fulcio rootCert"
curl_svc fulcio.fulcio-system.svc /healthz | jq -e '.status=="SERVING"' >/dev/null \
  && ok "Fulcio healthz" || bad "Fulcio healthz"

curl_svc rekor.rekor-system.svc /api/v1/log/publicKey | grep -q 'BEGIN PUBLIC KEY' \
  && ok "Rekor v1 publicKey" || bad "Rekor v1 publicKey"

curl_svc ctlog.ctlog-system.svc /sigstorescaffolding/ct/v1/get-sth | jq -e '.tree_size != null' >/dev/null \
  && ok "CTLog get-sth" || bad "CTLog get-sth"

[[ "$(curl_svc tsa.tsa-system.svc /api/v1/timestamp -o /dev/null -w '%{http_code}' || true)" == "405" ]] \
  && ok "TSA 在线（405）" || bad "TSA"

tok="$(curl_svc gettoken.default.svc / || true)"
claims="$(printf '%s' "$tok" | jwt_claims 2>/dev/null || true)"
jq -e '.iss=="https://kubernetes.default.svc.cluster.local"' >/dev/null <<<"$claims" \
  && ok "OIDC issuer" || bad "OIDC issuer"
jq -e '.sub=="system:serviceaccount:default:default"' >/dev/null <<<"$claims" \
  && ok "OIDC sub" || bad "OIDC sub"
jq -e '.aud | index("sigstore") != null' >/dev/null <<<"$claims" \
  && ok "OIDC audience" || bad "OIDC audience"

if [[ "${1:-}" == "--e2e" ]]; then
  BIN="${ORIGINSIGN_BIN:-$LAB_ROOT/bin/originsign}"
  [[ -x "$BIN" ]] || BIN="$(command -v originsign || true)"
  [[ -x "$BIN" ]] || { echo "未找到 originsign；设置 ORIGINSIGN_BIN" >&2; exit 1; }
  for h in tuf.tuf-system.svc fulcio.fulcio-system.svc rekor.rekor-system.svc \
           ctlog.ctlog-system.svc tsa.tsa-system.svc gettoken.default.svc; do
    getent hosts "$h" >/dev/null || { echo "无法解析 $h：先加 /etc/hosts" >&2; exit 1; }
  done
  OUT="$LAB_ROOT/out/e2e-$(date +%s)"; mkdir -p "$OUT"
  [[ -d /opt/tongsuo/lib ]] && export LD_LIBRARY_PATH="/opt/tongsuo/lib:${LD_LIBRARY_PATH:-}"
  "$BIN" init --mirror "$TUF_MIRROR" --root "$ROOT_JSON" --root-cache-dir "$OUT/tuf-cache"
  idtoken="$(curl -sS -m 10 "$ISSUER_URL")"
  "$BIN" sign --artifact memory --data "smoke" --sign-tool go-crypto --algo ecdsa \
    --id-token "$idtoken" --cert-mgr fulcio --cert-mgr-url "$FULCIO_URL" \
    --sign-mgr rekor --sign-mgr-url "$REKOR_URL" --save --output "$OUT"
  "$BIN" verify --artifact memory --data "smoke" --sign-tool go-crypto --algo ecdsa \
    --cert "$OUT/certificate.json" --signature "$(cat "$OUT/artifact.sig")" \
    --cert-mgr fulcio --cert-mgr-url "$FULCIO_URL" --sign-mgr rekor --sign-mgr-url "$REKOR_URL"
  ok "OriginSign keyless E2E（$OUT）"
fi

rm -f /tmp/fulcio-root.$$
[[ "$FAILED" == "0" ]] || { echo "SMOKE TEST FAILED" >&2; exit 1; }
echo "SMOKE TEST PASSED"
