#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"

if [[ -f .env ]]; then
  set -a
  source .env
  set +a
fi

: "${BASE_RPC:?Set BASE_RPC in the environment or copy .env.example to .env}"

args=(
  --fork-url "$BASE_RPC"
  --chain-id 8453
  --hardfork osaka
  --auto-impersonate
)

if [[ -n "${FORK_BLOCK:-}" ]]; then
  args+=(--fork-block-number "$FORK_BLOCK")
fi

exec anvil "${args[@]}"
