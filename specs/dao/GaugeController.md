# GaugeController — SPEC

**Intent:**  
Aggregate veXPGN voting power into per-gauge weights for each epoch, then **finalize immutable epoch snapshots** used by emissions distribution.

## State
- `ve` — `VoterEscrow` voting power source
- `usage` — usage multiplier / decay source
- `gauges[]` — historical gauge registry
- `isGauge[gauge]` — currently active gauge
- `wasEverGauge[gauge]` — whether a gauge has ever existed
- `gaugeWeight[epoch][gauge]` — live epoch weight
- `totalWeight[epoch]` — live epoch total
- `finalizedGaugeWeight[epoch][gauge]` — frozen epoch weight
- `finalizedTotalWeight[epoch]` — frozen epoch total
- `epochFinalized[epoch]`
- `userVoteBps[epoch][user][gauge]`
- `userUsedBps[epoch][user]`
- `userVotedGauges[epoch][user]`
- `powerUsedAtVote[epoch][user]`
- `userLastVoteTs[epoch][user]`
- params:
  - `minVeToVote`
  - `maxGaugesPerVote`
  - `voteCooldown`
  - `voteWindowEndBuffer`

## Invariants
- **INV-GC-01 (Historical registry preserved):** Removed gauges are deactivated via `isGauge=false` but remain in `gauges[]` for historical epoch finalization.
- **INV-GC-02 (Epoch-local finalization):** `finalizedTotalWeight[ep]` equals the sum of copied `finalizedGaugeWeight[ep][g]` values, not stale live totals.
- **INV-GC-03 (Vote window closure):** `vote()` and external `reset()` cannot change weights during the final closed window before epoch end.
- **INV-GC-04 (Per-user bps bound):** User vote bps across gauges never exceeds `MAX_BPS`.
- **INV-GC-05 (Active gauges only for voting):** Only currently active gauges may receive new votes.
- **INV-GC-06 (Closed epochs only finalized):** `finalizeEpoch(ep)` requires `ep < currentEpoch`.

## Permissions
- **DAO/Admin:** `addGauge`, `removeGauge`, `setParams`, `setVoteWindowEndBuffer`, `pause`, `unpause`
- **Users:** `vote`, `reset`
- **Anyone/Ops bot:** `finalizeEpoch`, `batchFinalize`

## External Interactions
- Reads `ve.balanceOf(user)`
- Reads and applies `usage.multiplierBps(user)` and `usage.applyDecay(user)`

## Failure Modes
- Revert on:
  - duplicate gauges in a vote
  - vote after close window
  - total bps above 100%
  - inactive or unknown gauge
  - finalizing current or future epoch
  - finalizing empty epoch

## Events
- `GaugeAdded(gauge)`
- `GaugeRemoved(gauge)`
- `Voted(user, epoch, userPowerCached, gauges, bps)`
- `Reset(user, epoch, userPowerCleared)`
- `ParamsUpdated(minVeToVote, maxGaugesPerVote, voteCooldown)`
- `VoteWindowEndBufferUpdated(bufferSeconds)`
- `EpochFinalized(epoch, totalWeightFinalized)`

## Tests Map
- **INV-GC-01:** `test/GaugeController.t.sol::testRemovedGaugeStillFinalizesHistorically()`
- **INV-GC-02:** `test/GaugeController.t.sol::testFinalizedTotalEqualsCopiedWeights()`
- **INV-GC-03:** `test/GaugeController.t.sol::testVoteAndResetBlockedInClosedWindow()`
- **INV-GC-04:** `test/GaugeController.t.sol::testUserVoteCannotExceed100Percent()`
- **INV-GC-05:** `test/GaugeController.t.sol::testCannotVoteInactiveGauge()`
- **INV-GC-06:** `test/GaugeController.t.sol::testFinalizeClosedEpochOnly()`
