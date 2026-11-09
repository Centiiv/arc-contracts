#!/bin/bash
#
# Deploy a 2-of-3 Safe on Arc through the canonical Safe v1.4.1 factory.
#
#   bash scripts/deploy-safe.sh --mainnet
#   bash scripts/deploy-safe.sh --testnet
#   bash scripts/deploy-safe.sh --mainnet --dry-run     # simulate, do not broadcast
#   bash scripts/deploy-safe.sh --mainnet --verify-only # verify an existing SAFE_ADDRESS
#
# Reads .env.test or .env.main (selected by the network flag):
#
#   PRIVATE_KEY=0x...        # deployer only; pays gas, is NOT a Safe owner
#   SAFE_ADMIN1=0x...        # defaults to ADMIN1
#   SAFE_ADMIN2=0x...        # defaults to ADMIN2
#   SAFE_RECOVERY=0x...      # defaults to RECOVERY
#   # optional:
#   SAFE_THRESHOLD=2
#   SAFE_SINGLETON=0x41675C099F32341bf84BFc5382aF534df5C7461a
#   SAFE_PROXY_FACTORY=0x4e1DCf7AD4e460CfD30791CCC4F9c8a4f820ec67
#   SAFE_FALLBACK_HANDLER=0xfd0732Dc9E303f09fCEf3a7388Ad10A83459Ec99
#   SAFE_SALT_NONCE=0
#   SAFE_ADDRESS=            # filled in by this script after a successful deploy
#
# The Safe singleton/factory are already deployed on Arc. This script only
# creates the per-Safe proxy. It writes SAFE_ADDRESS back to the env file.

export PATH="$HOME/.foundry/bin:$PATH"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_ROOT" || exit 1

# shellcheck source=scripts/load-env.sh
. "$SCRIPT_DIR/load-env.sh"

NETWORK="testnet"
DRY_RUN=0
VERIFY_ONLY=0

for arg in "$@"; do
  case $arg in
    --mainnet|--network=mainnet) NETWORK="mainnet" ;;
    --testnet|--network=testnet) NETWORK="testnet" ;;
    --dry-run) DRY_RUN=1 ;;
    --verify-only) VERIFY_ONLY=1 ;;
    -h|--help)
      cat <<'USAGE'
Deploy a 2-of-3 Safe on Arc through the canonical Safe v1.4.1 factory.

  bash scripts/deploy-safe.sh --mainnet
  bash scripts/deploy-safe.sh --testnet
  bash scripts/deploy-safe.sh --mainnet --dry-run
  bash scripts/deploy-safe.sh --mainnet --verify-only

Reads .env.test or .env.main:

  PRIVATE_KEY=0x...        # deployer only; pays gas, is NOT a Safe owner
  SAFE_ADMIN1=0x...        # defaults to ADMIN1
  SAFE_ADMIN2=0x...        # defaults to ADMIN2
  SAFE_RECOVERY=0x...      # defaults to RECOVERY
  SAFE_THRESHOLD=2         # optional; 2 or 3
  SAFE_SINGLETON=0x...     # optional; canonical default is used
  SAFE_PROXY_FACTORY=0x... # optional; canonical default is used
  SAFE_FALLBACK_HANDLER=0x...
  SAFE_SALT_NONCE=0
  SAFE_ADDRESS=            # filled in after a successful deploy

The Safe singleton/factory are already deployed on Arc. This script creates
the per-Safe proxy and writes SAFE_ADDRESS back to the env file.
USAGE
      exit 0
      ;;
  esac
done

arc_resolve_env
arc_set_network

echo "============================================"
echo "  Arc - Safe Deployment"
echo "  Network: $NETWORK"
echo "  Env:     $ENV_FILE"
echo "============================================"
echo ""

