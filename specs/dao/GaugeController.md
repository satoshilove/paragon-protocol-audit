# GaugeController — SPEC

**Intent:** Aggregate veXPGN votes into per-gauge weights per epoch; expose total weight and caps for the Emitter.

## State
- `gauges[]` — registered gauges
- `weight[gauge]` — current bps weight
- `totalWeight` — sum of all gauge weights (bps)
- `weightCapBps[gauge]` — optional per-gauge cap
- `epochLength` / `currentEpoch` — discrete periods for weight updates
- `ve` — VoterEscrow reference

## Invariants
- **INV-GC-01 (Sum bound):** `totalWeight ≤ 10000 bps`.
- **INV-GC-02 (Per-gauge cap):** `weight[gauge] ≤ weightCapBps[gauge]` if set.
- **INV-GC-03 (Epoch monotonic):** Epoch can only advance forward; no double-advance in a single block.
- **INV-GC-04 (Authorized changes):** Only DAO/Admin can add gauges, set caps, or finalize epoch weights.

## Permissions
- **DAO/Admin:** `addGauge`, `removeGauge`, `setWeightCap`, `rollEpoch`
- **Voters (if supported):** vote/adjust weights via veXPGN rules

## External Interactions
- Reads veXPGN balances if voting is dynamic; consumed by GaugeEmitter

## Failure Modes
- Revert on duplicate gauge, exceeding caps, or invalid epoch ops

## Events
- `GaugeAdded(gauge)`, `GaugeRemoved(gauge)`
- `WeightSet(gauge, bps)`, `WeightCapSet(gauge, capBps)`
- `EpochRolled(epoch, totalWeight)`

## Tests Map
- **INV-GC-01:** `test/DAO.t.sol::testWeightSumBound()`
- **INV-GC-02:** `test/DAO.t.sol::testPerGaugeCap()`
- **INV-GC-03:** `test/DAO.t.sol::testEpochMonotonic()`
- **INV-GC-04:** `test/DAO.t.sol::testOnlyDaoCanConfigure()`
