#!/bin/bash

set -e
export PATH="$HOME/.foundry/bin:$PATH"

# --- Parse flags ---
NETWORK="testnet"
TARGET="all" # all, lm, lp, proxies

for arg in "$@"; do
  case $arg in
    --mainnet)
      NETWORK="mainnet"
      ;;
    --testnet)
      NETWORK="testnet"
      ;;
    --lm)
      TARGET="lm"
      ;;
    --lp)
      TARGET="lp"
      ;;
    --proxies)
      TARGET="proxies"
      ;;
  esac
done

if [ "$NETWORK" = "mainnet" ]; then
  RPC_URL="https://rpc.mainnet.arc.io"
  EXPLORER="https://explorer.arc.io"
else
  RPC_URL="https://rpc.testnet.arc.io"
  EXPLORER="https://explorer.testnet.arc.io"
fi

OUTPUT_DIR="verification_jsons"
mkdir -p "$OUTPUT_DIR"

echo "============================================"
echo "  Arc Liquidity Protocol - JSON Generator"
echo "  Network:  $NETWORK"
echo "  Target:   $TARGET"
echo "  Output:   ./$OUTPUT_DIR/"
echo "============================================"
echo ""

# --- Load Addresses from .env.upgrade ---
if [ -f ".env.upgrade" ]; then
  echo "  Found .env.upgrade. Loading proxy configs..."
  set -a
  source .env.upgrade
  set +a
  LM_PROXY=$(printf '%s' "$LM_PROXY" | tr -d '\r\n' | xargs 2>/dev/null || true)
  LP_PROXY=$(printf '%s' "$LP_PROXY" | tr -d '\r\n' | xargs 2>/dev/null || true)
  LM_PROXY_ADMIN=$(printf '%s' "$LM_PROXY_ADMIN" | tr -d '\r\n' | xargs 2>/dev/null || true)
  LP_PROXY_ADMIN=$(printf '%s' "$LP_PROXY_ADMIN" | tr -d '\r\n' | xargs 2>/dev/null || true)
fi

# Fallback: prompt if proxies are not set
if [ -z "$LM_PROXY" ]; then
  read -rp "  Enter LiquidityManager Proxy Address (LM_PROXY): " LM_PROXY
fi
if [ -z "$LP_PROXY" ]; then
  read -rp "  Enter LiquidityProvider Proxy Address (LP_PROXY): " LP_PROXY
fi

IMPL_SLOT="0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc"
ADMIN_SLOT="0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103"

read_slot() {
  local contract="$1"
  local slot="$2"
  local raw
  raw=$(cast storage "$contract" "$slot" --rpc-url "$RPC_URL" 2>/dev/null) || true
  if echo "$raw" | grep -qE '^0x[0-9a-fA-F]{64}$'; then
    echo "0x${raw: -40}"
  else
    echo ""
  fi
}

echo ""
echo "[1/3] Resolving on-chain implementation addresses..."

LM_IMPL=$(read_slot "$LM_PROXY" "$IMPL_SLOT")
LP_IMPL=$(read_slot "$LP_PROXY" "$IMPL_SLOT")

if [ -z "$LM_PROXY_ADMIN" ]; then
  LM_PROXY_ADMIN=$(read_slot "$LM_PROXY" "$ADMIN_SLOT")
fi
if [ -z "$LP_PROXY_ADMIN" ]; then
  LP_PROXY_ADMIN=$(read_slot "$LP_PROXY" "$ADMIN_SLOT")
fi

echo "  LM Proxy:          $LM_PROXY"
echo "  LM Implementation: ${LM_IMPL:-'Unknown'}"
echo "  LM ProxyAdmin:     ${LM_PROXY_ADMIN:-'Unknown'}"
echo ""
echo "  LP Proxy:          $LP_PROXY"
echo "  LP Implementation: ${LP_IMPL:-'Unknown'}"
echo "  LP ProxyAdmin:     ${LP_PROXY_ADMIN:-'Unknown'}"
echo ""

echo "[2/3] Compiling latest build artifacts..."
forge build
echo ""

# Array to collect summary links
declare -a LINKS=()

generate_json() {
  local addr="$1"
  local path_and_contract="$2"
  local filename="$3"
  local desc="$4"

  if [ -z "$addr" ] || [ "$addr" = "0x0000000000000000000000000000000000000000" ]; then
    return
  fi

  local output_file="$OUTPUT_DIR/$filename"
  echo "  Generating: $output_file ($desc)..."

  forge verify-contract \
    "$addr" \
    "$path_and_contract" \
    --show-standard-json-input > "$output_file"

  LINKS+=("$desc|$addr|$output_file|$EXPLORER/address/$addr/contract-verification")
}

echo "[3/3] Generating Standard-JSON inputs..."

# 1. LiquidityManager Implementation
if [ "$TARGET" = "all" ] || [ "$TARGET" = "lm" ]; then
  generate_json "$LM_IMPL" "src/LiquidityManager.sol:LiquidityManager" "LiquidityManager_Impl.json" "LiquidityManager Implementation"
fi

# 2. LiquidityProvider Implementation
if [ "$TARGET" = "all" ] || [ "$TARGET" = "lp" ]; then
  generate_json "$LP_IMPL" "src/LiquidityProvider.sol:LiquidityProvider" "LiquidityProvider_Impl.json" "LiquidityProvider Implementation"
fi

# 3. Proxies
if [ "$TARGET" = "all" ] || [ "$TARGET" = "proxies" ]; then
  generate_json "$LM_PROXY" "lib/openzeppelin-contracts/contracts/proxy/transparent/TransparentUpgradeableProxy.sol:TransparentUpgradeableProxy" "LM_Proxy.json" "LiquidityManager Proxy"
  generate_json "$LP_PROXY" "lib/openzeppelin-contracts/contracts/proxy/transparent/TransparentUpgradeableProxy.sol:TransparentUpgradeableProxy" "LP_Proxy.json" "LiquidityProvider Proxy"
fi

echo ""
echo "================================================================================"
echo "                           VERIFICATION LINKS & FILES"
echo "================================================================================"
echo "  On each link:"
echo "    1. Verification Method:  Solidity (Standard-Json-Input)"
echo "    2. Compiler Version:     v0.8.28"
echo "    3. License:              No License / UNLICENSED"
echo "    4. Upload the corresponding JSON file from ./$OUTPUT_DIR/"
echo "================================================================================"
echo ""

for entry in "${LINKS[@]}"; do
  IFS="|" read -r desc addr file url <<< "$entry"
  echo "  [$desc]"
  echo "  Address: $addr"
  echo "  File:    $file"
  echo "  Link:    $url"
  echo ""
done

echo "================================================================================"
