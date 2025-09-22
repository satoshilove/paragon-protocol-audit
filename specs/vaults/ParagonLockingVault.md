# ParagonLockingVault — SPEC

**Intent:** Lock an LP token into fixed-duration tiers (30/60/90 days) with **share multipliers**, stake that LP into a farm pool (`pid`), accrue **XPGN** rewards pro-rata by **shares**, and let users **claim** rewards and **unlock** principal (with **early-unlock penalty**). **Emergency mode** disables deposits and allows immediate unlock.

## State
- `lpToken: IERC20` (immutable) — locked asset
- `rewardToken: IERC20` (immutable) — XPGN reward token
- `farm: IParagonFarm` (immutable) — farm controller
- `pid: uint256` (immutable) — farm pool id (**must match** `lpToken`)
- `dao: address` — recipient of early-unlock penalties
- `lock30/lock60/lock90: uint64` — tier durations (defaults **30/60/90 days**)
- `mult30/mult60/mult90: uint16` — tier multipliers in **bips** (defaults **12000/15000/20000** → 1.2×/1.5×/2.0×)
- `earlyPenaltyBips: uint16` — penalty on **principal** for early unlock (default **250** = 2.5%)
- `emergencyMode: bool` — deposits disabled; unlock allowed when **true**
- `accRewardPerShare: uint256` — global accumulator, **scaled 1e12**
- `totalShares: uint256` — sum of all active position shares
- `positions[user] → Position[]` — `{ amount, unlockTime, tier, rewardDebt, shares }`

**Deploy sanity:** require `farm.poolLpToken(pid) == lpToken`; pre-approve `farm` for `lpToken` with max allowance.

## API (user)
- `deposit(amount, tier, referrer)` — create locked position  
  • `tier ∈ {0,1,2}`; `unlockTime = now + lockDur`  
  • `shares = amount * multBips / 10000`  
  • Harvest first → pull LP → `farm.depositFor(pid, amount, address(this), referrer)`  
  • Set `rewardDebt = shares * accRPS / 1e12`  
  • Revert on `amount=0`, bad `tier`, or `emergencyMode`
- `claim(idx)` — harvest; pay `pending(idx)`; set `rewardDebt = shares * accRPS / 1e12`
- `claimAll()` — harvest; pay aggregated pending across caller positions; refresh debts
- `unlock(idx)` — harvest; require `now ≥ unlockTime` **or** `emergencyMode`; withdraw LP from farm to user; burn shares; zero position
- `unlockEarly(idx)` — harvest; withdraw LP; send `penalty = amount * earlyPenaltyBips / 10000` to `dao`, remainder to user; burn shares; zero position

## Admin (onlyOwner)
- `harvest()` — pull farm rewards; if `totalShares > 0`, `accRPS += harvested * 1e12 / totalShares`
- `setParams(l30, l60, l90, m30, m60, m90)` — multipliers must be `> 0`
- `setEarlyPenaltyBips(bips)` — `bips ≤ 10000`
- `setEmergencyMode(enabled)` — toggle emergency
- `setDao(dao)` — non-zero
- `rescueToken(token, amount, to)` — **cannot** rescue `lpToken` or `rewardToken`; `to != 0`

## Views
- `positionsLength(user) → uint256`
- `pending(idx, user) → uint256` — preview includes current farm pending as-if harvested now:  
  `accPreview = accRPS + (farm.pendingReward(pid, vault) * 1e12 / totalShares)` (when `totalShares > 0`); then  
  `pending = max(0, shares * accPreview / 1e12 − rewardDebt)`

## Reward / Accounting Model
- **Shares:** `shares = amount * multBips / 10000` (per-tier)
- **Accrual:** on harvest, increase `accRPS` by `harvested * 1e12 / totalShares` (if `totalShares > 0`)
- **User pending:** `max(0, shares * accRPS / 1e12 − rewardDebt)`
- **Debt rule:** after any position-touching action, set `rewardDebt = shares * accRPS / 1e12`
- **Penalty:** early unlock penalty is deducted from **LP principal** and paid to `dao`

## Invariants
- **INV-VLT-01 (Tier validation):** `deposit` reverts if `tier ∉ {0,1,2}`
- **INV-VLT-02 (Shares):** `shares = amount * multBips / 10000`; `totalShares = Σ(active shares)`
- **INV-VLT-03 (Unlock time):** `unlockTime = now + lockDur`
- **INV-VLT-04 (Harvest math):** if `totalShares > 0`, `accRPS' = accRPS + harvested * 1e12 / totalShares`
- **INV-VLT-05 (Debt rule):** after user actions, `rewardDebt = shares * accRPS / 1e12`
- **INV-VLT-06 (Preview):** `pending()` equals the preview formula using `farm.pendingReward`
- **INV-VLT-07 (Time gating):** `unlock` requires `now ≥ unlockTime` unless `emergencyMode`
- **INV-VLT-08 (Penalty):** `unlockEarly` sends `amount * earlyPenaltyBips / 10000` LP to `dao`; remainder to user
- **INV-VLT-09 (Burn on exit):** on unlock (normal/early), `totalShares' = totalShares − position.shares`; position zeroed
- **INV-VLT-10 (Emergency):** when `emergencyMode == true`, `deposit` reverts; `unlock` allowed
- **INV-VLT-11 (Rescue guard):** `rescueToken` reverts for `lpToken`/`rewardToken`; `to != 0`
- **INV-VLT-12 (Farm LP match):** constructor requires `farm.poolLpToken(pid) == lpToken`
- **INV-VLT-13 (Non-reentrancy):** mutating endpoints are **nonReentrant**

## External Interactions
- Farm: `depositFor`, `withdraw`, `harvest`, `pendingReward`, `poolLpToken`
- ERC-20: `transferFrom/transfer` for LP/reward; one-time max approval for LP → farm

## Failure Modes
`amount=0` · `bad tier` · `locked` · `emergency` · `bips>10000` · `mult=0` · `zero/zero addr` · `protected` · `pool/lp mismatch`

## Events
`Deposited(user, idx, amount, shares, unlockAt, tier)` ·  
`Claimed(user, idx, amount)` · `ClaimedAll(user, amount)` ·  
`Unlocked(user, idx, amount)` · `EarlyUnlocked(user, idx, returnedToUser, penaltyToDao)` ·  
`Harvested(amount)` · `ParamsUpdated(l30, l60, l90, m30, m60, m90)` ·  
`EarlyPenaltyUpdated(bips)` · `EmergencyModeUpdated(enabled)` ·  
`DaoUpdated(dao)` · `Rescued(token, amount, to)`

## Tests Map
- **INV-VLT-01/02/03:** tiers, shares, unlockTime; bad inputs revert
- **INV-VLT-04:** harvest increases `accRPS` (with `totalShares > 0`)
- **INV-VLT-05:** claim/claimAll pay correct amounts; debts refreshed
- **INV-VLT-06:** pending preview includes farm `pendingReward`
- **INV-VLT-07:** unlock time gating (revert before; succeed after or in emergency)
- **INV-VLT-08/09:** early-unlock penalty to `dao`; shares burned; position zeroed
- **INV-VLT-10:** emergency blocks deposits and allows unlock
- **INV-VLT-11:** rescueToken guards (cannot rescue LP/reward; can rescue others; `to != 0`)
- **INV-VLT-12:** ctor requires pool/LP match
- **INV-VLT-13:** non-reentrancy on mutating endpoints

## Rounding
`accRewardPerShare` uses **1e12** scale; floor division; small residual dust may remain in the vault (not user-lossy).
