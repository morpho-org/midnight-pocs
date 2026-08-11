#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
set -a
. ./.env
set +a
exec anvil \
  --fork-url "$BASE_RPC" \
  ${FORK_BLOCK:+--fork-block-number "$FORK_BLOCK"} \
  --chain-id 8453 \
  --hardfork osaka \
  --auto-impersonate
