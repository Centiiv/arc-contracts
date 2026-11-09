# Remediation Plan — Centiiv / arc-contracts

**Baseline:** `858eaf7` · **Audit:** Olympix BugPoCer Lite (23 Oct 2026) · **Plan date:** 8 Nov 2026
**Companion:** `AUDIT_RESPONSE.md` (what we told the auditors), `backlogs.md` (deferred work)
**Status:** Waves 0–2 implemented in the working tree; Wave 3 tooling and runbook implemented.
Contract deployment and the Safe transaction batch remain operational steps.

---

## 1. Objective

Close the eight findings we accepted as defects, document the eight we accept, and correct the three we
dispute — without mis-accounting a single live order. The contracts are live on Arc mainnet
(~30,000 USDC processed), so every change is evaluated against "does this preserve in-flight state?"

Work is organised into three waves plus a test wave. Waves are sequential; Wave 2 can overlap Wave 3.

| Wave | Scope | Touches storage? | Upgrades a proxy? |
|---|---|---|---|
| 0 | Tests | No | No |
| 1 | `LiquidityProvider` logic patch | **No** | Yes (LP) |
| 2 | EIP-712 order intent | Yes (`intentNonce`) | Yes (LP) |
| 3 | Governance migration | No | No |

---

## 2. Non-negotiable invariants

These must hold after every wave. Any change that breaks one is rejected on sight.

1. **No order's fee rate changes retroactively.** `order.feeBps` is the cap from creation; `settle` may
   discount, never exceed.
2. **`Types.MAX_BPS` stays `100_000`.** `order.currentBps` is seeded from it; changing the constant
   mis-settles every open order.
3. **`isFulfilled` / `isRefunded` are terminal.** Nothing may resurrect a terminal order except
   `cancelSettlement`, which has an explicit, tested reversal.
4. **`LiquidityProvider` never custodies funds.** All payouts remain `transferFrom` on temp wallets.
5. **Pause blocks outflows to relayer-chosen parties, never refunds to the depositor.**
6. **`pause()` stays single-key and instant.** Incident response must not require quorum.
7. **Storage layout is append-only.** New variables replace `__gap` (slot 6); `__gap` is re-declared
   after them.

---

## 3. Wave 0 — tests before code

### 3.1 Files

| File | Purpose | Status |
|---|---|---|
| `test/CentiivTestBase.sol` | Shared proxy fixture and signature helpers | ✅ |
| `test/poc/ExecuteTransfers_MissingPauseGate.t.sol` | Auditor PoC, adapted from the report (§5.1.1) | ✅ |
| `test/poc/RelayerOrderCreation_Unbound.t.sol` | Auditor PoC (§5.1.2) | ✅ |
| `test/poc/OnrampSharedEscrow.t.sol` | Auditor PoCs for 5.1.3(a) and (b) | ✅ (pins accepted behaviour) |
| `test/LiquidityProvider.pause.t.sol` | Paused-state matrix | ✅ |
| `test/LiquidityProvider.permit.t.sol` | Permit nonce consumption and replay | ✅ |
| `test/LiquidityProvider.fees.t.sol` | Ceiling rounding and zero-tier behaviour | ✅ |
| `test/LiquidityProvider.intent.t.sol` | EIP-712 binding, tampering, expiry, nonce, domain | ✅ (added) |
| `test/LiquidityProvider.events.t.sol` | Event assertions for the lifecycle | ✅ (added) |
| `test/LiquidityManager.initialize.t.sol` | Init validation branches | ✅ |
| `test/LiquidityManager.admin.t.sol` | `acceptAdmin2` gate, rotation symmetry, events | ✅ |
| `test/Governance.t.sol` | Wave 3 rehearsal: timelock-only upgrade, 2h delay, rotation | ✅ (added) |

The suite was run against `858eaf7` before the logic patch: 29 tests failed for the
expected reasons (`Paused()`, missing intent reverts, unconsumed permit nonces,
`FeePercentNotSet`). After the patch: **236 passed, 0 failed**.

### 3.2 Paused-state matrix (the core of Wave 1)

For each combination, assert revert-or-succeed explicitly:

| State | `createOrder` | `settle` | `refund` | `cancelSettlement` | `emergencyRefund` | `executeSettlementTransfer` | `executeRefundTransfer` |
|---|---|---|---|---|---|---|---|
| Unpaused, open order | ✅ | ✅ | ✅ | ✅ (if pending) | ❌ `NotPaused` | ✅ (if pending) | ✅ (if pending) |
| Unpaused, pending settlement | ✅ | ✅ | ❌ `PendingSettlementExists` | ✅ | ❌ | ✅ | n/a |
| **Paused**, open order | ❌ `Paused` | ❌ | ❌ | ✅ (reverts `NoPendingSettlement`) | ✅ | n/a | n/a |
| **Paused**, pending settlement | ❌ | ❌ | ❌ | ✅ **must succeed** | ❌ `PendingSettlementExists` | ❌ **`Paused`** | n/a |
| **Paused**, pending refund | ❌ | ❌ | ❌ | n/a | ❌ `OrderRefunded` | n/a | ✅ **must succeed** |

The two bold cells are the deadlock fix; the third is the drain fix.

### 3.3 Mutation-driven additions

Every category from `AUDIT_RESPONSE.md` §5.2 gets a test. Target: **≥ 90% mutation score** after Wave 1,
with remaining survivors justified in writing. The full re-run was waived by the CTO; the tests for
each survivor category are in place and the replay tool remains available.

---

## 4. Wave 1 — `LiquidityProvider` logic patch

**Single upgrade. Zero storage changes.**

### 4.1 Change spec

**All eight changes are implemented in `src/LiquidityProvider.sol`.**

| # | Location | Change |
|---|---|---|
| 1 | `executeSettlementTransfer` (`:198`) | add `whenNotPaused` |
| 2 | `cancelSettlement` (`:239`) | remove `whenNotPaused` |
| 3 | `executeRefundTransfer` (`:290`) | **no change** — stays ungated by design |
| 4 | `_settle` (`:148`) | reject `liquidityProvider == address(0)` |
| 5 | `_permitIfProvided` (`:321-344`) | always attempt `permit` when a signature is supplied |
| 6 | `emergencyRefund` (`:346`) | accept `msg.sender == order.sender` |
| 7 | `_calculateProtocolFee` (`:407`) | zero tier returns `0` instead of reverting |
| 8 | `onlyRelayer` (`:35-39`), comment (`:73-74`) | delete modifier, correct comment |

### 4.2 Details

**1. Drain gate**

```solidity
function executeSettlementTransfer(
    bytes32 orderId,
    address tokenAddress,
    Types.PermitSig calldata permitSig
) external whenNotPaused {          // ← added
```

`whenNotPaused` reads `ILiquidityManager(settingsContract).isPaused()` (`:48-51`).

**2 & 3. Deadlock removal**

```solidity
function cancelSettlement(bytes32 orderId) external {   // ← modifier removed
```

`cancelSettlement` performs only a state reversal (`:253-262`) and moves no tokens. `executeRefundTransfer`
is left ungated: its recipient is `order.refundAddress`, never a relayer-chosen party, so pausing it
would trap funds without adding protection.

Resulting pause semantics: **no discretionary payouts, every unwind path open.**

**4. Zero-address guard**

```solidity
if (liquidityProvider == address(0)) revert ZeroAddress();
```

Place it with the other `_settle` input checks, before any state write.

**5. Permit nonce consumption**

Replace the early-return-on-sufficient-allowance with:

```solidity
if (permitSig.r == bytes32(0)) return;

// Always attempt: a skipped permit leaves its nonce unconsumed and its
// signature replayable from calldata until the deadline.
try IERC20Permit(token).permit(
    owner, address(this), value,
    permitSig.deadline, permitSig.v, permitSig.r, permitSig.s
) {} catch {}

if (IERC20(token).allowance(owner, address(this)) < value) revert TransferFailed();
```

Behaviour preserved: a signature-less call (`r == 0`) still skips entirely, and a reverted permit is
still tolerated when allowance suffices. Cost: one extra external call when allowance already covers
`value`.

**6. Sender-authorised emergency refund**

Reorder so the order is loaded before the caller check:

```solidity
Types.Order storage order = orders[orderId];
if (order.orderId == bytes32(0)) revert OrderNotFound();

address _relayer = ILiquidityManager(settingsContract).getRelayerAddress();
address _admin1  = ILiquidityManager(settingsContract).getAdmin1();
address _admin2  = ILiquidityManager(settingsContract).getAdmin2();
if (
    msg.sender != _relayer &&
    msg.sender != _admin1 &&
    msg.sender != _admin2 &&
    msg.sender != order.sender          // ← added
) revert Unauthorized();
```

The existing `PendingSettlementExists` guard (`:358`) still applies, so a sender cannot unseat a live
settlement.

**7. Zero-rated tier**

Delete `if (tierBps == 0) revert FeePercentNotSet();` (`:409`). The overflow guard is
`if (amount > 0 && tierBps > 0 && …)`, which short-circuits when `tierBps == 0`, so no division by zero.
A zero rate yields `numerator = 0`, `feeWhole = 0`, `remainder = 0` → returns `0`.

**8. Dead code**

Delete the `onlyRelayer` modifier. All relayer checks are inline (`_settle:157`, `refund:271`,
`executeSettlementTransfer:213`, `executeRefundTransfer:305`, `cancelSettlement:243`,
`emergencyRefund:350`). Rewrite the `createOrder` comment to drop the false `onlyRelayer` claim.

### 4.3 Backend impact

**Implemented in `protocol-backend` (commit `8efcabf`).**

| Change | Backend effect |
|---|---|
| 1 | STEP2 `executeSettlementTransfer` reverts `Paused()` during a pause. The settlement worker now holds the op at `STEP1_DONE` **without consuming the step-2 attempt budget** and never marks the order FAILED. `settle()` (STEP1) gets the same treatment. |
| 2 | Admin tooling may now call `cancelSettlement` while paused. No code change required. |
| 5 | None in practice — `buildPermitForPending` returns `NO_PERMIT` (`r == 0`) when allowance suffices, so the new path is not hit. |
| 7 | Fee display must render a `0` rate without treating it as unset. |

### 4.4 Not in this wave

- No uniqueness mapping — **dropped** (see `AUDIT_RESPONSE.md` §3.3).
- No `feeBps == 0` legacy fallback — **dropped**; it would collide with change 7.
- No `MAX_BPS` change.

---

## 5. Wave 2 — EIP-712 order intent (5.1.2)

### 5.1 Contract

```
domain   = { name: "CentiivLiquidityProvider", version: "1", chainId, verifyingContract }
struct   = OrderIntent(bytes32 orderId, address token, int256 amount,
                       address temporaryWalletAddress, address refundAddress,
                       uint8 protocolFee, uint256 deadline, uint256 nonce)
```

- Verified inside `createOrder` **only** when `msg.sender != params.sender`.
- `deadline` is enforced; a zero `r` is rejected explicitly.
- `intentNonce[sender]` is **monotonic**: a nonce below the stored cursor reverts
  `InvalidNonce`; a higher nonce is accepted and moves the cursor to `nonce + 1`.
  Gaps are permitted so an abandoned order cannot wedge the relayer, and a consumed
  nonce can never be replayed.
- EIP-712 v4 is implemented locally (domain typehash, struct typehash, `\x19\x01`
  digest, `ECDSA.tryRecover`) rather than by inheriting OZ `EIP712Upgradeable`.
  OZ 5.7's `EIP712Upgradeable` pulls in `MessageHashUtils → Strings → Bytes`, which
  uses the Cancun `MCOPY` opcode; these contracts compile for `evm_version = paris`.
  The local implementation has the same wire format and uses **no storage**: the
  name and version are constants and the separator is recomputed per call, so the
  already-initialised proxy needs no `__EIP712_init` migration.

### 5.2 Params

Add to `Types.OrderParams` (append only):

```solidity
struct OrderIntentSig {
    uint256 deadline;
    uint256 nonce;
    uint8   v;
    bytes32 r;
    bytes32 s;
}
```

### 5.3 Storage

```solidity
mapping(address => uint256) public intentNonce;   // takes slot 6 (old __gap)
uint256[50] private __gap;                        // slots 7-56
```

This is the only storage change in the whole remediation. Verify with the CI layout gate before merging.

### 5.4 Backend

**Implemented in `protocol-backend` (commit `8efcabf`), deployed after the contract upgrade.**

