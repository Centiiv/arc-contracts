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

### 2.1 How the Safe is deployed on Arc

A Safe is not one contract. The **Safe singleton, `SafeProxyFactory` and
`CompatibilityFallbackHandler` are already deployed at their canonical v1.4.1
addresses on Arc mainnet (5042) and testnet (5042002)** — Safe's public deployment
registry marks both chains as canonical. You deploy **one proxy per Safe** through the
canonical factory; the singleton is shared by every Safe on the chain.

| Contract | Canonical address (Arc) |
|---|---|
| Safe singleton (v1.4.1) | `0x41675C099F32341bf84BFc5382aF534df5C7461a` |
| SafeL2 singleton (v1.4.1) | `0x29fcB43b46531BcA003ddC8FCB67FFE91900C762` |
| SafeProxyFactory | `0x4e1DCf7AD4e460CfD30791CCC4F9c8a4f820ec67` |
| CompatibilityFallbackHandler | `0xfd0732Dc9E303f09fCEf3a7388Ad10A83459Ec99` |
| MultiSendCallOnly | `0x9641d764fc13c8B624c04430C7356C1C7C8102e2` |

Confirm the code is present before deploying:

```sh
cast codehash 0x41675C099F32341bf84BFc5382aF534df5C7461a --rpc-url https://rpc.mainnet.arc.io
cast codehash 0x4e1DCf7AD4e460CfD30791CCC4F9c8a4f820ec67 --rpc-url https://rpc.mainnet.arc.io
```

Two ways to create the proxy:

**Option A — Safe{Wallet}.** Safe lists Arc in its deployment registry and supports
Arc's transaction service. Open `app.safe.global`, select Arc, create a Safe, add the
three owner addresses and threshold 2, and deploy. The deployer pays a few cents of
USDC gas. If Arc is not yet in the network picker, use Option B; do not wait on the UI.

**Option B — canonical factory (this repo).**

Fill the Safe section of `.env.test` (testnet) or `.env.main` (mainnet), created
from `.env.example`:

```sh
PRIVATE_KEY=0x...        # deployer only; pays gas, is NOT an owner
SAFE_ADMIN1=0x...
SAFE_ADMIN2=0x...
SAFE_RECOVERY=0x...
```

Then:

```sh
# Simulate first (no broadcast)
bash scripts/deploy-safe.sh --mainnet --dry-run

# Deploy + verify
bash scripts/deploy-safe.sh --mainnet

# Verify later
bash scripts/deploy-safe.sh --mainnet --verify-only
```

The script calls
`SafeProxyFactory.createProxyWithNonce(singleton, initializer, saltNonce)` with
`threshold = 2`, the three owners, the canonical fallback handler, and no payment.
The deployer key only pays gas; it is **not** a Safe owner. On success it writes
`SAFE_ADDRESS` to the same env file, which `scripts/governance.sh` reads.

The Solidity counterpart is `script/DeploySafe.s.sol`; the shell wrapper matches
`scripts/deploy.sh` / `scripts/upgrade.sh` conventions (network flag, balance check, build, verify).

Verify:

```sh
bash scripts/deploy-safe.sh --mainnet --verify-only
```

- [ ] `VERSION() == "1.4.1"`
- [ ] `getThreshold() == 2`
- [ ] `getOwners()` returns exactly the three intended, distinct addresses
- [ ] slot 0 (singleton) is the canonical Safe address
- [ ] fund each executing owner with a small USDC gas balance; the Safe itself does not pay gas

**How it works operationally.** A transaction is proposed by one owner in
Safe{Wallet} (or the Safe SDK), signed by owners until the threshold is met, then
submitted by any owner. The Safe contract verifies the signatures and executes the
call as the Safe address. Arc's deterministic finality means one confirmation is
final. The Safe nonce is per-Safe and sequential; never reuse or skip it. Upgrades,
ProxyAdmin ownership transfers and `acceptAdmin1` are all ordinary Safe transactions.

**Why not a single EOA?** A 2-of-3 Safe means one lost or compromised key cannot move
upgrade authority. 2-of-3 was chosen over 2-of-2 so losing one key does not
permanently disable upgrades.

### 2.2 Helper scripts

| Shell | Solidity | Purpose |
|---|---|---|
| `scripts/deploy.sh` | `script/Deploy.s.sol` | Deploy the two proxies |
| `scripts/upgrade.sh` | `script/Upgrade.s.sol` | Upgrade before the timelock takes ownership |
| `scripts/verify.sh` | `forge verify-contract` | Generate Standard-JSON verification inputs |
| `scripts/deploy-safe.sh` | `script/DeploySafe.s.sol` | Create the 2-of-3 Safe proxy via the canonical factory |
| `scripts/governance.sh` | `script/Governance.s.sol` | Deploy the timelock; print Safe calldata; verify; print schedule calldata |
| `scripts/load-env.sh` | — | Shared `.env.test` / `.env.main` loader |

All helpers read the same consolidated network file: `.env.test` for
`--testnet` and `.env.main` for `--mainnet` (override with `ENV_FILE`). The file
holds the deployer key, admins, proxy addresses, Safe owners, `SAFE_ADDRESS` and
`TIMELOCK`; `scripts/deploy-safe.sh` and `scripts/governance.sh` write the last two back. All
helpers accept `--mainnet` / `--testnet` and check the deployer's USDC gas
balance before broadcasting where a transaction is signed.

