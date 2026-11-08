# Backlog

Items consciously deferred, accepted as known issues, or scheduled outside the current audit-response
work. Ordered by rough priority.

---

## 1. CI: enforce storage-layout compatibility on every upgrade

**Why:** we upgrade two live proxies (`LiquidityManager`, `LiquidityProvider`). Slot comments rot, and a
reordered or inserted variable silently corrupts live state. A generated diff does not rot.

**What:**

- On every PR and release build, generate the layout:
  ```sh
  forge inspect LiquidityProvider storageLayout --json > .storage-layout/lp.json
  forge inspect LiquidityManager   storageLayout --json > .storage-layout/lm.json
  ```
- Commit the generated files, or store them as build artefacts.
- Diff against the last released layout. Fail the build on any change to an **existing** variable's
  slot, offset, or type. Additions at the end (and `__gap` shrinkage) are allowed with an explicit
  override label, e.g. `storage-change-approved`.
- Run it in the same job as `forge test` so it cannot be skipped.

**Notes:**

- Current `LiquidityProvider` layout (OZ 5.7.0; `Initializable` uses ERC-7201 namespaced storage and
  consumes **no** sequential slot):

  | Slot | Variable |
  |---|---|
  | 0 | `settingsContract` |
  | 1 | `usdc` |
  | 2 | `orders` |
  | 3 | `pendingSettlements` |
  | 4 | `pendingRefunds` |
  | 5 | `tierFees` |
  | 6 | `intentNonce` (added by 5.1.2) |
  | 7–56 | `__gap` (`uint256[50]`) |

- Any new state variable must **replace** gap space and be followed by a fresh gap declaration.
  Never insert before an existing variable.

**Status:** implemented. `scripts/check-storage-layout.sh` diffs `forge inspect` against
`.storage-layout/*.prev.json`, `.github/workflows/contracts.yml` runs it with the tests, and the
baseline snapshot is updated only after a successful upgrade.

---

## 2. Known low-priority issue: `orderId` squatting

**Finding reference:** BugPoCer 5.2.8 (Low).

- `createOrder` accepts a caller-supplied `orderId` and is first-writer-wins (LP:84-85). Any address
  can register an unused ID.
- **Impact is denial only.** The squatter receives an order it cannot settle — the relayer settles only
  orders it routed. A legitimate `createOrder` reverts `OrderAlreadyExists`, and the backend retries
  with a fresh ID.
- **Cost to the attacker is not trivial:** each squatted ID writes a full `Order` struct
  (~13-14 storage slots, a few hundred thousand gas). It does not compound.
- **Why we are not fixing it:** the only real fix is namespacing the key
  (`keccak256(abi.encode(sender, orderId))`) or deriving the ID in-contract, both of which change the
  order-ID contract shared with `protocol-backend` and `protocol-node`. No security gain to justify
  the coordination cost.

**Decision:** accepted. Documented in `AUDIT_RESPONSE.md` as a known low-priority issue.

**Status:** accepted, no action.

---

## 3. `LiquidityManager` reinitializer for token-registry seeding

**Finding reference:** BugPoCer 5.2.7 (Low) — partially disputed.

- `upgrade.sh` already seeds USDC/EURC via `script/SetSupportedTokens.s.sol` between the
  `LiquidityManager` and `LiquidityProvider` upgrades, aborting if seeding fails. The failure mode the
  finding describes is therefore operationally prevented.
- Residual gap: the protection is procedural (a shell script), not atomic. An operator running
  `forge script` directly would bypass it.
- **Proposed fix:** add a `reinitializer(2)` migration that seeds USDC/EURC and invoke it through
  `upgradeAndCall` on the `LiquidityManager` upgrade, so the invariant is enforced by the contract.
- Deferred because it requires a **second** proxy upgrade (`LiquidityManager`) and is not urgent given
  the script coverage.

**Status:** deferred. Target: next `LiquidityManager` upgrade.

---

## 4. Mutation-testing coverage gaps

**Finding reference:** Olympix mutation run — 37 of 172 mutants survived (78.5%).

Not security defects; test-suite blind spots. Priority items:

- `initialize` validation on both contracts (zero-address branches, `admin1 == admin2`, `initializer`
  re-entry).
- `whenNotPaused` on both `settle` overloads and `refund`.
- Ceiling-division rounding in `_calculateProtocolFee` / `_calculateProtocolFeeFromBps`
  (`remainder > 0`, `feeWhole += 1`).
- State assertions, not just balance assertions, where `storage` → `memory` mutants survive.
- `acceptAdmin2`'s `onlyPendingAdmin2` (asymmetric with `acceptAdmin1`, which is covered).
- `vm.expectEmit` coverage for state-changing functions.

**Status:** Wave 0 tests added (`test/LiquidityProvider.*.t.sol`, `test/LiquidityManager.*.t.sol`).
The mutation run has not been re-executed; target remains ≥ 90%.

---

## 5. Dead code: `LiquidityProvider.onlyRelayer`

- The modifier (LP:35-39) is declared but never applied; all relayer checks are inline.
- The comment at LP:73-74 claims `settle()` and `refund()` "still enforce `onlyRelayer`", which is
  false.
- Trivial cleanup: delete the modifier, correct the comment. Also removes one surviving mutant.

**Status:** implemented in Wave 1 — modifier deleted, comment corrected.

---

## 6. `transferAdmin2` remains single-key

**Finding reference:** residual of 5.2.1 / 5.2.2.

- After Wave 3, `admin1` is the 2-of-3 Safe, so `transferAdmin1`, `acceptAdmin1` and
  `updateSettingsContract` require quorum.
- `transferAdmin2` is still `onlyAdmin2`, so a single `admin2` key can nominate its own
  successor (and `acceptAdmin2` completes it from the new key). It cannot upgrade the
  proxy or change the settings pointer.
- **Proposed fix:** require co-signature from `admin1` on `transferAdmin2`, or move
  `admin2` rotation into the timelock. Either is a contract change; deferred because
  the practical control is key custody and `admin2` is already a governance-class key.

**Status:** accepted residual, documented in `AUDIT_RESPONSE.md` §4.1.

---

## 7. Backend dispatch fallback is best-effort

**Finding reference:** 5.1.3(a) residual.

- The Redis lease engine's capacity check and booking are atomic, but the dispatch
  fallback path logs "dispatching without a reservation" and proceeds
  (`fulfillment-processing.service.ts:968-972`).
- This is an internal anomaly path, not a supported mode. It does not invalidate the
  on-chain acceptance of 5.1.3, but it must not be treated as a guarantee.
- **Proposed fix:** make the fallback fail closed or page; remove the bypass once the
  lease service is the only dispatcher.

**Status:** open in `protocol-backend`; tracked outside this repository.