- Sign an `OrderIntent` alongside the existing EIP-2612 permit whenever the relayer creates an order.
- Pass `OrderIntentSig` in `createOrderParams` (appended after `permitSig`).
- The permit remains responsible for moving tokens; the intent is authorisation only.
- The backend reads `intentNonce(sender)` from the contract and combines it with a
  local monotonic cursor, so concurrent creates in one process cannot sign the same
  nonce. Gaps are permitted on-chain and a consumed nonce cannot replay.
- **Deployment order is contract first, then backend, in a coordinated window.**
  Appending a field changes the canonical tuple, so `createOrder`'s selector changes
  (`test/Migration.t.sol` pins this). The old backend's calldata cannot route to the new
  implementation. During the window, relayer-created off-ramp orders revert; on-ramp
  self-path orders, settlement, refunds and emergency refunds are unaffected. Pause or
  queue off-ramp order creation for the window, then release the backend and verify.
- After the upgrade the backend reads `intentNonce(sender)` from the contract; the
  getter does not exist on the old implementation, so the backend must not call it
  before the upgrade.

### 5.5 Rejected alternative

`refundAddress == params.sender` on the relayer path. Rejected: tokens land in the attacker's temp wallet
at `transferFrom` time, so constraining the refund address recovers nothing already moved, while adding a
backend/contract deployment-ordering hazard.

---

## 6. Wave 3 — governance migration

**Runs after Waves 1 and 2** — a timelock would otherwise delay the patches themselves.

### 6.1 Target topology

```
Safe (2-of-3: admin1, admin2, recovery)
  └── TimelockController (minDelay = 7200s)
        └── ProxyAdmin (LM)  → LiquidityManager proxy
        └── ProxyAdmin (LP)  → LiquidityProvider proxy
```

### 6.2 Steps

| # | Action | Notes |
|---|---|---|
| 1 | Deploy Safe 2-of-3 | Verify owners and threshold via `getThreshold()` / `getOwners()` |
| 2 | `ProxyAdmin.transferOwnership(Safe)` ×2 | **Must be signed by the current owner (original admin1 EOA).** Do this early — if that key is lost first, upgrade authority is stranded |
| 3 | Prove control | No-op `upgradeAndCall(proxy, currentImpl, "")` from the Safe; confirm an `Upgraded` event with an unchanged implementation |
| 4 | Deploy `TimelockController` | `PROPOSER` = Safe, `CANCELLER` = Safe, `EXECUTOR` = Safe, `minDelay = 7200`. `script/Governance.s.sol` |
| 5 | No external admin to renounce | Deploy with `admin = address(0)`. OZ still grants `DEFAULT_ADMIN_ROLE` to the timelock itself, so delay/role changes must pass the delay. Verify `hasRole(DEFAULT_ADMIN_ROLE, Safe) == false` |
| 6 | `ProxyAdmin.transferOwnership(Timelock)` ×2 | Executed by the Safe |
| 7 | Set `admin1` = Safe | `transferAdmin1(Safe)` from current admin1, then Safe calls `acceptAdmin1()` |
| 8 | Rehearse | Testnet: schedule → wait 2h → execute a real upgrade |

### 6.3 Option E consequences

- `transferAdmin1`, `acceptAdmin1`, `updateSettingsContract` → Safe quorum.
- `pause`, `unpause`, `updateProtocolAddress`, `setTokenSupported`, `updateTierFee` → single-key via
  `admin2`, unchanged.
- **Known gap:** `transferAdmin2` remains `onlyAdmin2` (logged in `backlogs.md`).

### 6.4 Alerting (protocol-backend → Discord)

| Contract | Event |
|---|---|
| Timelock | `CallScheduled`, `Cancelled`, `Executed` |
| Both proxies | `Upgraded(address)` |
| ProxyAdmin | `OwnershipTransferred`, `AdminChanged` |

An unmonitored window is not a control. `CallScheduled` is the alert that matters.

