# Governance Migration Runbook — Wave 3

**Audit items:** 5.2.1 (ProxyAdmin ownership), 5.2.2 (single-key governance), 5.2.5
(monitoring)
**Prerequisite:** Waves 1 and 2 are deployed and verified. A timelock in front of an
unpatched implementation delays the patch.

---

## 1. Target topology

```
Safe (2-of-3: admin1, admin2, recovery)
  └── TimelockController (minDelay = 7200s)
        ├── ProxyAdmin (LM) ──> LiquidityManager proxy
        └── ProxyAdmin (LP) ──> LiquidityProvider proxy
```

`LiquidityManager.admin1` is also set to the Safe. `admin2` remains a single key so
`pause()` stays instant; everything that can change the upgrade or settings pointer
requires quorum.

The timelock is deployed with `admin = address(0)`. OpenZeppelin still grants
`DEFAULT_ADMIN_ROLE` to the timelock contract itself, so changing the delay or roles
requires a timelocked operation. There is no external admin key to renounce.

---

## 2. Preconditions

- [ ] Safe deployed with threshold 2 and owners `admin1`, `admin2`, `recovery`
      (three **distinct** keys, ideally on different hardware).
- [ ] `getThreshold()` returns 2; `getOwners()` matches the three addresses.
- [ ] Both Waves 1 and 2 are live and the §7.3 smoke test passed.
- [ ] The current `ProxyAdmin` owner key (original `admin1` EOA) is available.
      This is the last moment to move it; if the key is lost first, upgrade authority
      is stranded permanently.
- [ ] Discord webhook tested with a synthetic alert.

Environment for the scripts:

```sh
export SAFE_ADDRESS=0x...
export LM_PROXY_ADMIN=0x...
export LP_PROXY_ADMIN=0x...
export LM_PROXY=0x...
export LP_PROXY=0x...
export TIMELOCK_MIN_DELAY=7200
```

---

## 3. Move ProxyAdmin ownership from the EOA to the Safe

Do this first. The Safe cannot prove control of a `ProxyAdmin` it does not own, and the
original `admin1` EOA key is the only thing that can make this transfer.

```sh
forge script script/Governance.s.sol:GovernanceScript \
  --sig printProxyAdminTransfers -vv
```

Send the two printed transactions from the original `admin1` EOA. After they land:

- `ProxyAdmin(LM).owner() == SAFE_ADDRESS`
- `ProxyAdmin(LP).owner() == SAFE_ADDRESS`
- No further upgrade can be sent by a single EOA.

## 4. Prove Safe control (no-op upgrade)

Before handing ownership to the timelock, execute one no-op upgrade from the Safe for
each proxy. This proves quorum can drive the `ProxyAdmin` at all, and emits
`Upgraded(currentImplementation)`.

```sh
export PROXY_ADMIN="$LP_PROXY_ADMIN"
export PROXY="$LP_PROXY"
export IMPLEMENTATION=<current LP implementation>
forge script script/Governance.s.sol:GovernanceScript --sig printNoopUpgrade -vv
```

Repeat with the LM variables. Read the current implementation from the proxy's
implementation slot or the last `Upgraded` event. A no-op upgrade must not change any
state; verify `LiquidityProvider.usdc()` / `settingsContract()` before and after.

## 5. Deploy the timelock

```sh
forge script script/Governance.s.sol:GovernanceScript \
  --rpc-url "$RPC_URL" --broadcast -vv
```

Record the deployed `TimelockController` address as `TIMELOCK`.

Verification before §6: the ProxyAdmins are owned by the Safe, `admin1` is still the
EOA, and the timelock reports `minDelay = 7200`, Safe has
`PROPOSER`/`EXECUTOR`/`CANCELLER`, Safe does **not** have `DEFAULT_ADMIN_ROLE`.

## 6. Move ProxyAdmin ownership to the timelock

Two Safe transactions. After they execute, **every** upgrade takes at least two hours.
That is the intended control, not an incident-time surprise.

```sh
forge script script/Governance.s.sol:GovernanceScript \
  --sig printTimelockTransfers -vv
```

Paste each printed `to` / `value` / `data` into Safe{Wallet} → Transaction Builder,
collect 2-of-3 signatures, execute.

## 7. Rotate `admin1` to the Safe

Two transactions, two different signers.

1. Current `admin1` EOA, direct transaction to `LM_PROXY`:
   `transferAdmin1(SAFE_ADDRESS)`.
