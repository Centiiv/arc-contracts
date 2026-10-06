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
  VERIFY_EXPLORER="https://explorer.arc.io"
else
  RPC_URL="https://rpc.testnet.arc.io"
  EXPLORER="https://testnet.arcscan.app"
  VERIFY_EXPLORER="https://explorer.testnet.arc.io"
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
  set -a
  source .env.upgrade
  set +a
  # Strip CR (Windows CRLF) and whitespace from all values
  PRIVATE_KEY=$(printf '%s' "$PRIVATE_KEY" | tr -d '\r\n' | xargs 2>/dev/null || true)
  LM_PROXY_ADMIN=$(printf '%s' "$LM_PROXY_ADMIN" | tr -d '\r\n' | xargs 2>/dev/null || true)
  LP_PROXY_ADMIN=$(printf '%s' "$LP_PROXY_ADMIN" | tr -d '\r\n' | xargs 2>/dev/null || true)
  LM_PROXY=$(printf '%s' "$LM_PROXY" | tr -d '\r\n' | xargs 2>/dev/null || true)
  LP_PROXY=$(printf '%s' "$LP_PROXY" | tr -d '\r\n' | xargs 2>/dev/null || true)
  export PRIVATE_KEY LM_PROXY_ADMIN LP_PROXY_ADMIN LM_PROXY LP_PROXY
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

if ! echo "$PRIVATE_KEY" | grep -qE '^0x[0-9a-fA-F]{64}$'; then
  echo "  Error: PRIVATE_KEY is malformed (expected 0x + 64 hex chars)."
  echo "  Got: ${#PRIVATE_KEY} chars"
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
DEPLOYER=$(cast wallet address "$PRIVATE_KEY" 2>&1) || true
if ! echo "$DEPLOYER" | grep -qE '^0x[0-9a-fA-F]{40}$'; then
  echo "  Error: could not derive deployer address from PRIVATE_KEY:"
  echo "  $DEPLOYER"
  exit 1
fi
BALANCE=$(cast balance "$DEPLOYER" --rpc-url "$RPC_URL" 2>&1) || true
echo "  Deployer:   $DEPLOYER"
echo "  Balance: $BALANCE (wei, native gas)"
echo ""

if [ "$BALANCE" = "0" ]; then
  echo "============================================"
  echo "  !!! NO GAS !!!"
  echo "============================================"
  echo ""
  echo "  Fund this address:"
  echo "  $DEPLOYER"
  echo ""
  exit 1
fi

# --- Show current state ---
echo "[2/3] Current proxy state:"
echo ""

IMPL_SLOT="0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc"

read_impl() {
  local raw
  raw=$(cast storage "$1" "$IMPL_SLOT" --rpc-url "$RPC_URL" 2>&1) || true
  if echo "$raw" | grep -qE '^0x[0-9a-fA-F]{64}$'; then
    echo "0x${raw: -40}"
  else
    echo "unknown ($raw)"
  fi
}

if [ "$UPGRADE_TARGET" = "lm" ] || [ "$UPGRADE_TARGET" = "both" ]; then
  echo "  LiquidityManager:"
  echo "    Proxy:      $LM_PROXY"
  echo "    ProxyAdmin: $LM_PROXY_ADMIN"
  echo "    Current:    $(read_impl "$LM_PROXY")"
fi

if [ "$UPGRADE_TARGET" = "lp" ] || [ "$UPGRADE_TARGET" = "both" ]; then
  echo "  LiquidityProvider:"
  echo "    Proxy:      $LP_PROXY"
  echo "    ProxyAdmin: $LP_PROXY_ADMIN"
  echo "    Current:    $(read_impl "$LP_PROXY")"
fi

echo ""

# --- Build & upgrade ---
echo "[3/3] Building & upgrading..."
echo ""

# --force: forge's incremental cache can leave script/ artifacts stale relative
# to src/ edits, which embeds outdated impl bytecode in UpgradeScript. Always rebuild.
forge build --force

NEW_LM_IMPL=""
NEW_LP_IMPL=""

run_upgrade() {
  local sig="$1" tmp status impl
  tmp=$(mktemp)
  forge script "script/Upgrade.s.sol:UpgradeScript" \
    --sig "$sig" \
    --rpc-url "$RPC_URL" \
    --private-key "$PRIVATE_KEY" \
    --broadcast \
    -vvv 2>&1 | tee "$tmp"
  status=${PIPESTATUS[0]}
  impl=$(grep -oE 'New implementation: 0x[0-9a-fA-F]{40}' "$tmp" | tail -1 | grep -oE '0x[0-9a-fA-F]{40}' || true)
  rm -f "$tmp"
  if [ "$status" -ne 0 ]; then
    return "$status"
  fi
  if [ "$sig" = "runLM()" ]; then
    NEW_LM_IMPL="$impl"
  else
    NEW_LP_IMPL="$impl"
  fi
}

