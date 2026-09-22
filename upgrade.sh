#!/bin/bash

export PATH="$HOME/.foundry/bin:$PATH"

# --- Parse flags ---
NETWORK="testnet"
UPGRADE_TARGET="both"
for arg in "$@"; do
  case $arg in
    --mainnet)
      NETWORK="mainnet"
      ;;
    --testnet)
      NETWORK="testnet"
      ;;
    --lm)
      UPGRADE_TARGET="lm"
      ;;
    --lp)
      UPGRADE_TARGET="lp"
      ;;
  esac
done

if [ "$NETWORK" = "mainnet" ]; then
  RPC_URL="https://rpc.mainnet.arc.io"
  EXPLORER="https://arcscan.app"
else
  RPC_URL="https://rpc.testnet.arc.io"
  EXPLORER="https://testnet.arcscan.app"
fi

echo "============================================"
echo "  Arc Liquidity Protocol - Upgrade Script"
echo "  Network: $NETWORK"
echo "  Target:  $UPGRADE_TARGET"
echo "============================================"
echo ""

# --- Check for .env.upgrade ---
if [ -f ".env.upgrade" ]; then
  echo "  Found .env.upgrade, loading..."
  echo ""
  source .env.upgrade
else
  echo "  No .env.upgrade found."
  echo "  Expected vars: PRIVATE_KEY, LM_PROXY_ADMIN, LP_PROXY_ADMIN, LM_PROXY, LP_PROXY"
  echo ""
  echo "  Example .env.upgrade:"
  echo "    PRIVATE_KEY=0x..."
  echo "    LM_PROXY_ADMIN=0x..."
  echo "    LP_PROXY_ADMIN=0x..."
  echo "    LM_PROXY=0x..."
  echo "    LP_PROXY=0x..."
  echo ""
  exit 1
fi

# --- Validate required vars ---
if [ -z "$PRIVATE_KEY" ]; then
  echo "  Error: PRIVATE_KEY is required in .env.upgrade"
  exit 1
fi

if [ "$UPGRADE_TARGET" = "lm" ] || [ "$UPGRADE_TARGET" = "both" ]; then
  if [ -z "$LM_PROXY" ] || [ -z "$LM_PROXY_ADMIN" ]; then
    echo "  Error: LM_PROXY and LM_PROXY_ADMIN required in .env.upgrade (or use --lp to skip LM)"
    exit 1
  fi
fi

if [ "$UPGRADE_TARGET" = "lp" ] || [ "$UPGRADE_TARGET" = "both" ]; then
  if [ -z "$LP_PROXY" ] || [ -z "$LP_PROXY_ADMIN" ]; then
    echo "  Error: LP_PROXY and LP_PROXY_ADMIN required in .env.upgrade (or use --lm to skip LP)"
    exit 1
  fi
fi

# --- Check admin1 balance ---
echo "[1/3] Checking deployer balance on Arc $NETWORK..."
BALANCE=$(cast balance "$PRIVATE_KEY" --rpc-url "$RPC_URL" 2>&1) || true
echo "  Deployer balance: $BALANCE USDC (native gas)"
echo ""

if echo "$BALANCE" | grep -qE "^0$"; then
  echo "============================================"
  echo "  !!! NO GAS !!!"
  echo "============================================"
  echo ""
  echo "  Fund this address with USDC:"
  echo "  $(cast wallet address "$PRIVATE_KEY" 2>/dev/null)"
  echo ""
  exit 1
fi

# --- Show current state ---
echo "[2/3] Current proxy state:"
echo ""

if [ "$UPGRADE_TARGET" = "lm" ] || [ "$UPGRADE_TARGET" = "both" ]; then
  CURRENT_IMPL=$(cast call "$LM_PROXY" "implementation()(address)" --rpc-url "$RPC_URL" 2>&1) || true
  echo "  LiquidityManager:"
  echo "    Proxy:     $LM_PROXY"
  echo "    ProxyAdmin: $LM_PROXY_ADMIN"
  echo "    Current:   $CURRENT_IMPL"
fi

if [ "$UPGRADE_TARGET" = "lp" ] || [ "$UPGRADE_TARGET" = "both" ]; then
  CURRENT_IMPL=$(cast call "$LP_PROXY" "implementation()(address)" --rpc-url "$RPC_URL" 2>&1) || true
  echo "  LiquidityProvider:"
  echo "    Proxy:     $LP_PROXY"
  echo "    ProxyAdmin: $LP_PROXY_ADMIN"
  echo "    Current:   $CURRENT_IMPL"
fi

echo ""

# --- Build & upgrade ---
echo "[3/3] Building & upgrading..."
echo ""

forge build

SCRIPT_ARGS=""
if [ "$UPGRADE_TARGET" = "lm" ]; then
  SCRIPT_ARGS=":UpgradeScript:runLM"
elif [ "$UPGRADE_TARGET" = "lp" ]; then
  SCRIPT_ARGS=":UpgradeScript:runLP"
else
  SCRIPT_ARGS=""
fi

forge script "script/Upgrade.s.sol${SCRIPT_ARGS}" \
  --rpc-url "$RPC_URL" \
  --private-key "$PRIVATE_KEY" \
  --broadcast \
  -vvv

echo ""
echo "============================================"
echo "  Upgrade complete!"
echo "============================================"
echo ""
echo "  Explorer: $EXPLORER"
echo ""
