# UsagePoints — SPEC

**Intent:**  
Track weekly usage points and a decaying usage score that influences voting multipliers and reward allocations.

## State
- `callers[addr]` — allowed notifiers
- `points[epoch][user]`
- `totalPoints[epoch]`
- `dailyAccrued[user][day][actionType]`
- daily caps per action and total
- `usageScore[user]`
- `lastActiveTs[user]`
- `lastDecayDay[user]`
- weighting params:
  - `wSwapVolBps`
  - `wPayVolBps`
  - `wPaySavedBps`
  - `wLpAddBps`
  - `wLpRetainBps`
  - `wP10Bps`
  - `wAgentBps`
- decay params:
  - `inactivityGrace`
  - `decayBpsPerDay`

## Invariants
- **INV-UP-01 (Notifier-only accrual):** Only approved callers may award usage points.
- **INV-UP-02 (Daily cap enforcement):** Per-action caps and total daily cap bound accrual.
- **INV-UP-03 (Epoch-local accounting):** Accrual writes to `currentEpoch()`.
- **INV-UP-04 (Usage score bounded):** `usageScore` remains within `[SCORE_FLOOR, SCORE_MAX]`.
- **INV-UP-05 (Decay non-increasing):** Applying decay without new activity cannot increase usage score.
- **INV-UP-06 (Multiplier bounded):** `multiplierBps(user)` stays within `[MULT_MIN_BPS, MULT_MAX_BPS]`.

## Permissions
- **DAO/Admin:** `setCaller`, `setDailyCaps`, `setWeights`, `setDecayParams`, `pause`, `unpause`
- **Approved callers:** usage action hooks
- **Anyone:** read views

## External Interactions
- None; internal accounting only

## Failure Modes
- Revert on unauthorized notifier
- Ignore zero-user or zero-value actions where specified
- Revert on invalid parameter bounds

## Events
- `CallerSet(caller, allowed)`
- `DailyCapsSet(...)`
- `WeightsSet(...)`
- `DecayParamsSet(gracePeriod, decayBpsPerDay)`
- `DecayApplied(user, newScore, lastDecayDayKey)`

## Tests Map
- **INV-UP-01:** `test/UsagePoints.t.sol::testOnlyApprovedCallerCanAccrue()`
- **INV-UP-02:** `test/UsagePoints.t.sol::testDailyCapsEnforced()`
- **INV-UP-03:** `test/UsagePoints.t.sol::testAccrualWritesCurrentEpoch()`
- **INV-UP-04:** `test/UsagePoints.t.sol::testUsageScoreBounded()`
- **INV-UP-05:** `test/UsagePoints.t.sol::testDecayNeverIncreasesScore()`
- **INV-UP-06:** `test/UsagePoints.t.sol::testMultiplierWithinBounds()`
