#!/usr/bin/env bash
# Storage-layout regression gate for the upgradeable proxies.
#
#   ./scripts/check-storage-layout.sh
#
# `.storage-layout/<Contract>.prev.json` is the layout of the last released
# implementation. Update it only after that implementation has been retired,
# i.e. immediately after a successful upgrade.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

FORGE="${FORGE:-forge}"
TMP="${TMPDIR:-/tmp}"

for contract in LiquidityProvider LiquidityManager; do
    next="${TMP}/${contract}.storage-next.json"
    "$FORGE" inspect "$contract" storageLayout --json > "$next"
    printf '%-20s ' "$contract"
    python3 scripts/storage_layout_check.py ".storage-layout/${contract}.prev.json" "$next"
done