**Implemented** in `protocol-backend` (commit `dd2b2b2`): `GovernanceMonitorService`
polls the timelock, both proxies and both ProxyAdmins every minute, chunks
`eth_getLogs`, and posts critical events with `@everyone` to a dedicated governance
webhook (falling back to the transaction-monitor webhook). Config keys:
`ARC_MAINNET_TIMELOCK_ADDRESS`, `ARC_MAINNET_LM_PROXY_ADMIN_ADDRESS`,
`ARC_MAINNET_LP_PROXY_ADMIN_ADDRESS` (and the `ARC_TESTNET_*` equivalents),
`GOVERNANCE_MONITOR_DISCORD_WEBHOOK_URL`.

### 6.5 Runbook to publish

`GOVERNANCE_MIGRATION.md` is the operational runbook and `script/Governance.s.sol` emits the
Safe Transaction Builder calldata for every step. It covers:

- **Ordering:** EOA → Safe → timelock, with the no-op upgrade in between to prove control.
- **Incident:** pause (instant) → diagnose → schedule fix → 2h → execute.
- **Admin rotation:** on-chain transfer **and** Safe signer swap. Neither alone completes it.
- **Key loss:** 2-of-3 tolerates one loss; document valid quorums and who holds what.

---

## 7. Deployment runbook

### 7.1 Pre-flight (every wave)

```sh
forge build
forge test                        # full suite green
forge test --match-path 'test/poc/*'
./scripts/check-storage-layout.sh # append-only layout, against .storage-layout/*.prev.json
```

### 7.2 Wave 1 (LP only)

```sh
./upgrade.sh --mainnet --lp
```

`upgrade.sh` handles the proxy upgrade and verification. It seeds tokens only on the full path; a
`--lp`-only run skips seeding by design.

### 7.3 Post-upgrade smoke test (mainnet, real order)

1. `createOrder` on-ramp → expect success.
2. `settle` → expect `PendingSettlement` written.
3. `pause()` → `executeSettlementTransfer` **must revert `Paused`**.
4. `cancelSettlement` while paused → **must succeed**.
5. `emergencyRefund` → `executeRefundTransfer` while paused → **must succeed**, funds at `refundAddress`.
6. `unpause()` → new order flows end-to-end.

Step 4 and 5 together are the deadlock fix; if either fails, roll back.

### 7.4 Wave 2

**Contract upgrade, then backend release, in a coordinated window.** The appended
`intentSig` field changes `createOrder`'s selector, so the old backend cannot call the
new implementation (`test/Migration.t.sol` pins both facts: the selector changes, and
the data layout would otherwise be forward-compatible). Relayer-created off-ramp orders
revert until the backend lands; on-ramp orders, settlement, refunds and emergency
refunds are unaffected.

Pause or queue off-ramp order creation for the window, deploy the LP upgrade, release
the backend, then verify one relayer-created order end-to-end with a real intent
signature. Keep the pre-Wave-2 implementation address recorded for rollback.

### 7.5 Wave 3

Follow §6.2 in order. Nothing in Wave 3 touches contract code.

---

## 8. Rollback

| Wave | Rollback | Safety |
|---|---|---|
| 1 | `upgradeAndCall(proxy, previousImpl, "")` | **Safe** — logic only, no storage change |
| 2 | Same, to the pre-Wave-2 implementation | **Safe** — `intentNonce` is appended; the older implementation ignores it |
| 3 | `ProxyAdmin.transferOwnership` back; timelock can be bypassed only while it still owns the ProxyAdmin | Migration is reversible until ownership moves to the timelock |

**Record the pre-upgrade implementation address before every upgrade** (read the proxy's implementation
slot, or the last `Upgraded` event). Without it there is no rollback path.

**After Wave 3, an upgrade takes 2 hours.** That is the point — but it must be in the runbook before
go-live, not discovered during an incident.

---

## 9. Risk register

| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| STEP2 worker treats `Paused()` as terminal and marks orders failed | Medium | High | Backend change ships **with** Wave 1; explicit retry classification (§4.3) |
| `cancelSettlement` ungated is abused to churn settlements during an incident | Low | Low | It only reverses; `settle` remains gated, so it cannot re-record |
| Paused-step smoke test skipped due to urgency | Medium | High | §7.3 is a hard gate; steps 4-5 are the deadlock proof |
| Storage slot drift in Wave 2 | Low | Critical | CI layout gate + testnet fork rehearsal |
| Wave 2 selector change leaves relayer-created orders reverting until the backend ships | High if uncoordinated | Medium | Pause/queue off-ramp creation; contract + backend in one window; `test/Migration.t.sol` documents the constraint |
| `ProxyAdmin` ownership stranded because the original admin1 key is lost mid-migration | Low | Critical | §6.2 step 2 runs first in the window |
| Timelock misconfigured (external admin retained) | Medium | High | Deploy with `admin = address(0)`; `hasRole(DEFAULT_ADMIN_ROLE, Safe) == false` is part of §8's checklist |
| Alerting not wired before go-live | Medium | Medium | §6.4 is a gate on Wave 3 completion |
| Zero-tier change exposes an unseeded tier | Low | Low | Tiers are seeded in `initialize`; zero now returns `0` rather than reverting |

