#!/bin/bash
#
# Deploy the Arc Liquidity Protocol proxies.
#
#   bash scripts/deploy.sh              # testnet
#   bash scripts/deploy.sh --mainnet    # mainnet
#
# Reads .env.test or .env.main (selected by the network flag). If ENV_FILE is
# set, that file is used instead. See .env.example for the full variable list.

export PATH="$HOME/.foundry/bin:$PATH"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_ROOT" || exit 1

PROJECT_DIR="$PROJECT_ROOT"

# shellcheck source=scripts/load-env.sh
. "$SCRIPT_DIR/load-env.sh"

# --- Parse --network flag ---
NETWORK="testnet"
for arg in "$@"; do
  case $arg in
    --network=mainnet|--mainnet)
      NETWORK="mainnet"
      ;;
    --network=testnet|--testnet)
      NETWORK="testnet"
      ;;
  esac
done

arc_resolve_env

echo "============================================"
echo "  Arc Liquidity Protocol - Deploy Script"
echo "  Network: $NETWORK"
echo "  Env:     $ENV_FILE"
echo "============================================"
echo ""

extract_key() {
  echo "$1" | grep -i "private" | sed 's/.*: *//' | tr -d '[:space:]'
}
extract_addr() {
  echo "$1" | grep -i "address" | sed 's/.*: *//' | tr -d '[:space:]'
}

# --- Load the consolidated network env if it exists ---
GENERATE_WALLETS=0
if [ -f "$ENV_FILE" ]; then
  echo "  Found $ENV_FILE. Loading saved config..."
  arc_load_env || { echo "  Error: could not load $ENV_FILE."; exit 1; }
  arc_clean \
    PRIVATE_KEY DEPLOYER_ADDR \
    ADMIN1 ADMIN1_KEY ADMIN2 ADMIN2_KEY RECOVERY RECOVERY_KEY \
    EVM_MASTER EVM_MASTER_KEY TREASURY TREASURY_KEY RELAYER RELAYER_KEY \
    USDC EURC UPGRADE_KEY \
    SAFE_ADMIN1 SAFE_ADMIN2 SAFE_RECOVERY SAFE_THRESHOLD \
    SAFE_SINGLETON SAFE_PROXY_FACTORY SAFE_FALLBACK_HANDLER SAFE_SALT_NONCE SAFE_ADDRESS \
    TIMELOCK TIMELOCK_MIN_DELAY GOVERNANCE_KEY \
    PROXY PROXY_ADMIN IMPLEMENTATION SALT RPC_URL
fi
arc_set_network

if [ -z "${DEPLOYER_ADDR:-}" ] && [ -n "${PRIVATE_KEY:-}" ]; then
  DEPLOYER_ADDR=$(cast wallet address "$PRIVATE_KEY" 2>/dev/null) || true
fi

# A usable deployment config needs the deployer and the four init roles.
CONFIG_COMPLETE=1
for name in PRIVATE_KEY ADMIN1 ADMIN2 TREASURY RELAYER; do
  if [ -z "${!name:-}" ]; then
    CONFIG_COMPLETE=0
  fi
done

if [ "$CONFIG_COMPLETE" = "1" ]; then
  echo "  Deployer:  $DEPLOYER_ADDR"
  echo "  Admin 1:   $ADMIN1"
  echo "  Admin 2:   $ADMIN2"
  echo "  Recovery:  ${RECOVERY:-'(unset)'}"
  echo "  Treasury:  $TREASURY"
  echo "  Relayer:   $RELAYER"
  echo "  USDC:      ${USDC:-'(default)'}"
  echo "  EURC:      ${EURC:-'(default)'}"
  echo ""
  read -rp "  Use these? [Y/n]: " USE_EXISTING
  if [ "$USE_EXISTING" = "n" ] || [ "$USE_EXISTING" = "N" ]; then
    echo "  Not using the saved config."
    echo "  Edit $ENV_FILE (or move it aside) and re-run."
    exit 1
  fi
  echo ""
else
  if [ "$NETWORK" = "mainnet" ]; then
    echo "  Error: $ENV_FILE is missing required values."
    echo "  Fill in PRIVATE_KEY, ADMIN1, ADMIN2, TREASURY and RELAYER,"
    echo "  then re-run. Use .env.example as the template."
    exit 1
  fi
  echo "  $ENV_FILE is missing required values; generating testnet wallets."
  echo ""
  GENERATE_WALLETS=1
fi

