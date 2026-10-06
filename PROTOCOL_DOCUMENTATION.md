# Centiiv Liquidity Protocol: Arc Technical Architecture & Specification

Target platform: Arc Network (Circle Layer-1)  
Primary assets: Canonical USDC (`0x3600000000000000000000000000000000000000`), EURC (testnet `0x89B50855Aa3bE2F677cD6303Cec089B5F319D72a`, mainnet `0xbEf5f6d51CB62b58e6A8f77868681825C6fe21c1`)  
Solidity version: `^0.8.20`  
Proxy pattern: OpenZeppelin `TransparentUpgradeableProxy`  

---

## 1. Executive summary

The Centiiv Liquidity Protocol provides deterministic, non-custodial stablecoin (USDC / EURC) liquidity routing and order fulfillment on the Arc Layer-1 network. It uses two contracts, separating protocol governance and parameterization from transactional settlement.

Orders move through an escrowed state machine. Payouts and refunds use a two-phase settlement pattern (State Commitment -> Fund Disbursement) via EIP-2612 gas-abstracted permit authorizations. The protocol does not pool user capital or hold settlement assets in long-term contract custody.

---

## 2. Network specifications

| Parameter | Specification |
|---|---|
| **Network** | Arc (Circle Layer-1) |
| **Execution Environment** | EVM-compatible |
| **Native Gas Token** | USDC |
| **Canonical USDC Contract** | `0x3600000000000000000000000000000000000000` |
| **Supported Settlement Tokens** | USDC, EURC (6 decimals each; registered in `LiquidityManager.setTokenSupported`) |
| **Testnet Chain ID** | `5042002` |
| **Mainnet Chain ID** | `5042` |
| **Finality Model** | Sub-second deterministic finality |

---

## 3. Architecture and core contracts

The system decouples configuration state from order-routing logic across two primary modules:

### 3.1 `LiquidityManager.sol`

This contract holds protocol-wide configuration, operational registries, and access-control mappings. It handles state only and holds zero asset balances.

It runs under dual-admin governance: sensitive configuration changes require authorization across both administrative accounts, and ownership transfers follow a two-step propose/accept pattern. The contract also stores the protocol `Treasury` address and the authorized `Relayer` execution keys, provides a global pause switch that halts non-emergency operations immediately, and keeps the fee schedule in basis points (bps).

It additionally maintains the supported-token registry (`setTokenSupported` / `isTokenSupported`, admin-only). `LiquidityProvider.createOrder` reverts with `TokenNotSupported` for any token that is not registered, so the set of settleable assets (USDC, EURC, …) is an explicit governance decision rather than an implicit whitelist.

### 3.2 `LiquidityProvider.sol`

This is the transactional core that runs the order lifecycle. It does not commingle funds into a shared liquidity pool; assets move between order escrows, liquidity provider fulfillment nodes, and the treasury.

Order creation validates parameters, registers order hashes, locks the fee ceiling, and verifies custody into a dedicated escrow account for each order. Settlement enforces the fee ceiling, checks relayer authorization, and routes funds once a valid authorization payload arrives. Refund processing covers regular cancellations and emergency returns after a pause.

---

## 4. Order lifecycle and state machine

### 4.1 Order creation

An order is created on-chain by registering its metadata and escrowing capital.

1. The caller provides an order identifier, nominal token volume, routing parameters, and execution message hash.
2. The active fee tier rate is queried from `LiquidityManager` and bound permanently to the order as F_max.
3. The order's token is checked against `LiquidityManager.isTokenSupported` — unregistered tokens revert with `TokenNotSupported`.
4. Capital is deposited into a dedicated order-bound escrow address. Orders cannot be overwritten, re-initialized, or underfunded.

### 4.2 Two-phase settlement

Settlement separates verification from fund transfers and lets escrow accounts abstract gas away, so it runs in two phases.

Phase 1 is settlement recording (`recordSettlement`). The authorized relayer registers the target fulfiller, the executed volume (partial or full), and the applied fee rate (F_applied). The contract asserts:

F_applied <= F_max

If F_applied > F_max, the transaction reverts. Internal accounting then records the pending disbursement; token balances do not change.

Phase 2 is disbursement (`executeSettlement`), run by the relayer or fulfiller node. The transfer is authorized by an EIP-2612 permit signed by the dedicated order escrow address. The transaction submitter (relayer or node) pays the gas, so the escrow address never needs to hold a gas token. Assets are distributed atomically:

Payout_Treasury = Amount * F_applied

Payout_Provider = Amount - Payout_Treasury

### 4.3 Refund paths

Standard refunds are initiated by the relayer when order routing cannot be completed, and they follow the same two-phase pattern. The sender receives 100% of the nominal escrowed principal, and protocol fees are 0.00%.

