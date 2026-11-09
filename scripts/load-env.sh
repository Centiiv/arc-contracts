#!/bin/bash
#
# Shared network/env resolution for the root helper scripts.
# Source this file; do not execute it.
#
#   NETWORK=mainnet        # or testnet (default)
#   . ./scripts/load-env.sh
#   arc_resolve_env        # sets ENV_SUFFIX and ENV_FILE
#   arc_load_env           # sources .env.test / .env.main
#   arc_set_network        # sets RPC_URL / EXPLORER / faucet defaults
#   arc_clean VAR ...      # strips CRLF and surrounding whitespace
#
# Consolidated env files:
#   .env.test   testnet values
#   .env.main   mainnet values
#
# Override the file with ENV_FILE=/path/to/file.

arc_resolve_env() {
  if [ "${NETWORK:-testnet}" = "mainnet" ]; then
    ENV_SUFFIX="main"
  else
    ENV_SUFFIX="test"
  fi
  ENV_FILE="${ENV_FILE:-.env.$ENV_SUFFIX}"
  export ENV_SUFFIX ENV_FILE
}

arc_load_env() {
  if [ -z "${ENV_FILE:-}" ]; then
    arc_resolve_env
  fi
  if [ ! -f "$ENV_FILE" ]; then
    return 1
  fi

  set -a
  case "$ENV_FILE" in
    */*)
      # shellcheck disable=SC1090
      . "$ENV_FILE"
      ;;
    *)
      # shellcheck disable=SC1090
      . "./$ENV_FILE"
      ;;
  esac
  set +a
  return 0
}

arc_set_network() {
  if [ "${NETWORK:-testnet}" = "mainnet" ]; then
    RPC_URL="${RPC_URL:-${ARC_MAINNET_RPC_URL:-https://rpc.mainnet.arc.io}}"
    EXPLORER="${EXPLORER:-https://arcscan.app}"
    VERIFY_EXPLORER="${VERIFY_EXPLORER:-https://explorer.arc.io}"
    FAUCET_MSG="${FAUCET_MSG:-  Fund this address with real USDC on Arc mainnet.}"
    FAUCET_URL="${FAUCET_URL:-}"
  else
    RPC_URL="${RPC_URL:-${ARC_TESTNET_RPC_URL:-https://rpc.testnet.arc.io}}"
    EXPLORER="${EXPLORER:-https://testnet.arcscan.app}"
    VERIFY_EXPLORER="${VERIFY_EXPLORER:-https://explorer.testnet.arc.io}"
    FAUCET_MSG="${FAUCET_MSG:-  Arc uses USDC as its native gas token.}"
    FAUCET_URL="${FAUCET_URL:-  Faucet: https://faucet.circle.com}"
  fi
  export RPC_URL EXPLORER VERIFY_EXPLORER FAUCET_MSG FAUCET_URL
}

arc_clean() {
  local name value
  for name in "$@"; do
    value=$(printf '%s' "${!name:-}" | tr -d '\r\n' | xargs 2>/dev/null || true)
    printf -v "$name" '%s' "$value"
    export "$name"
  done
}
