# Arc Liquidity Protocol Contracts

Solidity smart contracts for the cross-chain liquidity provisioning protocol, ported from Stellar Soroban to Arc (EVM-compatible L1).

## Overview

Two-contract architecture:

- **LiquidityManager** — Protocol settings, admin management, pause/unpause, treasury/relayer addresses
- **LiquidityProvider** — Order lifecycle: create, settle (two-step), refund (two-step), emergency refund, tiered fees

Both contracts are deployed behind **upgradeable proxies** (OpenZeppelin TransparentUpgradeableProxy). The proxy addresses are the permanent contract addresses. Implementation contracts can be upgraded without changing addresses or losing state.

## Fee Tiers

| Tier | Default Fee |
|------|-------------|
| Basic | 0.4% (400 bps) |
| Alpha | 0.3% (300 bps) |
| Ultimate | 0.2% (200 bps) |

Fees use ceiling division (protocol never loses on rounding) and are snapshotted per order at creation.

## Architecture

### Upgradeability

```
                    User / Relayer / Admin
                           │
                           ▼
              ┌─────────────────────────┐
              │  TransparentUpgradeable  │  ◄── Permanent address
              │        Proxy             │      (users always interact here)
              └────────────┬────────────┘
                           │ delegatecall
                           ▼
              ┌─────────────────────────┐
              │  LiquidityManager        │  ◄── Implementation (swappable)
              │  (or Provider)           │
              └─────────────────────────┘

              ┌─────────────────────────┐
              │  ProxyAdmin              │  ◄── Owns both proxies
              │  (owned by admin1)       │      Only this can upgrade
              └─────────────────────────┘
```

- **Proxy**: Stores all state (orders, balances, settings). Forwards calls to implementation via `delegatecall`.
- **Implementation**: Contains the logic. Can be replaced by deploying a new implementation and calling `upgradeAndCall` on the ProxyAdmin.
- **ProxyAdmin**: Owns both proxies. Only `admin1` (as ProxyAdmin owner) can trigger upgrades.

State is preserved across upgrades. The proxy address never changes.

### Upgrading

```solidity
// Deploy new implementation
LiquidityManager newImpl = new LiquidityManager();

// Admin calls ProxyAdmin to swap
ProxyAdmin(proxyAdminAddr).upgradeAndCall(
    ITransparentUpgradeableProxy(proxy),
    address(newImpl),
    ""
);
```

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
- **ProxyAdmin Owner (admin1)** — Can upgrade implementation contracts via ProxyAdmin

## Project Structure

```
src/
├── interfaces/
│   ├── ILiquidityManager.sol    # Cross-contract interface
│   ├── ILiquidityProvider.sol   # LP interface
│   └── IERC20.sol               # Standard ERC-20
├── libraries/
│   └── Types.sol                # Structs, enums, errors, constants
├── LiquidityManager.sol         # Settings manager (upgradeable)
└── LiquidityProvider.sol        # LP contract (upgradeable)
test/
├── mocks/
│   └── MockERC20.sol            # Mock USDC
├── LiquidityManager.t.sol       # 27 tests (incl. upgradeability)
├── LiquidityProvider.t.sol      # 47 tests (incl. upgradeability)
script/
├── Deploy.s.sol                 # Proxy deployment script
├── Upgrade.s.sol                # Proxy upgrade script
deploy.sh                        # Testnet/mainnet deployment
upgrade.sh                       # Testnet/mainnet upgrade
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
forge install OpenZeppelin/openzeppelin-contracts-upgradeable --no-commit
forge install OpenZeppelin/openzeppelin-contracts --no-commit
```

### Build

```bash
forge build
```

### Test

```bash
forge test -vvv
```

## Deployment

### Environment Variables

Set environment variables (or use `deploy.sh` to generate wallets):

```bash
export PRIVATE_KEY=0x...
export ADMIN1=0x...
export ADMIN2=0x...
export TREASURY=0x...
export RELAYER=0x...
export USDC=0x3600000000000000000000000000000000000000
```

### Deploy with deploy.sh

```bash
# Testnet (default)
bash deploy.sh

# Mainnet
bash deploy.sh --mainnet
```

The script checks your deployer balance, builds, and deploys proxies. Proxy addresses are logged in the output — these are your permanent contract addresses.

### Deploy manually

```bash
forge script script/Deploy.s.sol \
  --rpc-url https://rpc.testnet.arc.io \
  --private-key $PRIVATE_KEY \
  --broadcast \
  -vvv
```

For mainnet:
```bash
forge script script/Deploy.s.sol \
  --rpc-url https://rpc.mainnet.arc.io \
  --private-key $PRIVATE_KEY \
  --broadcast \
  -vvv
```

### Upgrade with upgrade.sh

Create a `.env.upgrade` file with your deployed contract addresses and admin1's private key:

```bash
# .env.upgrade
PRIVATE_KEY=0x...              # admin1 private key
LM_PROXY_ADMIN=0x...           # ProxyAdmin for LiquidityManager
LP_PROXY_ADMIN=0x...           # ProxyAdmin for LiquidityProvider
LM_PROXY=0x...                 # LiquidityManager proxy address
LP_PROXY=0x...                 # LiquidityProvider proxy address
```

These addresses are logged when you first deploy with `deploy.sh`.

```bash
# Upgrade both contracts
bash upgrade.sh

# Upgrade only LiquidityManager
bash upgrade.sh --lm

# Upgrade only LiquidityProvider
bash upgrade.sh --lp

# Testnet (default)
bash upgrade.sh

# Mainnet
bash upgrade.sh --mainnet
```

The script checks your admin1 balance, shows current implementation addresses, deploys new implementations, and upgrades the proxies.

### Upgrade manually

```bash
export PRIVATE_KEY=0x...       # admin1 private key
export LM_PROXY_ADMIN=0x...
export LP_PROXY_ADMIN=0x...
export LM_PROXY=0x...
export LP_PROXY=0x...

# Both
forge script script/Upgrade.s.sol \
  --rpc-url https://rpc.mainnet.arc.io \
  --broadcast -vvv

# LM only
forge script script/Upgrade.s.sol:UpgradeScript:runLM \
  --rpc-url https://rpc.mainnet.arc.io \
  --broadcast -vvv

# LP only
forge script script/Upgrade.s.sol:UpgradeScript:runLP \
  --rpc-url https://rpc.mainnet.arc.io \
  --broadcast -vvv
```

### Gas Estimate

```bash
forge script script/Deploy.s.sol \
  --rpc-url https://rpc.mainnet.arc.io \
  --estimate
```

## Arc-Specific Notes

- **USDC is native gas token** — 18 decimals for native, 6 decimals for ERC-20 interface
- **ERC-20 USDC address**: `0x3600000000000000000000000000000000000000` (testnet and mainnet)
- **Chain IDs**: `5042002` (testnet), `5042` (mainnet)
- **RPC**: `https://rpc.testnet.arc.io` / `https://rpc.mainnet.arc.io`
- **Explorer**: `https://testnet.arcscan.app` / `https://arcscan.app`
- Use 6-decimal ERC-20 values for all application-level transfers and math
- All token transfers use `IERC20.transferFrom()` — temp wallet must approve LP contract
- Transfers to `address(0)` revert at protocol level
