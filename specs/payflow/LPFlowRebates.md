# LPFlowRebates — SPEC

**Intent:** Minimal staking + reward stream for LP holders. Executors notify rewards per LP token; users stake/withdraw LP and claim reward tokens. Queues rewards when `totalStaked==0` and releases on first stake.

## State
- `factory: IFactory` — pair discovery (`getPair(a,b)` or reversed)
- `notifier` — address allowed to `notify`
- `balances[lp][user]`, `totalStaked[lp]`
- `rewardData[lp][reward]` → `{ rewardPerTokenStored, queued }`
- `userPaidPerToken[lp][user][reward]`, `accrued[lp][user][reward]`
- `supportedRewardTokens[]` — allow‑list (max 20)

## Invariants
- **INV-LPR-01:** `notify()` only by `notifier`; if `totalStaked==0`, amount is **queued**; else `rewardPerTokenStored += amount/totalStaked`.
- **INV-LPR-02:** `stake/withdraw` settles user rewards first (update `accrued` & `userPaidPerToken`).
- **INV-LPR-03:** `claim(lp, rewards[])` transfers exactly accrued amounts and zeroes accruals.
- **INV-LPR-04:** `_releaseQueued(lp)` runs after first stake; moves queued → `rewardPerTokenStored` for supported reward tokens.

## Permissions
- Owner: `setNotifier`, manage `supportedRewardTokens`, `emergencySweep(queued only)`
- Public: `stake`, `withdraw`, `claim`, `earned`

## External Interactions
- Pulls LP/reward tokens; validates LP via Factory

## Failure Modes
- Revert on zero amounts, bad indexes, or zero pair; nonReentrant

## Events
- `Staked`, `Withdrawn`, `Claimed`, `Notified`, `NotifierSet`, `SupportedRewardAdded/Removed`

## Tests Map
- INV-LPR-01: `test/LPRebates.t.sol::testNotifyQueueVsDistribute()`
- INV-LPR-02: `test/LPRebates.t.sol::testStakeWithdrawSettles()`
- INV-LPR-03: `test/LPRebates.t.sol::testClaim()`
- INV-LPR-04: `test/LPRebates.t.sol::testReleaseQueuedOnFirstStake()`
