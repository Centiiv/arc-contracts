#!/bin/bash
#
# Wave 3 governance helper for Arc.
#
#   bash governance.sh --mainnet --deploy-timelock
#   bash governance.sh --mainnet --print
#   bash governance.sh --mainnet --verify
#   bash governance.sh --mainnet --schedule
#
# Reads, in this order, whichever exist:
#   .env.upgrade      PRIVATE_KEY, LM_PROXY_ADMIN, LP_PROXY_ADMIN, LM_PROXY, LP_PROXY
#   .env.safe         SAFE_ADDRESS (written by deploy-safe.sh)
#   .env.governance   TIMELOCK (written by --deploy-timelock) and overrides
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

  bash governance.sh --mainnet --deploy-timelock
  bash governance.sh --mainnet --deploy-timelock --dry-run
  bash governance.sh --mainnet --print
  bash governance.sh --mainnet --verify
  bash governance.sh --mainnet --schedule
  bash governance.sh --mainnet            # show configuration

Reads, in this order, whichever exist:
  .env.upgrade      PRIVATE_KEY, LM_PROXY_ADMIN, LP_PROXY_ADMIN, LM_PROXY, LP_PROXY
  .env.safe         SAFE_ADDRESS (written by deploy-safe.sh)
  .env.governance   TIMELOCK (written by --deploy-timelock) and overrides

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

if [ "$NETWORK" = "mainnet" ]; then
  RPC_URL="${ARC_MAINNET_RPC_URL:-https://rpc.mainnet.arc.io}"
  EXPLORER="https://arcscan.app"
else
  RPC_URL="${ARC_TESTNET_RPC_URL:-https://rpc.testnet.arc.io}"
  EXPLORER="https://testnet.arcscan.app"
fi

echo "============================================"
echo "  Arc - Governance (Wave 3)"
echo "  Network: $NETWORK"
echo "  Mode:    $MODE"
echo "============================================"
echo ""

clean() {
  printf '%s' "${!1:-}" | tr -d '\r\n' | xargs 2>/dev/null || true
}

load_env() {
  if [ -f "$1" ]; then
    echo "  Loading $1"
    set -a
    # shellcheck disable=SC1090
    . "./$1"
    set +a
  fi
}

load_env ".env.upgrade"
load_env ".env.safe"
load_env ".env.governance"

PRIVATE_KEY=$(clean PRIVATE_KEY)
SAFE_ADDRESS=$(clean SAFE_ADDRESS)
TIMELOCK=$(clean TIMELOCK)
TIMELOCK_MIN_DELAY=$(clean TIMELOCK_MIN_DELAY)
LM_PROXY=$(clean LM_PROXY)
LP_PROXY=$(clean LP_PROXY)
LM_PROXY_ADMIN=$(clean LM_PROXY_ADMIN)
LP_PROXY_ADMIN=$(clean LP_PROXY_ADMIN)
PROXY=$(clean PROXY)
PROXY_ADMIN=$(clean PROXY_ADMIN)
IMPLEMENTATION=$(clean IMPLEMENTATION)
SALT=$(clean SALT)

unset_empty() {
  local name="$1"
  if [ -z "$(clean "$name")" ]; then
    unset "$name"
  fi
}

unset_empty TIMELOCK
unset_empty TIMELOCK_MIN_DELAY
unset_empty PROXY
unset_empty PROXY_ADMIN
unset_empty IMPLEMENTATION
unset_empty SALT

export PRIVATE_KEY SAFE_ADDRESS TIMELOCK TIMELOCK_MIN_DELAY
export LM_PROXY LP_PROXY LM_PROXY_ADMIN LP_PROXY_ADMIN
export PROXY PROXY_ADMIN IMPLEMENTATION SALT

is_address() { echo "$1" | grep -qE '^0x[0-9a-fA-F]{40}$'; }

require() {
  local name="$1"
  local value
  value=$(clean "$name")
  if [ -z "$value" ]; then
    echo "  Error: $name is required for --$MODE"
    MISSING=1
  fi
}

# ---------------------------------------------------------------- status
if [ "$MODE" = "status" ]; then
  echo "  Configuration:"
  for name in PRIVATE_KEY SAFE_ADDRESS TIMELOCK TIMELOCK_MIN_DELAY \
              LM_PROXY LP_PROXY LM_PROXY_ADMIN LP_PROXY_ADMIN \
              PROXY PROXY_ADMIN IMPLEMENTATION SALT; do
    value=$(clean "$name")
    if [ -z "$value" ]; then
      echo "    $name: (unset)"
    elif [ "$name" = "PRIVATE_KEY" ]; then
      echo "    $name: (set, redacted)"
    else
      echo "    $name: $value"
    fi
  done
  echo ""
  echo "  Modes:"
  echo "    --deploy-timelock   deploy TimelockController (needs PRIVATE_KEY, SAFE_ADDRESS)"
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
    require PRIVATE_KEY
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
  if ! echo "$PRIVATE_KEY" | grep -qE '^0x[0-9a-fA-F]{64}$'; then
    echo "  Error: PRIVATE_KEY must be 0x + 64 hex chars."
    exit 1
  fi

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

  if [ -f ".env.governance" ]; then
    if grep -qE '^TIMELOCK=' .env.governance; then
      sed -i "s|^TIMELOCK=.*|TIMELOCK=$NEW_TIMELOCK|" .env.governance
    else
      printf '\nTIMELOCK=%s\n' "$NEW_TIMELOCK" >> .env.governance
    fi
  else
    cat > .env.governance <<EOF
# Wave 3 governance state (generated by governance.sh)
SAFE_ADDRESS=$SAFE_ADDRESS
TIMELOCK=$NEW_TIMELOCK
TIMELOCK_MIN_DELAY=${TIMELOCK_MIN_DELAY:-7200}
EOF
  fi

  echo ""
  echo "  Timelock: $NEW_TIMELOCK"
  echo "  Saved TIMELOCK=$NEW_TIMELOCK to .env.governance"
  echo ""
  echo "  Next: bash governance.sh --$NETWORK --print"
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