Emergency refunds are callable only while the protocol is `PAUSED`. The sender or relayer can immediately refund the remaining escrow balance with no fees.

### 4.4 Cumulative partial fulfillment accounting

The protocol supports partial execution. For orders settled incrementally, each partial settlement updates a state variable Total_settled, and the contract asserts:

Total_settled <= Principal_total

The remaining unfulfilled allocation stays available for later settlement phases or a pro-rata refund.

---

## 5. Fee schedule and mathematical invariants

### 5.1 Fee tiers

Fee tiers are stored in basis points (1 bps = 0.01% = 0.0001):

| Tier Identifier | Fee Rate | Fee Basis Points | Example Fee (10,000 USDC) |
|---|---|---|---|
| **Tier 1 (Basic)** | 0.40% | 40 bps | 40.00 USDC |
| **Tier 2 (Alpha)** | 0.30% | 30 bps | 30.00 USDC |
| **Tier 3 (Ultimate)** | 0.20% | 20 bps | 20.00 USDC |

### 5.2 Computational invariants

1. At order creation (t_create), F_max = TierRate. For any settlement at t_settle > t_create:
   0 <= F_applied <= F_max

2. Fee calculation uses ceiling division to prevent dust exploits that would otherwise allow zero-fee settlements on fractional allocations:
   FeeAmount = ceiling((Amount * F_applied) / BPS_DIVISOR)

3. Every refund operation charges zero fees:
   Fee = 0 for all refund operations

4. Administrative changes to fee tier definitions apply only to orders initialized after the update (t > t_update). They cannot change orders that already exist.

---

## 6. Access control and role matrix

The protocol uses role-based access control (RBAC) across administrative and operational roles:

| Operational Function | `Admin 1` | `Admin 2` | `Relayer` | `LP Node` | Escrow Account | Unauthenticated |
|---|:---:|:---:|:---:|:---:|:---:|:---:|
| **Pause / Unpause Protocol** | Yes | Yes | No | No | No | No |
| **Propose/Accept Admin Transfer** | Yes | Yes | No | No | No | No |
| **Update Treasury / Relayer Address** | Yes | Yes | No | No | No | No |
| **Modify Global Fee Schedule** | Yes | Yes | No | No | No | No |
| **Record Settlement / Refund** | No | No | Yes | No | No | No |
| **Execute Disbursement (with Permit)** | No | No | Yes | Yes | No | No |
| **Emergency Refund Execution** | No | No | Yes | No | No | No |
| **Sign EIP-2612 Permit** | No | No | No | No | Yes (Off-chain) | No |
| **Read Contract State / Events** | Yes | Yes | Yes | Yes | Yes | Yes |

Governance roles (`Admin 1`, `Admin 2`) have no way to disburse order capital, and the `Relayer` cannot change governance parameters or exceed the fee bounds committed at order creation.

---

## 7. Security architecture and invariants

Admin rotation requires a proposal transaction from the current admin, then an `acceptRole` transaction from the nominated address. The contract prevents `Admin 1` and `Admin 2` from being set to the same address.

Escrow accounts authorize disbursements with EIP-2612 signatures instead of signing on-chain transactions themselves, so escrow keys never need to hold gas assets.

Neither `LiquidityManager` nor `LiquidityProvider` includes wildcard token sweep functions, owner-directed drain mechanisms, or arbitrary asset transfers. Funds can flow only to the liquidity provider address specified during settlement, the canonical `Treasury` address, or the original depositor via refund.

Order creation and execution enforce zero-address checks on all participant parameters, positive transfer values, unique non-colliding order identifiers, and correct cryptographic validation of EIP-2612 permit nonces and deadlines.

---

## 8. Upgradeability and storage layout

The contracts use OpenZeppelin's `TransparentUpgradeableProxy` pattern for upgrades:

- Users and external integrations interact with a static proxy address, while the logic lives in an implementation contract that governance can update.
- Implementations follow upgrade-safe storage patterns: new storage variables append to existing layouts, storage gaps are maintained across versions, and initializers are guarded by OpenZeppelin's `initializer` modifiers to prevent front-running during deployment.
- `ProxyAdmin` is owned exclusively by governance, so implementation upgrades require formal administrative authorization.

---

## 9. Verification, test suite and tooling

The test suite runs on Foundry with deterministic execution and invariant assertions.

It contains 87 automated unit, integration, and fuzz tests across both core contracts. Verification covers:

- The full order state machines (creation, partial fulfillment, terminal fulfillment, standard and emergency refunds).
- Storage layout preservation and post-upgrade continuity.
- Invariant testing that F_applied <= F_max holds across all boundary conditions.
- Fee rounding precision and dust accumulation boundaries.
- Access-control rejection across all unauthorized entry points.