# Response to Olympix BugPoCer Lite Scan

**Repository:** `Centiiv/arc-contracts`
**Commit under review:** `858eaf7`
**Scan date:** 23 October 2026
**Response date:** 9 November 2026
**Prepared by:** Office of the CTO, Centiiv
**Companion artefacts:** `Centiiv - BugPoCer Report.pdf` (93 pp.), `Centiiv - Mutation Testing Results.csv`

> **Fill before sending:** replace `<tx>` with the governance-migration transaction once it has
> executed, and confirm the commit hash and response date. The contract fixes are in `e35e0e5`.

---

## 1. Executive summary

We have reviewed all 19 issues (39 finding sites) raised in the BugPoCer Lite report and the 172-mutant
test-quality run. We thank the team for a report that is technically precise and, in almost every case,
correct against the code.

Two context points shape our dispositions:

1. **The contracts are live on Arc mainnet** and have processed approximately 30,000 USDC. The
   deployment was made from a build that already contained the `feeBps` snapshot field and
   `Types.MAX_BPS = 100_000`; neither has changed since origin.
2. **The protocol is deliberately split into a permissive contract and a policy-enforcing relayer.**
   The contract enforces what is checkable on-chain (paused state, token registry, caller identity,
   fee caps, order state machine). Identity, LP entitlement, collateral isolation and tier
   eligibility are enforced off-chain against KYC'd counterparties. Where an invariant can be
   enforced cheaply on-chain we enforce it; where it is inherently identity- or balance-based we
   rely on the off-chain control and say so.

### Disposition

| Status | Count | Meaning |
|---|---|---|
| Fixed | 8 | Change merged; commit and test referenced |
| Accepted | 8 | Behaviour understood and intended; rationale recorded |
| Disputed | 3 | Factually incorrect, or the recommended fix would introduce new risk |

### Disposition table

| ID | Issue | Severity | Status | Reference |
|---|---|---|---|---|
| 5.1.1 | Missing pause check | Medium | Fixed | `e35e0e5` |
| 5.1.2 | Unbound relayer order creation | Medium | Fixed | `e35e0e5` |
| 5.1.3 | On-ramp orders share unreserved temp-wallet funds | Medium | Accepted (mitigated off-chain) | §3.3 |
| 5.1.4 | Upgrade struct field default zero fee | Medium | Disputed | §3.4 |
| 5.2.1 | ProxyAdmin ownership not tied to dual-admin rotation | Low | Fixed | `<tx>` |
| 5.2.2 | Single admin key bypasses dual-admin governance | Low | Accepted; docs corrected | `e35e0e5` (docs) |
| 5.2.3 | Zero tier fee accepted by setter but rejected in createOrder | Low | Fixed | `e35e0e5` |
| 5.2.4 | Pending settlements cannot be cleared while paused | Low | Fixed | `e35e0e5` |
| 5.2.5 | Per-slice fee rounding exceeds order fee cap | Low | Accepted (bounded) | §4.5 |
| 5.2.6 | Missing sender authorization emergency refund | Low | Fixed | `e35e0e5` |
| 5.2.7 | Non-atomic upgrade migration | Low | Disputed in part; hardening deferred | §4.7 |
| 5.2.8 | OrderId squatting frontrun | Low | Accepted (known low priority) | §4.8 |
| 5.2.9 | Relayer-chosen settlement recipient not bound on-chain | Low | Accepted (by design) | §4.9 |
| 5.2.10 | Unearned fee tier selection | Low | Accepted (by design) | §4.10 |
| 5.2.11 | Unvalidated self-referential authority pointer | Low | Accepted (trusted path) | §4.11 |
| 5.2.12 | Fee unit is 1/100,000 but documented as basis points | Low | Disputed as code defect; docs corrected | `e35e0e5` (docs) |
| 5.2.13 | Missing zero address check (`liquidityProvider`) | Low | Fixed | `e35e0e5` |
| 5.2.14 | Single admin can revoke recorded settlement | Low | Accepted (by design) | §4.14 |
| 5.2.15 | Unconsumed permit signature replay | Low | Fixed | `e35e0e5` |

---

## 2. Context provided to the review team

### 2.1 Deployment state

- Arc mainnet, single deployment, ~30,000 USDC processed.
- `LiquidityManager` and `LiquidityProvider` sit behind `TransparentUpgradeableProxy`; two independent
  `ProxyAdmin` contracts.
