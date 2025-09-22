# GaugeEmitter — SPEC

**Intent:** Distribute epoch emissions to gauges according to `GaugeController` weights.

## State
- `controller` — GaugeController
- `epochLength`, `nextEpochAt`
- `lastDistributedEpoch`
- `rewardToken` — XPGN (minted in by EmissionsMinter)
- `isGauge[gauge]` — allow-list (mirrors controller)

## Invariants
- **INV-GE-01 (Once per epoch):** `distribute()` can execute at most once per epoch; reverts otherwise.
- **INV-GE-02 (Exact split):** Sum of amounts sent to gauges equals the input amount for the epoch (subject to rounding at most ±1 wei).
- **INV-GE-03 (Registered only):** Distribute only to gauges returned/approved by controller for the epoch.
- **INV-GE-04 (Time gating):** `block.timestamp ≥ nextEpochAt` to run; then `nextEpochAt += epochLength`.

## Permissions
- **DAO/Admin:** set `epochLength`, set controller, manage gauge allow-list (if mirrored)
- **Anyone/bot:** can call `distribute()` when epoch ready

## External Interactions
- Transfers reward token to `SimpleGauge.notifyRewardAmount`

## Failure Modes
- Revert on empty gauges/weights, not yet epoch time, or mismatched controller data

## Events
- `Distributed(epoch, total, gauges[], amounts[])`

## Tests Map
- **INV-GE-01:** `test/Emitter.t.sol::testOncePerEpoch()`
- **INV-GE-02:** `test/Emitter.t.sol::testExactSplitSum()`
- **INV-GE-03:** `test/Emitter.t.sol::testOnlyRegisteredGauges()`
- **INV-GE-04:** `test/Emitter.t.sol::testEpochTiming()`
