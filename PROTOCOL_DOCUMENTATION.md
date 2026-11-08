# Centiiv Liquidity Protocol: Arc Technical Architecture & Specification

Target platform: Arc Network (Circle Layer-1)  
Primary assets: Canonical USDC (`0x3600000000000000000000000000000000000000`), EURC (testnet `0x89B50855Aa3bE2F677cD6303Cec089B5F319D72a`, mainnet `0xbEf5f6d51CB62b58e6A8f77868681825C6fe21c1`)  
Solidity version: `^0.8.20`  
Proxy pattern: OpenZeppelin `TransparentUpgradeableProxy`

---

## 1. Executive summary

The Centiiv Liquidity Protocol provides deterministic, non-custodial stablecoin (USDC / EURC) liquidity routing and order fulfillment on the Arc Layer-1 network. It uses two contracts, separating protocol governance and parameterization from transactional settlement.

Orders move through a two-phase state machine. Payouts and refunds use a two-phase settlement pattern (state commitment → fund disbursement) via EIP-2612 gas-abstracted permit authorizations. The protocol does not pool user capital or take long-term custody of settlement assets in the contracts.

Funds are held in key-controlled temporary wallets, not in `LiquidityProvider`. The shape of that custody differs by path and is described in §4.1.

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

It runs under two administrative accounts. Either account can pause/unpause, change the treasury or relayer address, and update tier fees; `updateSettingsContract` and the `admin1` slot are controlled by `admin1` alone. It is therefore not a two-signature contract at the Solidity layer. Upgrade authority is separated: both `ProxyAdmin` contracts are owned by a 2-of-3 Safe behind a 2-hour `TimelockController` (§8), and `admin1` is set to that Safe so the highest-privilege paths require quorum.

Admin transfers follow a two-step propose/accept pattern, one slot at a time: `admin1` proposes `admin1`, `admin2` proposes `admin2`. The contract prevents both slots holding the same address.

The contract also stores the protocol `Treasury` address and the authorized `Relayer` address, provides a global pause switch, and maintains the supported-token registry (`setTokenSupported` / `isTokenSupported`, admin-only). `LiquidityProvider.createOrder` reverts with `TokenNotSupported` for any token that is not registered, so the set of settleable assets (USDC, EURC, …) is an explicit governance decision rather than an implicit whitelist.

### 3.2 `LiquidityProvider.sol`

This is the transactional core that runs the order lifecycle. It never custodies funds: every deposit and payout is a `transferFrom` between externally held wallets. Assets move between order temporary wallets, liquidity provider fulfillment nodes, and the treasury.

Order creation validates parameters, registers the order, locks the fee ceiling, and pulls the deposit into the temporary wallet named for the order. Settlement enforces the fee ceiling, checks relayer authorization, and routes funds once the authorized party executes the transfer. Refund processing covers regular cancellations and emergency returns after a pause.

---

## 4. Order lifecycle and state machine

### 4.1 Order creation

An order is created on-chain by registering its metadata and moving the deposit into a temporary wallet. The custody model depends on who creates the order:

- **Off-ramp (relayer path).** The relayer calls `createOrder` on behalf of `sender` and names a distinct `temporaryWalletAddress`. The deposit moves into that dedicated, order-bound wallet. Because the relayer chooses the destination, this path requires an EIP-712 `OrderIntent` signature from `sender` binding the order id, token, amount, temporary wallet, refund address, fee tier, deadline and nonce. The permit or allowance still moves the tokens; the intent only proves where they may go.
- **On-ramp (self path).** The LP node calls `createOrder` with itself as `sender` and `temporaryWalletAddress`. The transfer is a self-transfer, so no new wallet is funded and no intent is required: the wallet is already the node's own. Collateral isolation for this path is enforced off-chain by the routing lease engine, not by the contract.

Steps:

1. The caller provides an order identifier, nominal token volume, routing parameters, tier, and execution message hash.
2. The tier rate is read from `LiquidityProvider.tierFees` and snapshotted on the order as `feeBps` (the permanent cap, F_max).
3. The order's token is checked against `LiquidityManager.isTokenSupported` — unregistered tokens revert with `TokenNotSupported`.
4. The caller must be `sender` (self path) or the relayer. A relayer-created order additionally requires the EIP-712 intent described above.
5. The deposit is pulled into `temporaryWalletAddress`. On the self path the address must equal `msg.sender`. On the relayer path it is the signed destination.
6. Order identifiers are first-writer-wins. A duplicate reverts `OrderAlreadyExists`; the backend retries with a fresh id.

### 4.2 Two-phase settlement

Settlement separates verification from fund transfers so temporary wallets can stay gasless.

