Multicall — SPEC


**Intent:** Batch multiple read/write calls in a single transaction to reduce overhead.


## Invariants
- **INV-MC-01:** `aggregate(calls)` reverts if any call fails; returns per-call return data and the block number


## Permissions
- Public


## External Interactions
- Low-level `call` to targets; no delegatecall; no custody of funds


## Failure Modes
- Revert on any failing subcall; gas usage proportional to combined calls


## Events
- (Typically none)


## Tests Map
- INV-MC-01: `test/Multicall.t.sol::testAggregateAllOrNothing()`