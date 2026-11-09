#!/bin/bash
#
# Wave 3 governance helper for Arc.
#
#   bash scripts/governance.sh --mainnet --deploy-timelock
#   bash scripts/governance.sh --mainnet --print
#   bash scripts/governance.sh --mainnet --verify
#   bash scripts/governance.sh --mainnet --schedule
#
# Reads .env.test or .env.main (selected by the network flag). The file holds:
#   PRIVATE_KEY / GOVERNANCE_KEY   timelock deployer (gas only)
#   SAFE_ADDRESS                   written by scripts/deploy-safe.sh
#   LM_PROXY, LP_PROXY, LM_PROXY_ADMIN, LP_PROXY_ADMIN
#   TIMELOCK, TIMELOCK_MIN_DELAY   written by --deploy-timelock
#
# For --schedule, set:
#   PROXY=0x...            # the proxy being upgraded
#   PROXY_ADMIN=0x...      # its ProxyAdmin
#   IMPLEMENTATION=0x...   # the new implementation
#   SALT=0x...             # optional, defaults to keccak256("centiiv-upgrade")
#
# The timelock is deployed with admin = address(0): no external key can change
# roles or the delay without passing the 2-hour window itself.

export PATH="$HOME/.foundry/bin:$PATH"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_ROOT" || exit 1

# shellcheck source=scripts/load-env.sh
. "$SCRIPT_DIR/load-env.sh"

NETWORK="testnet"
MODE="status"
DRY_RUN=0

for arg in "$@"; do
  case $arg in
    --mainnet|--network=mainnet) NETWORK="mainnet" ;;
    --testnet|--network=testnet) NETWORK="testnet" ;;
    --deploy-timelock) MODE="deploy-timelock" ;;
    --print) MODE="print" ;;
    --verify) MODE="verify" ;;
    --schedule) MODE="schedule" ;;
    --dry-run) DRY_RUN=1 ;;
    -h|--help)
      cat <<'USAGE'
Wave 3 governance helper for Arc.

  bash scripts/governance.sh --mainnet --deploy-timelock
  bash scripts/governance.sh --mainnet --deploy-timelock --dry-run
  bash scripts/governance.sh --mainnet --print
  bash scripts/governance.sh --mainnet --verify
  bash scripts/governance.sh --mainnet --schedule
  bash scripts/governance.sh --mainnet            # show configuration

Reads .env.test or .env.main (selected by --mainnet / --testnet):

  PRIVATE_KEY / GOVERNANCE_KEY   timelock deployer (gas only)
  SAFE_ADDRESS                   written by scripts/deploy-safe.sh
  LM_PROXY, LP_PROXY, LM_PROXY_ADMIN, LP_PROXY_ADMIN
  TIMELOCK, TIMELOCK_MIN_DELAY

For --schedule, set:
  PROXY=0x...            # the proxy being upgraded
  PROXY_ADMIN=0x...      # its ProxyAdmin
  IMPLEMENTATION=0x...   # the new implementation
  SALT=0x...             # optional

The timelock is deployed with admin = address(0): no external key can change
roles or the delay without passing the 2-hour window itself.
USAGE
      exit 0
      ;;
  esac
done

arc_resolve_env
arc_set_network

echo "============================================"
echo "  Arc - Governance (Wave 3)"
echo "  Network: $NETWORK"
echo "  Env:     $ENV_FILE"
echo "  Mode:    $MODE"
echo "============================================"
echo ""

if [ -f "$ENV_FILE" ]; then
  echo "  Loading $ENV_FILE"
  arc_load_env || { echo "  Error: could not load $ENV_FILE."; exit 1; }
  arc_clean \
    PRIVATE_KEY ADMIN1_KEY GOVERNANCE_KEY \
    SAFE_ADDRESS \
    TIMELOCK TIMELOCK_MIN_DELAY \
    LM_PROXY LP_PROXY LM_PROXY_ADMIN LP_PROXY_ADMIN \
    PROXY PROXY_ADMIN IMPLEMENTATION SALT RPC_URL
  arc_set_network
else
  echo "  Error: $ENV_FILE not found."
  echo "  Create it from .env.example, then run scripts/deploy-safe.sh first."
  exit 1
fi

unset_empty() {
  local name="$1"
  if [ -z "$(printf '%s' "${!name:-}")" ]; then
    unset "$name"
  fi
}

unset_empty TIMELOCK
unset_empty TIMELOCK_MIN_DELAY
unset_empty PROXY
unset_empty PROXY_ADMIN
unset_empty IMPLEMENTATION
unset_empty SALT

GOVERNANCE_KEY="${GOVERNANCE_KEY:-${PRIVATE_KEY:-$ADMIN1_KEY}}"