```sh
bash scripts/deploy-safe.sh --mainnet --dry-run     # simulate, no broadcast
bash scripts/deploy-safe.sh --mainnet               # deploy + verify
bash scripts/governance.sh --mainnet                # show configuration
bash scripts/governance.sh --mainnet --deploy-timelock
bash scripts/governance.sh --mainnet --print        # all Safe calldata -> governance-calldata.txt
bash scripts/governance.sh --mainnet --verify
bash scripts/governance.sh --mainnet --schedule     # scheduleBatch calldata for an upgrade
```

### 2.3 Current Arc mainnet state (verified 8 Nov 2026)

Read-only against `https://rpc.mainnet.arc.io`:

| Item | Value |
|---|---|
| `LiquidityManager` proxy | `0xB648061376a696Daafb17D8107B18872ecC6889B` |
| `LiquidityProvider` proxy | `0x7A343A92B580f47A3Cb473dacB43F09f9467033f` |
| LM `ProxyAdmin` | `0xd454D48FbeA2bD631Cdf70a3a11089AC9d1e4f84` |
| LP `ProxyAdmin` | `0x588a5Ece2ab68D61eD48674a0FE37a2F3f8F0C89` |
| `ProxyAdmin` owner (both) | `0x31a432DF9c1d525a4A4522F33D6e369023AbE74b` (original `admin1` EOA) |
| `LiquidityManager.admin1` | `0x31a432DF9c1d525a4A4522F33D6e369023AbE74b` |
| `LiquidityManager.admin2` | `0xA62BE23BdF551A1bec11BdA9b2823B4bDAf2135b` |
| `LiquidityManager.paused` | `false` |
| LM implementation | `0x2Da36EF240a9DCC67319490829957DAE17e8b5E0` |
| LP implementation | `0xA579A4AB3D8F86050580f4aBBCE4ac5638df1665` |

Both `ProxyAdmin` contracts are still owned by the original `admin1` EOA, so **Wave 3
has not been executed**. That is the first action in this runbook and the only step
that must be signed by the old key.

The entire sequence — Safe creation through the canonical factory, both ProxyAdmin
transfers, `admin1` rotation, and a no-op upgrade through the 2-hour timelock — is
rehearsed against this exact live state on a local fork:

```sh
ARC_MAINNET_RPC_URL=https://rpc.mainnet.arc.io \
  forge test --match-contract GovernanceMainnetForkTest -vv
```

Nothing is broadcast. The fork test passed on 8 Nov 2026.

Put these in `.env.main` (or `.env.test`), which every helper reads:

```sh
SAFE_ADDRESS=0x...
LM_PROXY_ADMIN=0x...
LP_PROXY_ADMIN=0x...
LM_PROXY=0x...
LP_PROXY=0x...
TIMELOCK_MIN_DELAY=7200
```

---

## 3. Move ProxyAdmin ownership from the EOA to the Safe

Do this first. The Safe cannot prove control of a `ProxyAdmin` it does not own, and the
original `admin1` EOA key is the only thing that can make this transfer.

```sh
set -a
. ./.env.main          # or .env.test
set +a

forge script script/Governance.s.sol:GovernanceScript \
  --sig printProxyAdminTransfers -vv
```

`bash scripts/governance.sh --mainnet --print` does the same and writes every step to
`governance-calldata.txt`.

Send the two printed transactions from the original `admin1` EOA. After they land:

- `ProxyAdmin(LM).owner() == SAFE_ADDRESS`
- `ProxyAdmin(LP).owner() == SAFE_ADDRESS`
- No further upgrade can be sent by a single EOA.

## 4. Prove Safe control (no-op upgrade)

Before handing ownership to the timelock, execute one no-op upgrade from the Safe for
each proxy. This proves quorum can drive the `ProxyAdmin` at all, and emits
`Upgraded(currentImplementation)`.

```sh
set -a
. ./.env.main          # or .env.test
set +a

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
bash scripts/governance.sh --mainnet --deploy-timelock
```

This deploys `TimelockController(minDelay, [Safe], [Safe], address(0))`, writes
`TIMELOCK` to the same env file, and prints the address.

Verification before §6: the ProxyAdmins are owned by the Safe, `admin1` is still the
EOA, and the timelock reports `minDelay = 7200`, Safe has
`PROPOSER`/`EXECUTOR`/`CANCELLER`, Safe does **not** have `DEFAULT_ADMIN_ROLE`.

## 6. Move ProxyAdmin ownership to the timelock

Two Safe transactions. After they execute, **every** upgrade takes at least two hours.
That is the intended control, not an incident-time surprise.

```sh
bash scripts/governance.sh --mainnet --print
```

Paste each printed `to` / `value` / `data` into Safe{Wallet} → Transaction Builder,
collect 2-of-3 signatures, execute. The two ProxyAdmin transfers to the Safe are
**EOA transactions**, not Safe transactions: send them from the original `admin1` EOA.

## 7. Rotate `admin1` to the Safe

Two transactions, two different signers.

1. Current `admin1` EOA, direct transaction to `LM_PROXY`:
   `transferAdmin1(SAFE_ADDRESS)`.
2. Safe transaction to `LM_PROXY`: `acceptAdmin1()`.

```sh
bash scripts/governance.sh --mainnet --print
```

Consequences:

- `transferAdmin1`, `acceptAdmin1`, `updateSettingsContract` now require Safe quorum.
- `pause`, `unpause`, `updateProtocolAddress`, `setTokenSupported`, `updateTierFee`
  remain single-key via `admin2`.

**Known gap:** `transferAdmin2` is still `onlyAdmin2`; see `backlogs.md`. Treat the
`admin2` key as a governance key and keep it in the same custody class.

## 8. Verification checklist

```sh
bash scripts/governance.sh --mainnet --verify
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