- Settlement and refund flows run continuously, so the contracts cannot be treated as greenfield for
  any storage-affecting change. Section 9 records which changes touch storage.

### 2.2 Fee scale (relevant to 5.2.12)

`Types.MAX_BPS = 100_000`, so one fee unit is 0.001%. Seeded tiers are `Basic = 400` (0.40%),
`Alpha = 300` (0.30%), `Ultimate = 200` (0.20%). `updateTierFee` caps at `10_000`, i.e. 10% — the
intentional headroom recorded during context validation. Values are internally consistent; only the
"bps" naming is wrong. See §4.12.

### 2.3 Stated trust model

| Party | Trust | Enforced by |
|---|---|---|
| `admin1`, `admin2` | Trusted | `onlyAdmin` / `onlySettingsAdmin`; `admin1` will be a 2-of-3 Safe (§6) |
| Relayer | Semi-trusted | Contract caller checks; **authoritative policy layer off-chain** |
| ProxyAdmin owner | Trusted | `Ownable`; moving to a 2-of-3 Safe behind a 2-hour timelock (§6) |
| Temp wallet key holders | Trusted for their own funds | Key custody; off-ramp keys held by Centiiv, on-ramp by the LP node |
| On-ramp order creators | **Untrusted by the contract**, KYC'd commercially | Relayer refuses to settle non-vetted orders |
| LP nodes | Untrusted by the contract, KYC'd commercially | Relayer selects payout recipients and tiers; lease engine governs capacity |

Where the report says "any address can do X", that is correct and intentional at the contract layer:
the contract does not and cannot verify KYC. Claims that identity or balances are unverified on-chain
are accurate descriptions of a documented division of responsibility, not undisclosed gaps.

### 2.4 Note on the finding counts

The report states "5 Medium / 34 Low across 19 issues / 39 finding sites". Four medium *issues* but
five medium *sites*, because 5.1.3 carries two medium sites (a: unreserved shared escrow; b:
unescrowed on-ramp wallet) plus one low site (c: cross-order allowance). Section 3.3 addresses all
three.

---

## 3. Medium findings

### 3.1 — 5.1.1 Missing pause check — **Fixed**

**Confirmed as reported.** `executeSettlementTransfer` (`LiquidityProvider.sol:198`) and
`executeRefundTransfer` (`:290`) carried no pause gate, so payouts recorded before an incident pause
could still be executed.

**Partial acceptance of the recommendation.** We did not apply `whenNotPaused` to both functions. A
blanket gate on `executeRefundTransfer` would trap refunds recorded by `emergencyRefund`, which by
design runs while paused — converting the drain into a permanent lock. The report itself anticipates
this, recommending that emergency refunds be exempted.

**Implemented — the zero-storage matrix:**

| Function | Paused behaviour |
|---|---|
| `executeSettlementTransfer` | **blocked** (`whenNotPaused`) |
| `executeRefundTransfer` | allowed — the recipient is always `order.refundAddress`, never a relayer-chosen party |
| `cancelSettlement` | allowed — pure state reversal, moves no tokens |

This closes the drain while guaranteeing no funds can be trapped: every paused state now has an exit
(`cancelSettlement` → `emergencyRefund` → `executeRefundTransfer`). It is a logic-only change with no
new storage.

**Test:** `test/poc/ExecuteTransfers_MissingPauseGate.t.sol`
(`testPoc_SettlementTransferRevertsWhilePaused`) and the paused-state matrix in
`test/LiquidityProvider.pause.t.sol`.

---

### 3.2 — 5.1.2 Unbound relayer order creation — **Fixed**

**Confirmed and accepted as the most material finding.** `createOrder`'s caller guard (`:89`) admits
the relayer for any `params.sender`, and the destination guard (`:94`) only runs on the
`msg.sender == params.sender` branch. Neither the EIP-2612 permit nor an ERC-20 allowance commits to a
destination, so a compromised relayer could move any outstanding allowance to a wallet it named.

**Implemented — EIP-712 order intent.** When `msg.sender != params.sender`, `createOrder` now requires
a signature from `params.sender` over:

```
OrderIntent(
  bytes32 orderId, address token, int256 amount,
  address temporaryWalletAddress, address refundAddress,
  uint8 protocolFee, uint256 deadline, uint256 nonce )
```

