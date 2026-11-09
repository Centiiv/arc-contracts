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
| Basic | 0.40% (400 fee units) |
| Alpha | 0.30% (300 fee units) |
| Ultimate | 0.20% (200 fee units) |

Fee values are **not** basis points. One fee unit is 0.001% and the denominator is
`Types.MAX_BPS = 100_000`, kept for storage compatibility with live orders. Fees use
ceiling division (protocol never loses on rounding) and are snapshotted per order at
creation. A tier may be set to `0`; that is a valid promotional rate and produces a
zero-fee order rather than an error.

Relayer-created orders must carry an EIP-712 `OrderIntent` signed by the sender. The
wire format and a viem example are in `EIP712_INTENT.md`.

The snapshotted rate is a **cap, not a fixed charge**. `settle()` comes in two forms:

- `settle(orderId, liquidityProvider, settlePercent)` — no fee argument; charges the rate snapshotted at creation (original behavior, fully backward compatible).
- `settle(orderId, liquidityProvider, settlePercent, appliedFeeBps)` — optional override; the contract enforces `0 <= appliedFeeBps <= order.feeBps`, allowing discounted (even zero) fees per settlement — e.g. to reward specific LPs — while making it impossible to ever charge more than the rate quoted at creation. The applied rate is emitted in the `OrderSettled` event.

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

    Safe (2-of-3) ──> TimelockController (2h) ──> ProxyAdmin ──> proxy
```

- **Proxy**: Stores all state (orders, balances, settings). Forwards calls to implementation via `delegatecall`.
- **Implementation**: Contains the logic. Replaced by scheduling an upgrade through the timelock.
- **ProxyAdmin**: Owns one proxy each. After the Wave 3 migration it is owned by the timelock, not by an EOA.
- **Timelock**: Deployed with no external admin; delay/role changes must themselves pass the 2-hour delay.

State is preserved across upgrades. The proxy address never changes. See
`GOVERNANCE_MIGRATION.md` for the migration and `scripts/check-storage-layout.sh` for the
layout gate.

### Upgrading

Before the governance migration, `upgrade.sh` signs with `admin1` and works as below.
After the migration, an upgrade is a Safe transaction that schedules
`ProxyAdmin.upgradeAndCall(proxy, newImpl, "")` on the timelock and executes it two
hours later. A single EOA can no longer upgrade.

```solidity
// Deploy new implementation
LiquidityManager newImpl = new LiquidityManager();

// Timelock (formerly admin1) calls ProxyAdmin to swap
ProxyAdmin(proxyAdminAddr).upgradeAndCall(
    ITransparentUpgradeableProxy(proxy),
    address(newImpl),
    ""
);
```

### Two-Step Settlement

1. **Step 1 (State Update)** — Relayer calls `settle(orderId, liquidityProvider, settlePercent)` — or the 4-arg overload with an `appliedFeeBps` at or below the fee snapshotted at creation. Updates order state, computes the fee, writes `PendingSettlement` to storage. No tokens move. This is blocked while paused.
2. **Step 2 (Token Transfer)** — Relayer (or LP node / temporary wallet) calls `executeSettlementTransfer()` with an optional EIP-2612 permit for the temporary wallet's allowance. Transfers the order's token (USDC or EURC — read from `order.token`, never hardcoded) to LP node and treasury. Deletes pending record. **Blocked while paused**, which is the 5.1.1 fix: a settlement recorded before an incident pause cannot be paid out.

### Two-Step Refund

1. **Step 1 (State Update)** — Relayer calls `refund()`. Marks the order refunded, writes `PendingRefund` with the **remaining** principal after any partial settlements. No tokens move. Blocked while paused.
2. **Step 2 (Token Transfer)** — Relayer, refund address (or temporary wallet) calls `executeRefundTransfer()`. Returns the remaining principal to `refundAddress`. **Not blocked while paused** — the recipient is always the refund address, never a caller-chosen party.

### Emergency Refund

While paused, the relayer, `admin1`, `admin2`, or the order's sender can call
`emergencyRefund()`. It records the remaining principal with no fee. The matching
`executeRefundTransfer()` stays available while paused.

### Cancelling a Recorded Settlement

`cancelSettlement()` reverses a recorded (not yet paid) settlement. It moves no tokens
and is **not** blocked while paused, so `cancelSettlement` → `emergencyRefund` →
`executeRefundTransfer` is always a valid exit.

## Auth Model

- **Relayer** — Authorizes settlement, refund, and emergency refund; chooses the applied fee rate at settlement (capped by the creation-time snapshot). On the off-ramp path it creates orders on behalf of users, which requires an EIP-712 `OrderIntent` signature from the user.
- **Sender** — Owns the deposit, approves the LP contract via `IERC20.approve()` or an EIP-2612 permit, and signs the order intent. On the LP self path the sender is the LP node and no intent is needed.
- **Temp Wallet** — Holds order funds and authorizes settlement/refund transfers via off-chain EIP-2612 permit signatures — it never sends a transaction and never pays gas. Off-ramp orders use a dedicated wallet; on-ramp orders pay into the LP node's own wallet.
- **LP Node / Refund Address / Relayer** — Can execute the recorded settlement (`executeSettlementTransfer`) and refund (`executeRefundTransfer`) transfers, subject to the pause rules above.
- **Admin1/Admin2** — Either admin can pause, unpause, update protocol addresses, register tokens, and update fee tiers. Only `admin1` can call `updateSettingsContract` or transfer the `admin1` slot; `admin2` transfers its own slot.
- **Safe (2-of-3) → Timelock (2h) → ProxyAdmin** — Controls implementation upgrades. `admin1` is set to the Safe after the migration, so admin rotation and `updateSettingsContract` require quorum.

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
├── mocks/MockERC20.sol          # Mock USDC/EURC with EIP-2612
├── CentiivTestBase.sol          # Shared proxy fixture + signature helpers
├── LiquidityProvider.t.sol      # Legacy lifecycle coverage
├── LiquidityProvider.pause.t.sol       # Paused-state matrix
├── LiquidityProvider.permit.t.sol      # Permit nonce consumption/replay
├── LiquidityProvider.fees.t.sol        # Zero tier + ceiling rounding
├── LiquidityProvider.intent.t.sol      # EIP-712 order-intent binding
├── LiquidityProvider.events.t.sol      # Event assertions
├── LiquidityManager.t.sol       # Legacy manager coverage
├── LiquidityManager.initialize.t.sol   # Init validation branches
├── LiquidityManager.admin.t.sol        # Rotation symmetry + events
├── Governance.t.sol             # Safe/timelock rehearsal
├── Migration.t.sol              # Wave 2 selector/calldata migration facts
├── fork/GovernanceMainnetFork.t.sol    # Full Wave 3 rehearsal against live Arc state
└── poc/                         # Auditor PoCs, retained as regression tests
script/
├── Deploy.s.sol                 # Proxy deployment script
├── DeploySafe.s.sol             # Canonical-factory Safe proxy deployment
├── Upgrade.s.sol                # Proxy upgrade script (pre-migration)
└── Governance.s.sol             # Timelock deploy + Safe calldata helpers
scripts/
├── check-storage-layout.sh      # Storage-layout regression gate
├── storage_layout_check.py
├── mutation_replay.py           # Replays the auditor's exact mutant list
└── run-mutation-shards.sh
.storage-layout/                 # Last released layouts (gate baseline)
deploy.sh                        # Testnet/mainnet deployment
upgrade.sh                       # Testnet/mainnet upgrade (pre-migration)
deploy-safe.sh                   # Create the 2-of-3 Safe via the canonical factory
governance.sh                    # Timelock deploy, Safe calldata, verification
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
./scripts/check-storage-layout.sh   # append-only storage layout gate
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
# Optional — seeds the LiquidityManager supported-token registry with EURC
export EURC=0x89B50855Aa3bE2F677cD6303Cec089B5F319D72a   # testnet
# export EURC=0xbEf5f6d51CB62b58e6A8f77868681825C6fe21c1  # mainnet
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

> **After the Wave 3 governance migration this script no longer works.** It signs with
> the `admin1` EOA, which no longer owns the ProxyAdmins. Use the timelock flow in
> `GOVERNANCE_MIGRATION.md` instead.

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

### Deploy a Safe and the Wave 3 timelock

The Safe singleton, proxy factory and fallback handler are already deployed at
their canonical v1.4.1 addresses on Arc. `deploy-safe.sh` only creates the
per-Safe proxy through the canonical factory.

```bash
cp .env.safe.example .env.safe
# fill PRIVATE_KEY (gas only), SAFE_ADMIN1, SAFE_ADMIN2, SAFE_RECOVERY