2. Safe transaction to `LM_PROXY`: `acceptAdmin1()`.

```sh
forge script script/Governance.s.sol:GovernanceScript \
  --sig printAdmin1Rotation -vv
```

Consequences:

- `transferAdmin1`, `acceptAdmin1`, `updateSettingsContract` now require Safe quorum.
- `pause`, `unpause`, `updateProtocolAddress`, `setTokenSupported`, `updateTierFee`
  remain single-key via `admin2`.

**Known gap:** `transferAdmin2` is still `onlyAdmin2`; see `backlogs.md`. Treat the
`admin2` key as a governance key and keep it in the same custody class.

## 8. Verification checklist

```sh
forge script script/Governance.s.sol:GovernanceScript --sig verify -vv
```

- [ ] `LM ProxyAdmin owner == TIMELOCK`
- [ ] `LP ProxyAdmin owner == TIMELOCK`
- [ ] `LiquidityManager.admin1 == SAFE_ADDRESS`
- [ ] `TimelockController.getMinDelay() == 7200`
- [ ] Safe holds `PROPOSER`, `EXECUTOR`, `CANCELLER`
- [ ] Safe does **not** hold `DEFAULT_ADMIN_ROLE`
- [ ] `pause()` from `admin2` still works; `pause()` from the old `admin1` reverts
- [ ] A test upgrade on testnet was scheduled, waited two hours, and executed

---

## 9. Alerting (protocol-backend → Discord)

An unmonitored timelock is a delay, not a control. Wire these before declaring Wave 3
complete:

| Contract | Event | Why it matters |
|---|---|---|
| Timelock | `CallScheduled(bytes32 id, uint256 index, address target, uint256 value, bytes data, bytes32 predecessor, uint256 delay)` | **The alert that matters.** An unexpected scheduled call is an incident |
| Timelock | `Cancelled(bytes32 id)` | Confirms a rogue operation was stopped |
| Timelock | `Executed(bytes32 id, address target, uint256 value, bytes data)` | Confirms what actually landed |
| Timelock | `MinDelayChange(uint256 oldDuration, uint256 newDuration)` | Must always be paired with a scheduled call |
| Both proxies | `Upgraded(address indexed implementation)` | Detects an implementation swap |
| ProxyAdmin | `OwnershipTransferred(address indexed previousOwner, address indexed newOwner)` | Detects an ownership move back to an EOA |
| ProxyAdmin | `AdminChanged(address previousAdmin, address newAdmin)` | Detects a proxy admin swap |

The watcher should post to Discord with: event name, transaction hash, block number,
decoded arguments, and a link to the explorer. Send one synthetic alert and confirm it
arrives before closing the migration.

`CallScheduled` is the page-worthy event; the rest are informational. A `Cancelled`
event without a preceding internal change-freeze is suspicious in the other direction.

---

## 10. Rollback

| Stage | Rollback | Cost |
|---|---|---|
| Before §5 | `ProxyAdmin.transferOwnership` back to the EOA | Immediate |
| After §5, before §6 | Safe schedules `ProxyAdmin.transferOwnership(EOA)` through the timelock | 2 hours |
| After §6 | Same timelocked ownership transfer, then `LM.transferAdmin1(EOA)` from the Safe and `acceptAdmin1()` from the EOA | 2 hours + two steps |

Rollback of a *contract* upgrade is also timelocked after §5:
`ProxyAdmin.upgradeAndCall(proxy, previousImplementation, "")`, scheduled and executed
after two hours. This is why the pre-upgrade implementation address must be recorded
before every upgrade.

---

## 11. Failure modes to watch

| Symptom | Likely cause | Action |
|---|---|---|
| `AccessControlUnauthorizedAccount` on execute | Safe lacks `EXECUTOR_ROLE`, or 2-of-3 signatures missing | Check roles; collect another signature |
| `TimelockUnexpectedOperationState` on execute | Delay not elapsed, or operation not scheduled | Check `getTimestamp(id)`; wait |
| `TimelockUnexpectedOperationState` on schedule | Same operation id already scheduled | Reuse or change the salt |
| Upgrade rejected by ProxyAdmin | Timelock is not the ProxyAdmin owner yet | Complete §5 first |
| `admin1` rotation cannot be accepted | `acceptAdmin1` sent by old admin instead of the Safe | Send from the Safe |