# --- Generate wallets if needed (testnet only) ---
if [ "$GENERATE_WALLETS" = "1" ]; then
  echo "[1/4] Generating wallets..."
  echo ""

  echo "--- Deployer wallet ---"
  DEPLOYER_RAW=$(cast wallet new 2>&1)
  echo "$DEPLOYER_RAW"
  DEPLOYER_KEY=$(extract_key "$DEPLOYER_RAW")
  DEPLOYER_ADDR=$(extract_addr "$DEPLOYER_RAW")
  echo ""

  echo "--- Admin 1 wallet ---"
  ADMIN1_RAW=$(cast wallet new 2>&1)
  echo "$ADMIN1_RAW"
  ADMIN1_KEY=$(extract_key "$ADMIN1_RAW")
  ADMIN1=$(extract_addr "$ADMIN1_RAW")
  echo ""

  echo "--- Admin 2 wallet ---"
  ADMIN2_RAW=$(cast wallet new 2>&1)
  echo "$ADMIN2_RAW"
  ADMIN2_KEY=$(extract_key "$ADMIN2_RAW")
  ADMIN2=$(extract_addr "$ADMIN2_RAW")
  echo ""

  echo "--- Recovery (third Safe owner) wallet ---"
  RECOVERY_RAW=$(cast wallet new 2>&1)
  echo "$RECOVERY_RAW"
  RECOVERY_KEY=$(extract_key "$RECOVERY_RAW")
  RECOVERY=$(extract_addr "$RECOVERY_RAW")
  echo ""

  echo "--- Treasury wallet ---"
  TREASURY_RAW=$(cast wallet new 2>&1)
  echo "$TREASURY_RAW"
  TREASURY_KEY=$(extract_key "$TREASURY_RAW")
  TREASURY=$(extract_addr "$TREASURY_RAW")
  echo ""

  echo "--- Relayer wallet ---"
  RELAYER_RAW=$(cast wallet new 2>&1)
  echo "$RELAYER_RAW"
  RELAYER_KEY=$(extract_key "$RELAYER_RAW")
  RELAYER=$(extract_addr "$RELAYER_RAW")
  echo ""

  # Fallback: manual input if parsing failed
  if [ -z "$DEPLOYER_KEY" ] || [ -z "$DEPLOYER_ADDR" ]; then
    echo "Could not parse deployer wallet. Please enter manually:"
    read -rp "  Deployer Private Key (0x...): " DEPLOYER_KEY
    read -rp "  Deployer Address (0x...):    " DEPLOYER_ADDR
  fi
  if [ -z "$ADMIN1" ]; then
    read -rp "  Admin 1 Address (0x...):     " ADMIN1
  fi
  if [ -z "$ADMIN1_KEY" ]; then
    read -rp "  Admin 1 Private Key (0x...): " ADMIN1_KEY
  fi
  if [ -z "$ADMIN2" ]; then
    read -rp "  Admin 2 Address (0x...):     " ADMIN2
  fi
  if [ -z "$ADMIN2_KEY" ]; then
    read -rp "  Admin 2 Private Key (0x...): " ADMIN2_KEY
  fi
  if [ -z "$RECOVERY" ]; then
    read -rp "  Recovery Address (0x...):    " RECOVERY
  fi
  if [ -z "$RECOVERY_KEY" ]; then
    read -rp "  Recovery Private Key (0x...): " RECOVERY_KEY
  fi
  if [ -z "$TREASURY" ]; then
    read -rp "  Treasury Address (0x...):    " TREASURY
  fi
  if [ -z "$TREASURY_KEY" ]; then
    read -rp "  Treasury Private Key (0x...): " TREASURY_KEY
  fi
  if [ -z "$RELAYER" ]; then
    read -rp "  Relayer Address (0x...):     " RELAYER
  fi
  if [ -z "$RELAYER_KEY" ]; then
    read -rp "  Relayer Private Key (0x...): " RELAYER_KEY
  fi

  USDC="0x3600000000000000000000000000000000000000"
  if [ "$NETWORK" = "mainnet" ]; then
    EURC="0xbEf5f6d51CB62b58e6A8f77868681825C6fe21c1"
  else
    EURC="0x89B50855Aa3bE2F677cD6303Cec089B5F319D72a"
  fi

  if [ -f "$ENV_FILE" ]; then
    ENV_BACKUP="$ENV_FILE.bak.$(date +%Y%m%d%H%M%S)"
    cp "$ENV_FILE" "$ENV_BACKUP"
    echo "  Backed up $ENV_FILE to $ENV_BACKUP"
  fi

  cat > "$ENV_FILE" <<EOF
# =============================================================================
# Arc Liquidity Protocol - $NETWORK environment (generated by scripts/deploy.sh)
# =============================================================================
PRIVATE_KEY=$DEPLOYER_KEY
DEPLOYER_ADDR=$DEPLOYER_ADDR

ADMIN1=$ADMIN1
ADMIN1_KEY=$ADMIN1_KEY
ADMIN2=$ADMIN2
ADMIN2_KEY=$ADMIN2_KEY
RECOVERY=$RECOVERY
RECOVERY_KEY=$RECOVERY_KEY
UPGRADE_KEY=$ADMIN1_KEY

EVM_MASTER=${EVM_MASTER:-}
EVM_MASTER_KEY=${EVM_MASTER_KEY:-}
TREASURY=$TREASURY
TREASURY_KEY=$TREASURY_KEY
RELAYER=$RELAYER
RELAYER_KEY=$RELAYER_KEY

USDC=$USDC
EURC=$EURC