export PRIVATE_KEY SAFE_ADDRESS TIMELOCK TIMELOCK_MIN_DELAY
export LM_PROXY LP_PROXY LM_PROXY_ADMIN LP_PROXY_ADMIN
export PROXY PROXY_ADMIN IMPLEMENTATION SALT
export GOVERNANCE_KEY

is_address() { echo "$1" | grep -qE '^0x[0-9a-fA-F]{40}$'; }

require() {
  local name="$1"
  local value
  value=$(printf '%s' "${!name:-}")
  if [ -z "$value" ]; then
    echo "  Error: $name is required for --$MODE (set it in $ENV_FILE)"
    MISSING=1
  fi
}

# ---------------------------------------------------------------- status
if [ "$MODE" = "status" ]; then
  echo "  Configuration:"
  for name in PRIVATE_KEY GOVERNANCE_KEY SAFE_ADDRESS TIMELOCK TIMELOCK_MIN_DELAY \
              LM_PROXY LP_PROXY LM_PROXY_ADMIN LP_PROXY_ADMIN \
              PROXY PROXY_ADMIN IMPLEMENTATION SALT; do
    value=$(printf '%s' "${!name:-}")
    if [ -z "$value" ]; then
      echo "    $name: (unset)"
    elif [ "$name" = "PRIVATE_KEY" ] || [ "$name" = "GOVERNANCE_KEY" ]; then
      echo "    $name: (set, redacted)"
    else
      echo "    $name: $value"
    fi
  done
  echo ""
  echo "  Modes:"
  echo "    --deploy-timelock   deploy TimelockController (needs a funded key, SAFE_ADDRESS)"
  echo "    --print             print every Safe transaction calldata"
  echo "    --verify            read owners/threshold/admin/owners on-chain"
  echo "    --schedule          print the scheduleBatch calldata for an upgrade"
  exit 0
fi

# ---------------------------------------------------------------- validate
MISSING=0
require SAFE_ADDRESS

case "$MODE" in
  deploy-timelock)
    if [ -z "${GOVERNANCE_KEY:-}" ]; then
      echo "  Error: GOVERNANCE_KEY (or PRIVATE_KEY / ADMIN1_KEY) is required for --deploy-timelock"
      MISSING=1
    fi
    ;;
  print|verify)
    require LM_PROXY
    require LP_PROXY
    require LM_PROXY_ADMIN
    require LP_PROXY_ADMIN
    ;;
  schedule)
    require TIMELOCK
    require PROXY
    require PROXY_ADMIN
    require IMPLEMENTATION
    ;;
esac

if [ "$MISSING" -ne 0 ]; then
  exit 1
fi
if ! is_address "$SAFE_ADDRESS"; then
  echo "  Error: SAFE_ADDRESS is not a valid address."
  exit 1
fi

# ---------------------------------------------------------------- deploy timelock
if [ "$MODE" = "deploy-timelock" ]; then
  if ! echo "$GOVERNANCE_KEY" | grep -qE '^0x[0-9a-fA-F]{64}$'; then
    echo "  Error: GOVERNANCE_KEY must be 0x + 64 hex chars."
    exit 1
  fi
  PRIVATE_KEY="$GOVERNANCE_KEY"
  export PRIVATE_KEY

  DEPLOYER=$(cast wallet address "$PRIVATE_KEY" 2>&1) || true
  BALANCE=$(cast balance "$DEPLOYER" --rpc-url "$RPC_URL" 2>&1) || true
  echo "  Deployer: $DEPLOYER"
  echo "  Balance:  $BALANCE (wei, native USDC gas)"
  echo ""
  if [ "$BALANCE" = "0" ]; then
    if [ "$DRY_RUN" = "1" ]; then
      echo "  Warning: zero balance; a dry run may still fail gas estimation."
    else
      echo "  !!! NO GAS !!! Fund $DEPLOYER on Arc $NETWORK."
      exit 1
    fi
  fi

  echo "[1/2] Building..."
  forge build --force >/dev/null || { echo "  Build failed."; exit 1; }

  echo "[2/2] Deploying TimelockController (minDelay=${TIMELOCK_MIN_DELAY:-7200}s)..."
  echo ""
  OUT=$(mktemp)
  FORGE_ARGS=(--sig "run()" --rpc-url "$RPC_URL" --private-key "$PRIVATE_KEY" -vvv)
  if [ "$DRY_RUN" = "0" ]; then
    FORGE_ARGS+=(--broadcast)
  fi
  forge script script/Governance.s.sol:GovernanceScript "${FORGE_ARGS[@]}" 2>&1 | tee "$OUT"
  STATUS=${PIPESTATUS[0]}
  NEW_TIMELOCK=$(grep -oE 'TimelockController: 0x[0-9a-fA-F]{40}' "$OUT" | tail -1 | grep -oE '0x[0-9a-fA-F]{40}' || true)
  rm -f "$OUT"

  if [ "$STATUS" -ne 0 ] || [ -z "$NEW_TIMELOCK" ]; then
    echo "  Timelock deployment FAILED."
    exit 1
  fi

  if [ "$DRY_RUN" = "1" ]; then
    echo ""
    echo "  Dry run: TimelockController would be $NEW_TIMELOCK"
    echo "  TIMELOCK was not persisted."
    exit 0
  fi

  if grep -qE '^TIMELOCK=' "$ENV_FILE"; then
    sed -i "s|^TIMELOCK=.*|TIMELOCK=$NEW_TIMELOCK|" "$ENV_FILE"
  else
    printf '\nTIMELOCK=%s\n' "$NEW_TIMELOCK" >> "$ENV_FILE"
  fi
  if ! grep -qE '^TIMELOCK_MIN_DELAY=' "$ENV_FILE"; then
    printf 'TIMELOCK_MIN_DELAY=%s\n' "${TIMELOCK_MIN_DELAY:-7200}" >> "$ENV_FILE"
  fi

  echo ""
  echo "  Timelock: $NEW_TIMELOCK"
  echo "  Saved TIMELOCK=$NEW_TIMELOCK to $ENV_FILE"
  echo ""
  echo "  Next: bash scripts/governance.sh --$NETWORK --print"
  exit 0