bound to a domain separator of `(name, version, chainId, address(this))` with a per-sender,
monotonic `intentNonce` (a consumed nonce can never be replayed; gaps are permitted). The intent proves
what the sender authorised; the permit or allowance continues to move the tokens. The two mechanisms
coexist deliberately. The domain constants require no storage and no initializer migration on the live
proxy.

**Why not the cheaper fix.** Constraining `refundAddress == params.sender` was evaluated and rejected:
the tokens land in the attacker's temp wallet at `transferFrom` time, so forcing the refund address
recovers nothing already moved. It would add a deployment-sequencing hazard across backend and
contract for negligible benefit.

**Scope:** the self path (`msg.sender == params.sender`) is unchanged and needs no signature.

**Deployment note:** the signature is carried in an appended `OrderParams` field, so the
`createOrder` selector changes. The contract upgrade and the backend release ship in one
coordinated window; relayer-created off-ramp orders are unavailable for that window,
while on-ramp orders, settlement, refunds and emergency refunds are unaffected.

---

### 3.3 — 5.1.3 On-ramp orders share unreserved temp-wallet funds — **Accepted (mitigated off-chain)**

**Confirmed for sites (a) and (b).** Because `:94` forces `temporaryWalletAddress == msg.sender` on the
on-ramp path, the funding call at `:102` is `transferFrom(L, L, amount)` — a self-transfer that
reserves nothing.

**We decline on-chain uniqueness.** The proposed remedy — one open order per destination wallet — was
prototyped and rejected on two grounds: it caps every LP node at a single concurrent on-ramp order
(a regression for vetted, high-volume LPs), and it permanently bricks a wallet whose order is
abandoned. It also adds a storage slot to a live proxy for no capability the off-chain control lacks.

**Site (a) — allocation-time double-booking: mitigated off-chain.** Collateral isolation is enforced
by the routing lease engine before an order is created:

- Capacity check and booking are atomic in a single Redis Lua transaction
  (`src/routing/leases/redis-lua/acquire-lease.lua`).
- Routing computes availability as reported balance less active leases, floored at zero
  (`src/routing/node-liquidity.service.ts`).
- A node is therefore never allocated beyond its unreserved funds; the dispatch code documents this
  exact double-allocation risk as the reason the reservation exists
  (`fulfillment-processing.service.ts:920-929`).

We note for completeness that the dispatch fallback path is best-effort — a refused reservation logs
and dispatches anyway. That path is treated internally as an anomaly to be fixed, not a supported
mode.

**Site (b) — funds moved after `settle`: accepted residual.** This is **not** addressed by the
reservation engine; it is a property of holding escrow in a key-controlled wallet. Residual mitigation:
the backend re-checks live allowance immediately before requesting the payout, LPs are KYC'd
counterparties with commercial recourse, and per-order wallets are used on the off-ramp path. We
state this as accepted risk rather than claiming it is eliminated. Removing it entirely would require
contract custody, which is a deliberate architectural non-goal.

**Site (c) — cross-order allowance consumption: subsumed by (a).** With allocation-time isolation, one
order's execution can no longer consume the allowance another order depends on.

**Documentation correction accepted:** `PROTOCOL_DOCUMENTATION.md` §4.1 asserted a dedicated
order-bound escrow for every order. That is true for off-ramp and false for on-ramp. The documentation
is corrected to describe each path accurately.

---

### 3.4 — 5.1.4 Upgrade struct field default zero fee — **Disputed**

**The described impact cannot occur on this codebase.** `feeBps` has been a member of `Types.Order`
since the repository's initial commit (`3a63098`), and `Types.MAX_BPS` has been `100_000` since origin.
No deployed implementation of `LiquidityProvider` ever wrote an `Order` without a `feeBps` field, so
there is no population of legacy orders for which it reads zero.

We also **decline the recommended fallback** (`feeBps == 0` → use `tierFees[tier]`). It would collide
with the fix for 5.2.3: a legitimate zero-rated tier also produces `feeBps == 0`, so the fallback would
reinterpret a valid promotional order as legacy and charge whatever the tier rate happens to be at
settlement time — breaking the "fee locked at creation" invariant. Adding code to fix a non-existent
class of order, at the cost of corrupting a real one, is not a trade we will make.

**Request:** if the reviewer has evidence of a deployed implementation predating `3a63098`, we will
re-examine; our repository history does not contain one.

---

## 4. Low findings

### 4.1 — 5.2.1 ProxyAdmin ownership not tied to dual-admin rotation — **Fixed**

