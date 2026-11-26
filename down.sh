#!/usr/bin/env bash
# 停止端口转发并删除本实验室 KinD 集群；--purge 同时清理生成的 root.json/endpoints.env。
set -euo pipefail

LAB_ROOT="$(cd "$(dirname "$0")" && pwd)"
STATE="$LAB_ROOT/.state"
CLUSTER_NAME="${CLUSTER_NAME:-sigstore-boot-lab}"
[[ "$CLUSTER_NAME" != "kind" ]] || { echo "拒绝删除默认集群名 'kind'" >&2; exit 1; }

if [[ -f "$STATE/kourier.pid" ]]; then
  pid="$(cat "$STATE/kourier.pid")"
  kill "$pid" 2>/dev/null || true
  rm -f "$STATE/kourier.pid"
fi

if command -v kind >/dev/null 2>&1 && kind get clusters 2>/dev/null | grep -qx "$CLUSTER_NAME"; then
  echo "删除 KinD 集群 $CLUSTER_NAME"
  kind delete cluster --name "$CLUSTER_NAME"
else
  echo "KinD 集群 $CLUSTER_NAME 不存在，跳过"
fi

if [[ "${1:-}" == "--purge" ]]; then
  for p in .state root.json endpoints.env out tuf-cache; do
    [[ -e "$LAB_ROOT/$p" ]] || continue
    resolved="$(realpath -m "$LAB_ROOT/$p")"
    case "$resolved" in "$LAB_ROOT"/*) rm -rf -- "$resolved" ;; *) echo "拒绝删除 $resolved" >&2; exit 1 ;; esac
  done
fi
echo "完成"
