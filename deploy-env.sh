#!/usr/bin/env bash
# sbenv/originsign-image 兼容入口：source "$SIGSTORE_ENV/deploy-env.sh"。
LAB_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export SIGSTORE_ENV="$LAB_ROOT"
export KUBECONFIG="$LAB_ROOT/.state/kubeconfig"
if [[ -f "$LAB_ROOT/endpoints.env" ]]; then
  # shellcheck disable=SC1091
  source "$LAB_ROOT/endpoints.env"
fi
