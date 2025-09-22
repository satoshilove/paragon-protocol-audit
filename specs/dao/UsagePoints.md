# UsagePoints — SPEC

**Intent:** Track and award “usage points” to addresses (e.g., for on-chain activity); points can be consumed by other modules (reputation, boosts).

## State
- `operator` — address authorized to award points
- `points[user]` — cumulative points
- (Optional) `epoch` or category mapping if supported

## Invariants
- **INV-UP-01 (Monotonic):** `points[user]` never decreases except via explicit `burn` (if implemented).
- **INV-UP-02 (Authorized):** Only `operator`/DAO can award or burn points.

## Permissions
- **Operator/DAO:** `award(user, amount)`, `awardBatch(users[], amounts[])`, optional `burn(user, amount)`, `setOperator`
- **Public:** `pointsOf(user)` views

## External Interactions
- None (pure bookkeeping)

## Failure Modes
- Revert on zero address/amount, unauthorized calls

## Events
- `Awarded(user, amount)`, `AwardedBatch(count)`
- `Burned(user, amount)`, `OperatorSet(operator)`

## Tests Map
- **INV-UP-01:** `test/UsagePoints.t.sol::testMonotonicPoints()`
- **INV-UP-02:** `test/UsagePoints.t.sol::testOnlyOperatorCanAward()`