Phase 1 is settlement recording (`settle`, two overloads). The relayer registers the target fulfiller, the executed portion, and the applied fee rate (F_applied, defaulting to the snapshotted cap). The contract asserts:

F_applied <= F_max

If F_applied > F_max, the transaction reverts `FeeExceedsCap`. Internal accounting then records the pending disbursement; token balances do not change. Only one settlement may be pending per order.

Phase 2 is disbursement (`executeSettlementTransfer`), run by the fulfiller, the relayer, or the temporary wallet. The transfer is authorized by an EIP-2612 permit signed by the temporary wallet, or by an existing allowance. The transaction submitter pays the gas, so the temporary wallet never needs to hold a gas token. Assets are distributed atomically:

```
Payout_Treasury = ceiling(Amount * F_applied / 100,000)
Payout_Provider = Amount - Payout_Treasury
```

`executeSettlementTransfer` is pause-gated. A settlement recorded before an incident pause cannot be paid out until the protocol is unpaused or the settlement is cancelled (§4.5).

### 4.3 Refund paths

Standard refunds (`refund`) are initiated by the relayer when order routing cannot be completed, and they follow the same two-phase pattern. The pending refund is the **remaining** principal after any partial settlements, not the original nominal amount; protocol fees on a refund are zero. `refund` is pause-gated.

Emergency refunds (`emergencyRefund`) are callable only while the protocol is paused, by the relayer, `admin1`, `admin2`, or the order's `sender`. They record the remaining principal as a pending refund with no fees. The disbursement (`executeRefundTransfer`) is **not** pause-gated: its recipient is always `order.refundAddress`, never a party chosen by the caller, so pausing it would only trap funds.

### 4.4 Cumulative partial fulfillment accounting

The protocol supports partial execution. Each settlement decrements `currentBps` (the unfulfilled share, seeded to 100,000) and the remaining `amount`; the contract asserts:

settlePercent <= currentBps

Full settlement sets `isFulfilled` and drains `currentBps` to zero. `isFulfilled` and `isRefunded` are terminal except through `cancelSettlement` (§4.5).

### 4.5 Cancelling a recorded settlement

`cancelSettlement` reverses phase 1 before funds move: it restores `amount`, `currentBps` and `feesCollected`, clears `isFulfilled`, and deletes the pending settlement. It moves no tokens and is deliberately not pause-gated. `cancelSettlement` → `emergencyRefund` → `executeRefundTransfer` is therefore always available, including while paused.

---

## 5. Fee schedule and mathematical invariants

### 5.1 Fee tiers

Fee values are **not** basis points. One fee unit is 0.001%, and the denominator is 100,000. The seeded tiers are:

| Tier Identifier | Fee Rate | Fee Units | Example Fee (10,000 USDC) |
|---|---|---|---|
| **Tier 1 (Basic)** | 0.40% | 400 | 40.00 USDC |
| **Tier 2 (Alpha)** | 0.30% | 300 | 30.00 USDC |
| **Tier 3 (Ultimate)** | 0.20% | 200 | 20.00 USDC |

`Types.MAX_BPS = 100_000` and `updateTierFee` caps a tier at `10_000` units (10%). The constants and storage names retain the historical `BPS` spelling; changing the value would invalidate `order.currentBps` on all in-flight orders.

### 5.2 Computational invariants

1. At order creation (t_create), F_max = TierRate. For any settlement at t_settle > t_create:
   0 <= F_applied <= F_max

2. Fee calculation uses ceiling division on every slice to prevent dust exploits that would otherwise allow zero-fee settlements on fractional allocations:
   FeeAmount = ceiling((Amount * F_applied) / 100,000)

   Because each slice rounds independently, aggregate fees can exceed `ceiling(total * F_applied / 100,000)` by at most `n - 1` base units for `n` slices. The excess accrues to the treasury, never to the depositor.

3. A zero-rated tier is valid. `updateTierFee` accepts `0`, and `_calculateProtocolFee` returns `0` rather than reverting, so a promotional tier does not halt order creation.

4. Every refund operation charges zero fees:
   Fee = 0 for all refund operations

5. Administrative changes to fee tier definitions apply only to orders initialized after the update (t > t_update). They cannot change orders that already exist, because `order.feeBps` is snapshotted at creation.

---

## 6. Access control and role matrix

The protocol uses role-based access control (RBAC) across administrative and operational roles:

| Operational Function | `Admin 1` | `Admin 2` | `Relayer` | `LP Node` | Temporary Wallet | Unauthenticated |
|---|:---:|:---:|:---:|:---:|:---:|:---:|
| **Pause / Unpause Protocol** | Yes | Yes | No | No | No | No |
| **Propose Admin 1 Transfer / Accept** | Propose + accept own slot | No | No | No | No | No |
| **Propose Admin 2 Transfer / Accept** | No | Propose + accept own slot | No | No | No | No |
| **Update Treasury / Relayer Address** | Yes | Yes | No | No | No | No |
| **Modify Global Fee Schedule** | Yes | Yes | No | No | No | No |
| **Register / Unregister Token** | Yes | Yes | No | No | No | No |
| **Update Settings Contract** | Yes | No | No | No | No | No |
| **Create Order (own wallet)** | No | No | No | Yes | No | Yes (self path, own funds) |
| **Create Order (relayer path, signed intent)** | No | No | Yes | No | No | No |
| **Record Settlement / Refund** | No | No | Yes | No | No | No |
| **Execute Settlement Disbursement** | No | No | Yes | Yes (recipient) | Yes (payer) | No |
| **Cancel Recorded Settlement** | Yes | Yes | Yes | No | No | No |
| **Emergency Refund (while paused)** | Yes | Yes | Yes | No | No | Order sender |
| **Execute Refund Disbursement** | No | No | Yes | No | Yes (payer) | Refund address |
| **Sign EIP-2612 Permit** | No | No | No | No | Yes (off-chain) | No |
| **Sign EIP-712 Order Intent** | No | No | No | No | No | Order sender (off-chain) |
| **Read Contract State / Events** | Yes | Yes | Yes | Yes | Yes | Yes |

Governance roles (`Admin 1`, `Admin 2`) have no way to disburse order capital, and the `Relayer` cannot change governance parameters or exceed the fee bounds committed at order creation.

---

## 7. Security architecture and invariants

Admin rotation requires a proposal transaction from the current admin, then an `acceptAdmin1` / `acceptAdmin2` transaction from the nominated address. The contract prevents `Admin 1` and `Admin 2` from being set to the same address.

Temporary wallets authorize disbursements with EIP-2612 signatures instead of signing on-chain transactions themselves, so they never need to hold gas assets. Relayer-created orders additionally require an EIP-712 intent from the depositor; a compromised relayer cannot redirect a deposit, change its amount, or swap the refund address.

Neither `LiquidityManager` nor `LiquidityProvider` includes wildcard token sweep functions, owner-directed drain mechanisms, or arbitrary asset transfers. Funds can flow only to the liquidity provider address specified during settlement, the canonical `Treasury` address, or the order's `refundAddress`.

Order creation and execution enforce zero-address checks on participant parameters (including the settlement recipient), positive transfer values, non-zero order identifiers and message hashes, and correct cryptographic validation of EIP-2612 permit nonces and deadlines. A supplied permit is always attempted so its nonce is consumed even when a prior allowance already covers the transfer.

Pause semantics are deliberate: `executeSettlementTransfer` is blocked while paused; `cancelSettlement` and `executeRefundTransfer` are not; `emergencyRefund` requires the paused state. There is no paused state in which funds have no exit.

---

## 8. Upgradeability and storage layout

The contracts use OpenZeppelin's `TransparentUpgradeableProxy` pattern for upgrades:

- Users and external integrations interact with a static proxy address, while the logic lives in an implementation contract that governance can update.
- Implementations follow upgrade-safe storage patterns: new storage variables append to existing layouts, storage gaps are maintained across versions, and initializers are guarded by OpenZeppelin's `initializer` modifiers to prevent front-running during deployment.
- Upgrade authority follows `Safe (2-of-3) → TimelockController (2 hours) → ProxyAdmin → proxy`. The original deployer EOA no longer controls the ProxyAdmins after the Wave 3 migration.
- `scripts/check-storage-layout.sh` diffs the current `forge inspect` layout against the last released snapshot under `.storage-layout/`; a moved or retyped non-gap variable fails the check.

The 5.1.2 remediation consumed the old `uint256 __gap` at slot 6 for `mapping(address => uint256) intentNonce` and redeclared a `uint256[50] __gap` at slot 7. No other sequential storage changed.

---

## 9. Verification, test suite and tooling

The test suite runs on Foundry with deterministic execution and invariant assertions.

It contains 236 automated unit, integration, PoC and governance tests across both core contracts. Verification covers:

- The full order state machines (creation, partial fulfillment, terminal fulfillment, standard and emergency refunds).
- The paused-state matrix, including the drain (no settlement payout while paused) and the deadlock (cancellation and refund disbursement remain available).
- EIP-712 order-intent binding, tampering, expiry, nonce reuse and domain separation.
- Storage layout preservation and post-upgrade continuity.
- Permille fee math, per-slice ceiling rounding and its aggregate bound.
- Access-control rejection across all unauthorized entry points.
- The Wave 3 upgrade chain: timelock-only upgrades, the 2-hour delay, and admin rotation.