# Filled in after deployment.
LM_PROXY=
LP_PROXY=
LM_PROXY_ADMIN=
LP_PROXY_ADMIN=

# Safe owners default to the protocol admins.
SAFE_ADMIN1=$ADMIN1
SAFE_ADMIN2=$ADMIN2
SAFE_RECOVERY=$RECOVERY
SAFE_THRESHOLD=2
SAFE_SINGLETON=
SAFE_PROXY_FACTORY=
SAFE_FALLBACK_HANDLER=
SAFE_SALT_NONCE=0
SAFE_ADDRESS=

TIMELOCK=
TIMELOCK_MIN_DELAY=7200
GOVERNANCE_KEY=

PROXY=
PROXY_ADMIN=
IMPLEMENTATION=
SALT=

RPC_URL=
EOF

  echo "[2/4] Saved to $ENV_FILE (includes all private keys)"
  echo ""
fi

# --- Token addresses ---
USDC="${USDC:-0x3600000000000000000000000000000000000000}"
if [ "$NETWORK" = "mainnet" ]; then
  EURC="${EURC:-0xbEf5f6d51CB62b58e6A8f77868681825C6fe21c1}"
else
  EURC="${EURC:-0x89B50855Aa3bE2F677cD6303Cec089B5F319D72a}"
fi
UPGRADE_KEY="${UPGRADE_KEY:-$ADMIN1_KEY}"
SAFE_ADMIN1="${SAFE_ADMIN1:-$ADMIN1}"
SAFE_ADMIN2="${SAFE_ADMIN2:-$ADMIN2}"
SAFE_RECOVERY="${SAFE_RECOVERY:-$RECOVERY}"
export USDC EURC PRIVATE_KEY ADMIN1 ADMIN2 RECOVERY TREASURY RELAYER

# --- Summary ---
echo "============================================"
echo "  Deployment Config"
echo "============================================"
echo "  Network:   $NETWORK"
echo "  Env:       $ENV_FILE"
echo "  RPC:       $RPC_URL"
echo "  Deployer:  $DEPLOYER_ADDR"
echo "  Admin 1:   $ADMIN1"
echo "  Admin 2:   $ADMIN2"
echo "  Recovery:  $RECOVERY"
echo "  Treasury:  $TREASURY"
echo "  Relayer:   $RELAYER"
echo "  USDC:      $USDC"
echo "  EURC:      $EURC"
echo "============================================"
echo ""

# --- Check balance ---
echo "[3/4] Checking balance on Arc $NETWORK..."
BALANCE=$(cast balance "$DEPLOYER_ADDR" --rpc-url "$RPC_URL" 2>&1) || true

echo "  Deployer balance: $BALANCE USDC (native gas)"
echo ""

if echo "$BALANCE" | grep -qE "^0$"; then
  echo "============================================"
  echo "  !!! NO GAS !!!"
  echo "============================================"
  echo ""
  echo "$FAUCET_MSG"
  echo "  Fund this address with USDC:"
  echo "  $DEPLOYER_ADDR"
  echo ""
  if [ -n "$FAUCET_URL" ]; then
    echo "$FAUCET_URL"
    echo "  (select Arc Testnet)"
    echo ""
  fi
  echo "  Then re-run: bash scripts/deploy.sh --$NETWORK"
  echo ""
else
  echo "============================================"
  echo "  Deploying contracts..."
  echo "============================================"
  echo ""

  echo "[4/4] Building & deploying..."
  echo ""

  if [ ! -d "lib/forge-std" ]; then
    forge install foundry-rs/forge-std --no-commit
  fi

  forge build

  if ! forge script script/Deploy.s.sol \
    --rpc-url "$RPC_URL" \
    --private-key "$PRIVATE_KEY" \
    --broadcast \
    -vvv; then
    echo ""
    echo "============================================"
    echo "  Deployment FAILED"
    echo "============================================"
    exit 1
  fi

  echo ""
  echo "============================================"
  echo "  Deployment complete!"
  echo "============================================"
  echo ""
  case "$ENV_FILE" in
    */*) ENV_PATH="$ENV_FILE" ;;
    *) ENV_PATH="$PROJECT_DIR/$ENV_FILE" ;;
  esac
  echo "  All private keys saved in: $ENV_PATH"
  echo "  Explorer: $EXPLORER"
  echo ""
  echo "  Contracts deployed behind upgradeable proxies."
  echo "  The proxy addresses are your permanent contract addresses."
  echo "  Implementation contracts can be upgraded via ProxyAdmin."
  echo ""
  echo "  Next: copy LM_PROXY, LP_PROXY, LM_PROXY_ADMIN and LP_PROXY_ADMIN"
  echo "  from the output above into $ENV_FILE, then run:"
  echo "    bash scripts/verify.sh --$NETWORK"
  echo ""
  echo "  Admin functions you can now test:"
  echo "    pause() / unpause()         — either admin"
  echo "    updateProtocolAddress()     — either admin"
  echo "    setTokenSupported()         — either admin"
  echo "    transferAdmin1/2()          — specific admin"
  echo ""
fi