if [ -f "$ENV_FILE" ]; then
  echo "  Loading $ENV_FILE"
  arc_load_env || { echo "  Error: could not load $ENV_FILE."; exit 1; }
  arc_clean \
    PRIVATE_KEY ADMIN1 ADMIN2 RECOVERY \
    SAFE_ADMIN1 SAFE_ADMIN2 SAFE_RECOVERY SAFE_ADDRESS \
    SAFE_THRESHOLD SAFE_SALT_NONCE \
    SAFE_SINGLETON SAFE_PROXY_FACTORY SAFE_FALLBACK_HANDLER \
    RPC_URL
  arc_set_network
else
  echo "  Error: $ENV_FILE not found."
  echo ""
  echo "  Create it from .env.example:"
  echo "    cp .env.example $ENV_FILE"
  echo ""
  echo "  Then fill in:"
  echo "    PRIVATE_KEY=0x...      # deployer, gas only"
  echo "    SAFE_ADMIN1=0x..."
  echo "    SAFE_ADMIN2=0x..."
  echo "    SAFE_RECOVERY=0x..."
  exit 1
fi

SAFE_ADMIN1="${SAFE_ADMIN1:-$ADMIN1}"
SAFE_ADMIN2="${SAFE_ADMIN2:-$ADMIN2}"
SAFE_RECOVERY="${SAFE_RECOVERY:-$RECOVERY}"

unset_empty() {
  local name="$1"
  if [ -z "$(printf '%s' "${!name:-}")" ]; then
    unset "$name"
  fi
}

unset_empty SAFE_THRESHOLD
unset_empty SAFE_SALT_NONCE
unset_empty SAFE_SINGLETON
unset_empty SAFE_PROXY_FACTORY
unset_empty SAFE_FALLBACK_HANDLER

export PRIVATE_KEY SAFE_ADMIN1 SAFE_ADMIN2 SAFE_RECOVERY
export SAFE_THRESHOLD SAFE_SALT_NONCE
export SAFE_SINGLETON SAFE_PROXY_FACTORY SAFE_FALLBACK_HANDLER

is_address() { echo "$1" | grep -qE '^0x[0-9a-fA-F]{40}$'; }

# ---------------------------------------------------------------- verify-only
if [ "$VERIFY_ONLY" = "1" ]; then
  if ! is_address "$SAFE_ADDRESS"; then
    echo "  Error: SAFE_ADDRESS is required for --verify-only"
    exit 1
  fi
  echo "[1/1] Verifying Safe $SAFE_ADDRESS ..."
  echo ""
  SAFE_ADDRESS="$SAFE_ADDRESS" forge script script/DeploySafe.s.sol:DeploySafeScript \
    --sig "verify()" \
    --rpc-url "$RPC_URL" \
    -vv
  echo ""
  echo "  Explorer: $EXPLORER/address/$SAFE_ADDRESS"
  exit 0
fi

# ---------------------------------------------------------------- validate
echo "[1/4] Validating configuration..."
errors=0

if ! echo "$PRIVATE_KEY" | grep -qE '^0x[0-9a-fA-F]{64}$'; then
  echo "  Error: PRIVATE_KEY must be 0x + 64 hex chars."
  errors=1
fi
for name in SAFE_ADMIN1 SAFE_ADMIN2 SAFE_RECOVERY; do
  value=$(printf '%s' "${!name:-}")
  if ! is_address "$value"; then
    echo "  Error: $name must be a 0x address."
    errors=1
  fi
done
if [ "${SAFE_ADMIN1:-}" = "${SAFE_ADMIN2:-}" ] ||
   [ "${SAFE_ADMIN1:-}" = "${SAFE_RECOVERY:-}" ] ||
   [ "${SAFE_ADMIN2:-}" = "${SAFE_RECOVERY:-}" ]; then
  echo "  Error: the three owners must be distinct."
  errors=1
fi
if [ -n "${SAFE_THRESHOLD:-}" ] && [ "$SAFE_THRESHOLD" != "2" ] && [ "$SAFE_THRESHOLD" != "3" ]; then
  echo "  Error: SAFE_THRESHOLD must be 2 or 3."
  errors=1
fi
if [ "$errors" -ne 0 ]; then
  exit 1
fi