bash deploy-safe.sh --mainnet --dry-run    # simulate
bash deploy-safe.sh --mainnet              # deploy + verify, writes SAFE_ADDRESS
bash deploy-safe.sh --mainnet --verify-only
```

Then the timelock and governance calldata:

```bash
cp .env.governance.example .env.governance   # optional; .env.upgrade/.env.safe are also read
bash governance.sh --mainnet                  # show configuration
bash governance.sh --mainnet --deploy-timelock
bash governance.sh --mainnet --print          # writes governance-calldata.txt
bash governance.sh --mainnet --verify
bash governance.sh --mainnet --schedule       # after setting PROXY/PROXY_ADMIN/IMPLEMENTATION
```

The full ordered migration (EOA → Safe → timelock, `admin1` rotation, live
verification, alerting, rollback) is in `GOVERNANCE_MIGRATION.md`.

### Gas Estimate

```bash
forge script script/Deploy.s.sol \
  --rpc-url https://rpc.mainnet.arc.io \
  --estimate
```

## Arc-Specific Notes

- **USDC is native gas token** — 18 decimals for native, 6 decimals for ERC-20 interface
- **ERC-20 USDC address**: `0x3600000000000000000000000000000000000000` (testnet and mainnet)
- **ERC-20 EURC address**: `0x89B50855Aa3bE2F677cD6303Cec089B5F319D72a` (testnet), `0xbEf5f6d51CB62b58e6A8f77868681825C6fe21c1` (mainnet) — 6 decimals
- **Supported-token registry**: `createOrder` reverts with `TokenNotSupported` unless the token is registered via `LiquidityManager.setTokenSupported` (admin). `deploy.sh` seeds USDC (and `EURC` when set); after upgrading an existing deployment, run `script/SetSupportedTokens.s.sol` before upgrading the LiquidityProvider implementation (`upgrade.sh` does this automatically)
- **Chain IDs**: `5042002` (testnet), `5042` (mainnet)
- **RPC**: `https://rpc.testnet.arc.io` / `https://rpc.mainnet.arc.io`
- **Explorer**: `https://testnet.arcscan.app` / `https://arcscan.app`
- Use 6-decimal ERC-20 values for all application-level transfers and math
- All token transfers use `IERC20.transferFrom()` — the owner either pre-approves the LP contract or attaches an EIP-2612 `PermitSig` (relayer/LP submits and pays gas)
- Transfers to `address(0)` revert at protocol level