---

## 10. Definition of done

- [x] Wave 0 tests written; 29 fail on `858eaf7`, 236 pass after the patch
- [ ] Wave 1 deployed; §7.3 smoke test passes including the two paused-state assertions
- [x] Mutation re-run waived by CTO; the 37 survivors are addressed by Wave 0 tests (original 78.5% stands as the last measured score)
- [ ] Wave 2 deployed; one relayer-created order verified end-to-end with a signed intent
- [x] Backend signs `OrderIntent` and holds STEP1/STEP2 on `Paused()` (`8efcabf`)
- [x] Discord governance watcher for timelock/proxy events (`dd2b2b2`)
- [ ] Wave 3 executed on-chain: Safe + timelock + `admin1` rotation + live test alert
- [x] Wave 3 rehearsed end-to-end against live Arc mainnet state on a fork (`cd076c3`)
- [x] Safe deploy script (`script/DeploySafe.s.sol`) using the canonical Arc factory
- [x] Storage-layout gate implemented (`scripts/check-storage-layout.sh`), passing locally, wired in `.github/workflows/contracts.yml`
- [x] Governance script (`script/Governance.s.sol`) and runbook (`GOVERNANCE_MIGRATION.md`)
- [ ] `AUDIT_RESPONSE.md` `<commit>` / `<tx>` placeholders replaced and re-dated
- [ ] `backlogs.md` updated with anything deferred during implementation

### 10.1 Files changed

| File | Change |
|---|---|
| `src/LiquidityProvider.sol` | Wave 1 logic patch; EIP-712 intent; `intentNonce`; NatSpec |
| `src/libraries/Types.sol` | `OrderIntentSig`; `intentSig` appended to `OrderParams`; three errors |
| `src/interfaces/ILiquidityProvider.sol` | `intentNonce(address)` |
| `test/CentiivTestBase.sol` + 11 new suites | Wave 0 coverage, PoCs, governance rehearsal |
| `script/Governance.s.sol` | Timelock deploy + Safe calldata helpers |
| `script/DeploySafe.s.sol` | Canonical-factory Safe proxy deployment + verification |
| `deploy-safe.sh`, `.env.safe.example` | Safe deployment wrapper and env template |
| `governance.sh`, `.env.governance.example` | Timelock deploy, Safe calldata, verification wrapper |
| `test/fork/GovernanceMainnetFork.t.sol` | Live-mainnet fork rehearsal of the full Wave 3 migration |
| `scripts/mutation_replay.py`, `scripts/run-mutation-shards.sh` | Replay of the auditor's exact mutant list |
| `scripts/check-storage-layout.sh`, `scripts/storage_layout_check.py`, `.storage-layout/*` | Storage gate and released baselines |
| `.github/workflows/contracts.yml` | Build, test, layout gate |
| `PROTOCOL_DOCUMENTATION.md` | 5.1.3, 5.2.2, 5.2.5, 5.2.6, 5.2.12, pause semantics, fee units |
| `GOVERNANCE_MIGRATION.md` | Wave 3 runbook |
| `EIP712_INTENT.md` | Backend signing guide for `OrderIntent` (viem example) |

---

## 11. Out of scope

Tracked in `backlogs.md`: `LiquidityManager` `reinitializer(2)` (5.2.7), `admin2` rotation co-signature,
order-ID namespacing (5.2.8), the backend dispatch fallback, and residual mutation gaps outside the
target set. Discord alerting for timelock/proxy events is a `protocol-backend` change and a Wave 3
go-live gate; the event list is in `GOVERNANCE_MIGRATION.md` §9.