DEPLOYER=$(cast wallet address "$PRIVATE_KEY" 2>&1) || true
if ! is_address "$DEPLOYER"; then
  echo "  Error: could not derive the deployer address from PRIVATE_KEY:"
  echo "  $DEPLOYER"
  exit 1
fi

echo "  Deployer:   $DEPLOYER (gas only, not an owner)"
echo "  Owner 1:    $SAFE_ADMIN1"
echo "  Owner 2:    $SAFE_ADMIN2"
echo "  Recovery:   $SAFE_RECOVERY"
echo "  Threshold:  ${SAFE_THRESHOLD:-2} of 3"
echo ""

# ---------------------------------------------------------------- balance
echo "[2/4] Checking deployer balance on Arc $NETWORK..."
BALANCE=$(cast balance "$DEPLOYER" --rpc-url "$RPC_URL" 2>&1) || true
echo "  Balance: $BALANCE (wei, native USDC gas)"
echo ""

if [ "$BALANCE" = "0" ]; then
  if [ "$DRY_RUN" = "1" ]; then
    echo "  Warning: zero balance; a dry run may still fail gas estimation."
  else
    echo "============================================"
    echo "  !!! NO GAS !!!"
    echo "============================================"
    echo ""
    echo "$FAUCET_MSG"
    echo "  Fund: $DEPLOYER"
    echo "  Then re-run: bash scripts/deploy-safe.sh --$NETWORK"
    exit 1
  fi
fi

# ---------------------------------------------------------------- deploy
echo "[3/4] Building..."
forge build --force >/dev/null || { echo "  Build failed."; exit 1; }

echo "[4/4] Creating the Safe proxy..."
echo ""

OUT=$(mktemp)
if [ "$DRY_RUN" = "1" ]; then
  forge script script/DeploySafe.s.sol:DeploySafeScript \
    --rpc-url "$RPC_URL" \
    --private-key "$PRIVATE_KEY" \
    -vvv 2>&1 | tee "$OUT"
else
  forge script script/DeploySafe.s.sol:DeploySafeScript \
    --rpc-url "$RPC_URL" \
    --private-key "$PRIVATE_KEY" \
    --broadcast \
    -vvv 2>&1 | tee "$OUT"
fi
STATUS=${PIPESTATUS[0]}
NEW_SAFE=$(grep -oE 'Safe proxy: 0x[0-9a-fA-F]{40}' "$OUT" | tail -1 | grep -oE '0x[0-9a-fA-F]{40}' || true)
rm -f "$OUT"

if [ "$STATUS" -ne 0 ] || [ -z "$NEW_SAFE" ]; then
  echo ""
  echo "============================================"
  echo "  Safe deployment FAILED"
  echo "============================================"
  exit 1
fi

echo ""
echo "============================================"
echo "  Safe deployed"
echo "============================================"
echo "  Safe:     $NEW_SAFE"
echo "  Explorer: $EXPLORER/address/$NEW_SAFE"
echo ""

if [ "$DRY_RUN" = "1" ]; then
  echo "  Dry run: SAFE_ADDRESS was not persisted."
  exit 0
fi

# Persist for scripts/governance.sh
if grep -qE '^SAFE_ADDRESS=' "$ENV_FILE"; then
  sed -i "s|^SAFE_ADDRESS=.*|SAFE_ADDRESS=$NEW_SAFE|" "$ENV_FILE"
else
  printf '\nSAFE_ADDRESS=%s\n' "$NEW_SAFE" >> "$ENV_FILE"
fi
echo "  Saved SAFE_ADDRESS=$NEW_SAFE to $ENV_FILE"
echo ""

echo "[verify] Reading the Safe back..."
SAFE_ADDRESS="$NEW_SAFE" forge script script/DeploySafe.s.sol:DeploySafeScript \
  --sig "verify()" \
  --rpc-url "$RPC_URL" \
  -vv
echo ""
echo "  Next:"
echo "    1. Fund each executing Safe owner with a small USDC gas balance"
echo "       (the Safe itself does not pay gas)."
echo "    2. bash scripts/governance.sh --$NETWORK --deploy-timelock"
echo "    3. bash scripts/governance.sh --$NETWORK --print"
