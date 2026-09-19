#!/bin/bash

export PATH="$HOME/.foundry/bin:$PATH"

PROJECT_DIR="/mnt/c/Users/SciPhii/Desktop/Centiiv/code/apps/protocol/arc-contracts"
cd "$PROJECT_DIR"

echo "============================================"
echo "  Arc Liquidity Protocol - Deploy Script"
echo "============================================"
echo ""

extract_key() {
  echo "$1" | grep -i "private" | sed 's/.*: *//' | tr -d '[:space:]'
}
extract_addr() {
  echo "$1" | grep -i "address" | sed 's/.*: *//' | tr -d '[:space:]'
}

# --- Check if .env already exists ---
if [ -f ".env" ]; then
  echo "  Found existing .env file. Loading saved config:"
  source .env
  echo "  Deployer:  $DEPLOYER_ADDR"
  echo "  Admin 1:   $ADMIN1"
  echo "  Admin 2:   $ADMIN2"
  echo "  Treasury:  $TREASURY"
  echo "  Relayer:   $RELAYER"
  echo "  USDC:      $USDC"
  echo ""
  read -rp "  Use these? [Y/n]: " USE_EXISTING
  if [ "$USE_EXISTING" = "n" ] || [ "$USE_EXISTING" = "N" ]; then
    echo "  Regenerating wallets..."
    echo ""
    rm -f .env
  else
    echo ""
  fi
fi

# --- Generate wallets if no .env ---
if [ ! -f ".env" ]; then
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

  cat > "$PROJECT_DIR/.env" <<EOF
PRIVATE_KEY=$DEPLOYER_KEY
DEPLOYER_ADDR=$DEPLOYER_ADDR
ADMIN1=$ADMIN1
ADMIN1_KEY=$ADMIN1_KEY
ADMIN2=$ADMIN2
ADMIN2_KEY=$ADMIN2_KEY
TREASURY=$TREASURY
TREASURY_KEY=$TREASURY_KEY
RELAYER=$RELAYER
RELAYER_KEY=$RELAYER_KEY
USDC=$USDC
EOF

  echo "[2/4] Saved to .env (includes all private keys)"
  echo ""
fi

# --- Summary ---
echo "============================================"
echo "  Deployment Config"
echo "============================================"
echo "  Deployer:  $DEPLOYER_ADDR"
echo "  Admin 1:   $ADMIN1"
echo "  Admin 2:   $ADMIN2"
echo "  Treasury:  $TREASURY"
echo "  Relayer:   $RELAYER"
echo "  USDC:      $USDC"
echo "============================================"
echo ""

# --- Check balance ---
echo "[3/4] Checking balance on Arc testnet..."
BALANCE=$(cast balance "$DEPLOYER_ADDR" --rpc-url https://rpc.testnet.arc.io 2>&1) || true

echo "  Deployer balance: $BALANCE USDC (native gas)"
echo ""

if echo "$BALANCE" | grep -qE "^0$"; then
  echo "============================================"
  echo "  !!! NO GAS !!!"
  echo "============================================"
  echo ""
  echo "  Arc uses USDC as its native gas token."
  echo "  Fund this address with USDC testnet:"
  echo "  $DEPLOYER_ADDR"
  echo ""
  echo "  Faucet: https://faucet.circle.com"
  echo "  (select Arc Testnet)"
  echo ""
  echo "  Then re-run: bash deploy.sh"
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

  forge script script/Deploy.s.sol \
    --rpc-url https://rpc.testnet.arc.io \
    --private-key "$PRIVATE_KEY" \
    --broadcast \
    -vvv

  echo ""
  echo "============================================"
  echo "  Deployment complete!"
  echo "============================================"
  echo ""
  echo "  All private keys saved in: $PROJECT_DIR/.env"
  echo "  Explorer: https://testnet.arcscan.app"
  echo ""
  echo "  Admin functions you can now test:"
  echo "    pause() / unpause()         — either admin"
  echo "    updateProtocolAddress()     — either admin"
  echo "    transferAdmin1/2()          — specific admin"
  echo ""
fi