**Confirmed.** `transferAdmin1` / `acceptAdmin1` wrote only `LiquidityManager.admin1`. The two
`ProxyAdmin` contracts retained their original `Ownable` owner, so rotating `admin1` did not retire the
old key's unilateral upgrade authority — the one scenario rotation exists to handle.

**Implemented:**

- Both `ProxyAdmin` contracts are owned by a **2-of-3 Safe** (`admin1`, `admin2`, `recovery`), behind
  an OpenZeppelin `TimelockController` with a 2-hour delay. Upgrade chain:
  `Safe → Timelock → ProxyAdmin → proxy`.
- `admin1` on-chain is set to the Safe, so `transferAdmin1`, `acceptAdmin1` and `updateSettingsContract`
  now require Safe quorum. Operational actions (`pause`, `unpause`, `updateProtocolAddress`,
  `setTokenSupported`, `updateTierFee`) remain single-key via `admin2`, preserving instant incident
  response.
- Admin rotation is a documented two-step procedure: on-chain transfer **and** Safe signer swap. Neither
  alone completes a rotation.

**Residual, stated:** `transferAdmin2` remains `onlyAdmin2`. Closing it requires a contract change and
is tracked in `backlogs.md`.

`<tx>` records the migration.

---

### 4.2 — 5.2.2 Single admin key bypasses dual-admin governance — **Accepted; documentation corrected**

**Code confirmed as reported.** `onlyAdmin` (either key) gates `updateProtocolAddress`,
`setTokenSupported`, `pause`, `unpause`; `onlySettingsAdmin` (either key) gates `updateTierFee`;
`admin1` alone gates `updateSettingsContract`. This is the intended operating model and was stated
during context validation.

**Conceded as a documentation defect.** The documentation claimed sensitive changes require both
admins. It is corrected to describe the deployed behaviour.

**Partially mitigated by 5.2.1:** with `admin1` set to a 2-of-3 Safe, the highest-privilege paths
(`updateSettingsContract`, admin rotation) now require quorum. We deliberately keep `pause` single-key
— a pause that requires three signatures is a pause that does not happen.

**Residual:** a single compromised `admin2` key can set itself as relayer and settle open orders to
itself. Primary control is key custody. Dual signatures on every parameter were rejected as a
liveness/availability trade we are not willing to make for a Low-severity governance property.

---

### 4.3 — 5.2.3 Zero tier fee accepted by setter but rejected in createOrder — **Fixed**

**Confirmed.** `updateTierFee` accepted `0` (`:387` rejects only `< 0 || > 10_000`) while
`_calculateProtocolFee` reverted `FeePercentNotSet` on a zero rate (`:409`). Setting a promotional
zero-fee tier would have halted order creation for that tier.

**Implemented:** zero is treated as a valid rate and returns `0` fee. Tier values are seeded in
`initialize` and preserved across upgrades, so no "unset tier" state existed for the revert to protect
against. `FeePercentNotSet` remains declared for interface compatibility.

---

### 4.4 — 5.2.4 Pending settlements cannot be cleared while paused — **Fixed**

**Confirmed.** `cancelSettlement` was `whenNotPaused` (`:239`) and `emergencyRefund` reverts
`PendingSettlementExists` (`:358`), so an order with a recorded settlement had exactly one exit during
a pause: the un-gated execute function — the 5.1.1 drain path.

**Implemented:** `cancelSettlement` is no longer pause-gated. It performs only a state reversal and
moves no tokens, so pausing it served no protective purpose while creating a trap. Combined with 5.1.1
this eliminates the deadlock entirely: `cancelSettlement` → `emergencyRefund` → `executeRefundTransfer`
is always available.

**Residual, stated:** `refund()` remains `whenNotPaused`, so during a pause the relayer cannot record a
standard refund. Emergency refund is the intended path.

---

### 4.5 — 5.2.5 Per-slice fee rounding exceeds order fee cap — **Accepted (bounded)**

**Confirmed, accepted, not remediated.** `_calculateProtocolFeeFromBps` rounds each slice up
independently, so aggregate fees can exceed `ceil(total × feeBps / 100_000)` by at most `n − 1` base
units, where `n` is the number of slices. With 6-decimal USDC that is a handful of micro-USDC per order,
accruing to the treasury rather than being lost.

Not changed because the alternative — cumulative-fee accounting — would add state to a live proxy for
an immaterial amount and would weaken the stated "protocol never loses on rounding" property. The bound
is now documented in NatSpec.

