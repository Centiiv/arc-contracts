# Arc Liquidity Protocol Contracts

Solidity smart contracts for the cross-chain liquidity provisioning protocol, ported from Stellar Soroban to Arc (EVM-compatible L1).

## Overview

Two-contract architecture:

- **LiquidityManager** — Protocol settings, admin management, pause/unpause, treasury/relayer addresses
- **LiquidityProvider** — Order lifecycle: create, settle (two-step), refund (two-step), emergency refund, tiered fees

## Fee Tiers

| Tier | Default Fee |
|------|-------------|
| Basic | 0.4% (400 bps) |
| Alpha | 0.3% (300 bps) |
| Ultimate | 0.2% (200 bps) |

Fees use ceiling division (protocol never loses on rounding) and are snapshotted per order at creation.

## Architecture

### Two-Step Settlement

1. **Step 1 (State Update)** — Relayer calls `settle()`. Updates order state, writes `PendingSettlement` to storage. No tokens move.
2. **Step 2 (Token Transfer)** — Temporary wallet calls `executeSettlementTransfer()`. Transfers USDC to LP node and treasury. Deletes pending record.

### Two-Step Refund

1. **Step 1 (State Update)** — Relayer calls `refund()`. Marks order refunded, writes `PendingRefund`. No tokens move.
2. **Step 2 (Token Transfer)** — Temporary wallet calls `executeRefundTransfer()`. Returns full amount to refund address.

### Emergency Refund

Relayer calls `emergencyRefund()` while contract is paused. Full amount returned with no fee.

## Auth Model

- **Relayer** — Authorizes order creation, settlement, refund, and emergency refund (`msg.sender` check)
- **Sender** — Pre-approves LP contract via `IERC20.approve()` for token transfers
- **Temp Wallet** — Pre-approves LP contract, then calls `executeSettlementTransfer()` / `executeRefundTransfer()`
- **Admin1/Admin2** — Either admin can pause, unpause, update addresses, update fee tiers

## Project Structure

```
src/
├── interfaces/
│   ├── ILiquidityManager.sol    # Cross-contract interface
│   └── IERC20.sol               # Standard ERC-20
├── libraries/
│   └── Types.sol                # Structs, enums, errors, constants
├── LiquidityManager.sol         # Settings manager
└── LiquidityProvider.sol        # LP contract
test/
├── mocks/
│   └── MockERC20.sol            # Mock USDC
├── LiquidityManager.t.sol       # 20+ tests
└── LiquidityProvider.t.sol      # 30+ tests
script/
└── Deploy.s.sol                 # Deployment script
```

## Setup

### Install Foundry

```bash
curl -L https://foundry.paradigm.xyz | bash
foundryup
```

### Install dependencies

```bash
cd arc-contracts
forge install foundry-rs/forge-std --no-commit
```

### Build

```bash
forge build
```

### Test

```bash
forge test -vvv
```

## Deployment (Arc Testnet)

Set environment variables:

```bash
export PRIVATE_KEY=0x...
export ADMIN1=0x...
export ADMIN2=0x...
export TREASURY=0x...
export RELAYER=0x...
export USDC=0x3600000000000000000000000000000000000000
```

Deploy:

```bash
forge script script/Deploy.s.sol \
  --rpc-url https://rpc.testnet.arc.io \
  --private-key $PRIVATE_KEY \
  --broadcast \
  --verify
```

## Arc-Specific Notes

- **USDC is native gas token** — 18 decimals for native, 6 decimals for ERC-20 interface
- **ERC-20 USDC address**: `0x3600000000000000000000000000000000000000` (testnet)
- **Chain ID**: `5042002` (testnet)
- **RPC**: `https://rpc.testnet.arc.io`
- **Explorer**: `https://testnet.arcscan.app`
- Use 6-decimal ERC-20 values for all application-level transfers and math
- All token transfers use `IERC20.transferFrom()` — temp wallet must approve LP contract
- Transfers to `address(0)` revert at protocol level