fail_upgrade() {
  echo ""
  echo "============================================"
  echo "  Upgrade FAILED"
  echo "============================================"
  exit 1
}

# --- Verification JSONs (same format/flow as verify.sh) ---
OUTPUT_DIR="verification_jsons"
mkdir -p "$OUTPUT_DIR"
VERIFY_LINKS=()

generate_verify_json() {
  local addr="$1"
  local path_and_contract="$2"
  local filename="$3"
  local desc="$4"
  local output_file="$OUTPUT_DIR/$filename"

  echo "  Generating verification JSON: $output_file"
  if forge verify-contract \
    "$addr" \
    "$path_and_contract" \
    --show-standard-json-input > "$output_file"; then
    VERIFY_LINKS+=("$desc|$addr|$output_file|$VERIFY_EXPLORER/address/$addr/contract-verification")
  else
    rm -f "$output_file"
    echo "  Warning: could not generate JSON for $desc (run ./verify.sh manually)"
  fi
}

# Seeds the supported-token registry on the live LM proxy (initialize cannot
# re-run). MUST happen before the new LiquidityProvider — whose createOrder
# gates on isTokenSupported — goes live, otherwise every new order reverts.
seed_supported_tokens() {
  echo ""
  echo "  Seeding supported tokens (USDC, EURC) on $LM_PROXY ..."

  local env_usdc="" env_eurc=""
  if [ -f ".env" ]; then
    env_usdc=$(grep -E '^USDC=' .env | tail -1 | cut -d= -f2- | tr -d '\r\n' || true)
    env_eurc=$(grep -E '^EURC=' .env | tail -1 | cut -d= -f2- | tr -d '\r\n' || true)
  fi
  USDC="${env_usdc:-0x3600000000000000000000000000000000000000}"
  if [ "$NETWORK" = "mainnet" ]; then
    EURC="${env_eurc:-0xbEf5f6d51CB62b58e6A8f77868681825C6fe21c1}"
  else
    EURC="${env_eurc:-0x89B50855Aa3bE2F677cD6303Cec089B5F319D72a}"
  fi

  if ! LM_PROXY="$LM_PROXY" USDC="$USDC" EURC="$EURC" PRIVATE_KEY="$PRIVATE_KEY" \
    forge script script/SetSupportedTokens.s.sol \
      --rpc-url "$RPC_URL" \
      --broadcast \
      -vvv
  then
    echo ""
    echo "============================================"
    echo "  Token registry seeding FAILED"
    echo "  Do NOT upgrade LiquidityProvider until this succeeds —"
    echo "  its createOrder gate would reject every order."
    echo "============================================"
    exit 1
  fi
}

if [ "$UPGRADE_TARGET" = "both" ]; then
  run_upgrade "runLM()" || fail_upgrade
  seed_supported_tokens
  run_upgrade "runLP()" || fail_upgrade
elif [ "$UPGRADE_TARGET" = "lm" ]; then
  run_upgrade "runLM()" || fail_upgrade
  seed_supported_tokens
else
  run_upgrade "runLP()" || fail_upgrade
fi

echo ""
echo "  Generating verification inputs for new implementations..."
if [ -n "$NEW_LM_IMPL" ]; then
  generate_verify_json "$NEW_LM_IMPL" "src/LiquidityManager.sol:LiquidityManager" "LiquidityManager_Impl.json" "LiquidityManager Implementation"
fi
if [ -n "$NEW_LP_IMPL" ]; then
  generate_verify_json "$NEW_LP_IMPL" "src/LiquidityProvider.sol:LiquidityProvider" "LiquidityProvider_Impl.json" "LiquidityProvider Implementation"
fi

echo ""
echo "============================================"
echo "  Upgrade complete!"
echo "============================================"
echo ""
if [ -n "$NEW_LM_IMPL" ]; then
  echo "  New LiquidityManager implementation: $NEW_LM_IMPL"
fi
if [ -n "$NEW_LP_IMPL" ]; then
  echo "  New LiquidityProvider implementation: $NEW_LP_IMPL"
fi
if [ -n "$NEW_LM_IMPL" ]; then
  echo "  LiquidityManager proxy upgraded:     $LM_PROXY"
fi
if [ -n "$NEW_LP_IMPL" ]; then
  echo "  LiquidityProvider proxy upgraded:     $LP_PROXY"
fi
echo ""
if [ ${#VERIFY_LINKS[@]} -gt 0 ]; then
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
  for entry in "${VERIFY_LINKS[@]}"; do
    IFS="|" read -r desc addr file url <<< "$entry"
    echo "  [$desc]"
    echo "  Address: $addr"
    echo "  File:    $file"
    echo "  Link:    $url"
    echo ""
  done
fi
echo "  Explorer: $EXPLORER"
echo ""