---

### 4.6 — 5.2.6 Missing sender authorization emergency refund — **Fixed**

**Confirmed as a documentation/code mismatch.** `emergencyRefund` accepted relayer, `admin1`, `admin2`
(`:350`); `order.sender` could not trigger it, contrary to `PROTOCOL_DOCUMENTATION` §4.3.

**Implemented:** `msg.sender == order.sender` is now accepted. The `PendingSettlementExists` guard still
applies, so a sender cannot use this to unseat a live settlement.

---

### 4.7 — 5.2.7 Non-atomic upgrade migration — **Disputed in part; hardening deferred**

**Partly disputed.** The report states that "the README mentions an `upgrade.sh`, but no such file is in
the repo". `scripts/upgrade.sh` is present in the repository, and its `seed_supported_tokens` step
(lines 229-268) invokes `script/SetSupportedTokens.s.sol` **between** the `LiquidityManager` and
`LiquidityProvider` upgrades, aborting with `exit 1` if seeding fails. The failure mode described — LP
upgraded against an empty registry, blocking every `createOrder` — is operationally prevented today.

**Accepted:** the protection is procedural rather than atomic, and depends on the operator using
`scripts/upgrade.sh`.

**Deferred:** a `reinitializer(2)` that seeds USDC/EURC and is invoked through `upgradeAndCall` on the
`LiquidityManager` upgrade. This requires a second proxy upgrade and is tracked in `backlogs.md`.

---

### 4.8 — 5.2.8 OrderId squatting frontrun — **Accepted (known low priority)**

**Confirmed, accepted.** `createOrder` is first-writer-wins on a caller-supplied `orderId` (`:85`), open
to any address on the self path.

**Impact is denial only.** A squatter receives an order it cannot settle — the relayer settles only
orders it routed. A legitimate `createOrder` reverts `OrderAlreadyExists`, which the backend treats as a
failed attempt and retries with a fresh ID.

**Cost to the attacker is material:** each squatted ID writes a full `Order` struct (roughly 13–14
storage slots, several hundred thousand gas), and the cost does not compound.

**Why not fixed:** the only real remedy is namespacing the key (`keccak256(abi.encode(sender, orderId))`)
or deriving the ID in-contract, both of which change the order-ID contract shared with
`protocol-backend` and `protocol-node`. No security gain justifies that coordination. Recorded in
`backlogs.md` as a known low-priority issue.

---

### 4.9 — 5.2.9 Relayer-chosen settlement recipient not bound on-chain — **Accepted (by design)**

**Confirmed and accepted.** `_settle` stores the caller-supplied `liquidityProvider` with no registry
check, so a compromised relayer can direct any funded order's payout to an arbitrary address.

This is the direct consequence of the design decision that the relayer is the authoritative settlement
router (§2.3). Binding it on-chain requires an admin-maintained LP allowlist, which adds a governance
dependency and a liveness failure mode — a delisted LP would block settlement of live orders — for a
risk already governed by relayer key custody and LP KYC. The 5.1.2 work removes the adjacent
arbitrary-*deposit* exposure, which was the more valuable half.

---

### 4.10 — 5.2.10 Unearned fee tier selection — **Accepted (by design)**

**Confirmed and accepted.** `createOrder` records the caller-supplied tier (`:105`, `:120`); the contract
does not verify entitlement.

Tier entitlement is an identity and billing fact the contract cannot establish. The relayer refuses
orders carrying an unearned tier, and LP tiers are commercial agreements with KYC'd counterparties.
Same model as 5.2.2 and 5.2.9. Note that the 5.2.3 fix (a valid zero-rate tier) does not widen this.

---

### 4.11 — 5.2.11 Unvalidated self-referential authority pointer — **Accepted (trusted path)**

**Confirmed.** `updateSettingsContract` (`:396`) checks only non-zero and `msg.sender == getAdmin1()`;
it does not verify that the new address implements the expected interface.

**Accepted as a trusted escape hatch**, as validated during context: `admin1` is trusted to supply a
correct address, and the function exists to recover from a broken settings contract. A two-step accept
would add friction to the one path designed to be fast during an emergency.

NatSpec now warns that a mispointed `settingsContract` disables all state-changing paths and that
recovery requires a further call from `admin1` reading admins from the *new* contract — so the pointer
must be correct at the moment of the call. With 5.2.1 in place, this path additionally requires Safe
quorum.

---