fi

# ---------------------------------------------------------------- verify
if [ "$MODE" = "verify" ]; then
  forge script script/Governance.s.sol:GovernanceScript \
    --sig "verify()" \
    --rpc-url "$RPC_URL" \
    -vv
  echo ""
  echo "  Safe:     $EXPLORER/address/$SAFE_ADDRESS"
  [ -n "$TIMELOCK" ] && echo "  Timelock: $EXPLORER/address/$TIMELOCK"
  exit 0
fi

# ---------------------------------------------------------------- schedule
if [ "$MODE" = "schedule" ]; then
  forge script script/Governance.s.sol:GovernanceScript \
    --sig "printUpgradeSchedule()" \
    --rpc-url "$RPC_URL" \
    -vv
  exit 0
fi

# ---------------------------------------------------------------- print
if [ "$MODE" = "print" ]; then
  OUT_FILE="governance-calldata.txt"
  : > "$OUT_FILE"

  run_print() {
    local sig="$1"
    echo "" | tee -a "$OUT_FILE"
    echo "################################################################" | tee -a "$OUT_FILE"
    echo "# $sig" | tee -a "$OUT_FILE"
    echo "################################################################" | tee -a "$OUT_FILE"
    forge script script/Governance.s.sol:GovernanceScript \
      --sig "$sig" \
      --rpc-url "$RPC_URL" \
      -vv 2>&1 | tee -a "$OUT_FILE"
  }

  echo "  Writing all calldata to $OUT_FILE"
  echo ""
  echo "  Step 1: EOA -> Safe ProxyAdmin transfers (send from the old admin1 EOA)"
  run_print "printProxyAdminTransfers()"

  echo ""
  echo "  Step 2: admin1 rotation (EOA proposes, Safe accepts)"
  run_print "printAdmin1Rotation()"

  if [ -n "$TIMELOCK" ]; then
    echo ""
    echo "  Step 3: Safe -> Timelock ProxyAdmin transfers (one Safe batch)"
    run_print "printTimelockTransfers()"
  else
    echo ""
    echo "  Skipping Safe -> Timelock transfers: TIMELOCK is not set."
    echo "  Run --deploy-timelock first."
  fi

  if [ -n "$TIMELOCK" ] && [ -n "$PROXY" ] && [ -n "$PROXY_ADMIN" ] && [ -n "$IMPLEMENTATION" ]; then
    echo ""
    echo "  Step 4: schedule a timelocked upgrade"
    run_print "printUpgradeSchedule()"
  else
    echo ""
    echo "  Skipping upgrade schedule: set TIMELOCK, PROXY, PROXY_ADMIN and IMPLEMENTATION."
  fi

  echo ""
  echo "============================================"
  echo "  Calldata written to $OUT_FILE"
  echo "============================================"
  echo "  Paste each 'to / value / data' into Safe{Wallet} -> Transaction Builder."
  echo "  The two ProxyAdmin transfers to the Safe are EOA transactions, not Safe"
  echo "  transactions: send them from the original admin1 EOA."
  exit 0
fi