### 4.12 — 5.2.12 Fee unit is 1/100,000 but documented as basis points — **Disputed as a code defect; docs corrected**

**Accepted as a documentation defect. The recommended code change is declined.**

The values are correct: `MAX_BPS = 100_000` with tiers `400 / 300 / 200` are 0.40% / 0.30% / 0.20%.
Nothing is under-charging today.

**Why we will not change `MAX_BPS` to `10_000`:** `order.currentBps` is written as `MAX_BPS` at creation
(`:116`) and decremented per settlement slice (`:170`). On a live proxy with open orders, changing the
constant invalidates the accounting of every in-flight order and would mis-settle live principal. This
is the single most dangerous remediation in the report for our deployment.

**Implemented:** documentation and NatSpec now state the unit explicitly — "fee units, 1 unit = 0.001%,
denominator 100,000" — with worked examples (`400 = 0.40%`). Code renaming (`MAX_BPS` → `MAX_FEE_UNITS`,
`feeBps` → `feeUnits`) is deferred to a coordinated migration because it changes the `orders`
auto-getter ABI consumed by the frontend.

---

### 4.13 — 5.2.13 Missing zero address check on `liquidityProvider` — **Fixed**

**Confirmed.** `_settle` accepted `address(0)` as the payout recipient, producing a pending settlement
that cannot execute. We note the impact is recoverable rather than permanent: the transfer reverts and
rolls back the deletion of the pending record, after which `cancelSettlement` restores the order.

**Implemented:** `if (liquidityProvider == address(0)) revert ZeroAddress();` at the start of `_settle`.

---

### 4.14 — 5.2.14 Single admin can revoke recorded settlement — **Accepted (by design)**

**Confirmed and accepted.** `cancelSettlement` accepts `admin1` or `admin2` alone (`:239`).

An intentional emergency brake, validated as acceptable during context. Cancellation restores the order
to its pre-settlement state and does not redirect funds: the restored principal can only be settled to a
relayer-chosen recipient or refunded to `order.refundAddress`. An admin cannot pay itself. With 5.2.1 in
place, admin-initiated cancellation inherits Safe-level key custody.

---

### 4.15 — 5.2.15 Unconsumed permit signature replay — **Fixed**

**Confirmed.** `_permitIfProvided` (`:329`) returned early when the existing allowance already covered
`value`, leaving a supplied signature's nonce unconsumed and its `(v, r, s)` published in calldata. The
signature stayed replayable until its deadline, and the owner's next permit reuses the same nonce.

**Implemented:** when a signature is supplied, `permit` is always attempted inside the existing
`try/catch`; a revert is tolerated only if the post-attempt allowance covers `value`. This consumes the
nonce instead of leaving a live signature, and remains tolerant of a front-run permit submission.

No storage impact; existing signature-less flows (`r == 0`) are unchanged.

---

## 5. Mutation testing

### 5.1 Result

172 mutants, 135 killed, 37 survived — **78.5%**.

We agree with the framing that survivors indicate test-suite blind spots rather than vulnerabilities:
every surviving mutant corresponds to code that is either correct today or non-security-relevant. All
37 have been classified.

### 5.2 Classification

| Category | Count | Assessment | Action |
|---|---|---|---|
| Event emissions deleted | 16 | Not security-relevant; no `expectEmit` assertions exist | `vm.expectEmit` added for state-changing admin and order functions |
| `initialize` validation (`ZeroAddress`, `admin1 == admin2`, `initializer`) | 8 | **Genuine gap** | Revert tests added per branch; double-initialise test added |
| `whenNotPaused` removed from `settle` (×2) and `refund` | 3 | **Genuine gap** | Pause tests added for both `settle` overloads and `refund` |
| `storage` → `memory` | 3 | **Genuine gap** — silent no-op writes | State assertions added after each phase, not just balances |
| Ceiling rounding in both fee helpers | 4 | **Genuine gap** | Fractional-fee unit tests added |
| `onlyPendingAdmin2` removed from `acceptAdmin2` | 1 | Asymmetry; `acceptAdmin1` is covered | Admin2 acceptance test added |
| `onlyRelayer` mutated (dead modifier) | 1 | Dead code | Modifier deleted |
| `settlePercent <= 0 \|\| > MAX_BPS` → `&&` | 1 | Boundary not exercised | Boundary tests added |

### 5.3 Result after remediation

The suite now includes the auditor's Proof-of-Concept tests under `test/poc/`, retained permanently as
regression tests, plus the coverage gaps above. We have not re-run the mutation suite; the original
78.5% remains the last measured score. Each of the 37 surviving mutants falls into one of the
categories above and now has an explicit test or a deleted/dead construct. A re-run is available on
request rather than claimed as complete.

---

## 6. Governance and upgrade authority

| Control | Implementation |
|---|---|
| Upgrade authority | 2-of-3 Safe (`admin1`, `admin2`, `recovery`) owns both ProxyAdmins |
| Delay | OpenZeppelin `TimelockController`, `minDelay = 2 hours`, between Safe and ProxyAdmin |
| `admin1` | Set to the Safe, so admin rotation and `updateSettingsContract` require quorum |
| Incident response | `pause()` remains single-key and instant; the sequence is pause → schedule → 2h → execute |
| Monitoring | Backend watchers alert Discord on `CallScheduled` / `Cancelled` / `Executed`, proxy `Upgraded`, ProxyAdmin `OwnershipTransferred` and `AdminChanged` |

A 2-of-3 was chosen over 2-of-2 so that loss of a single key cannot permanently disable upgrades.
Timelock roles are configured at deployment with no external admin: the controller is deployed with
`admin = address(0)`, so the only `DEFAULT_ADMIN_ROLE` holder is the timelock itself and even a delay
change must pass through the 2-hour window.

---

## 7. Issues identified by us

### 7.1 Dead `onlyRelayer` modifier and a stale comment — **Fixed**

`LiquidityProvider.onlyRelayer` (`:35-39`) was declared but never applied; all relayer checks are
inline. The comment at `:73-74` claimed `settle()` and `refund()` "still enforce `onlyRelayer`", which
was false. The modifier is deleted and the comment corrected. This also removes one surviving mutant.

### 7.2 EURC gas is USDC-denominated while fees accrue in EURC — **Noted, operational**

On Arc, gas is paid in native USDC regardless of the ERC-20 moved, and temp wallets never pay gas: the
relayer submits off-ramp transfers and the LP node submits on-ramp STEP2. Protocol fees on a EURC order
accrue to the treasury in EURC. Every EURC order is therefore gas-negative in USDC unless the fee covers
it. Not a contract defect; recorded for the pricing model.

### 7.3 Refund amount is remaining principal, not nominal principal — **Documentation corrected**

`refund` records `refundAmount = order.amount`, the remaining principal after any partial settlements,
while the documentation described a 100% nominal refund. Behaviour is correct for a partially settled
order; the documentation now states the distinction.

---

## 8. Verification

1. Every "Fixed" item ships with a test that fails on the pre-fix code and passes after it.
2. The auditor's PoCs are retained under `test/poc/` and run in CI.
3. Each fix references its merge commit; the governance migration references its transaction.
4. The mutation score is reported as measured at scan time (78.5%); the survivor categories are now covered by explicit tests, and a re-run is available on request.
5. We invite a re-scan against the post-fix commit.
6. We request clarification on 5.1.4 (§3.4) and on the `upgrade.sh` absence claim in 5.2.7 (§4.7).

---

## 9. Upgrade and storage-layout notes

| Change | Storage impact |
|---|---|
| 5.1.1 / 5.2.4 — pause matrix | **None.** Logic only. |
| 5.2.3, 5.2.6, 5.2.13, 5.2.15, 7.1 | **None.** Logic only. |
| 5.1.2 — `intentNonce` mapping | Appended, consuming `__gap` (slot 6); a fresh `uint256[50]` follows. The EIP-712 domain uses constants and no storage. |
| 5.2.1 — governance migration | No contract storage. Two `ProxyAdmin` ownership transfers plus an `admin1` rotation. |
| 5.2.12 | Documentation only. `MAX_BPS` **unchanged**. |

A storage-layout regression gate (`forge inspect … storageLayout`, diffed against the last released
layout) has been added to CI so slot drift cannot ship silently.

---

## 10. Sign-off

We consider the report a fair and accurate assessment of the contracts as scanned, and we are grateful
for the PoCs — they materially shortened our remediation work. Where we have declined a recommendation
(5.1.3 custody, 5.1.4 fallback, 5.2.12 constant change, 5.2.9/5.2.10 on-chain enumeration) the
alternative would either mis-account live orders or convert a commercial control into a governance
dependency.

Signed for Centiiv:

**_________________________**
Chief Technology Officer
9 November 2026
