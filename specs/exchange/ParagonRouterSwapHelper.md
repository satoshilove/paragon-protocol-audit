# ParagonRouterSwapHelper — SPEC


**Intent:** Internal helpers used by Router to perform hop-by-hop swaps, including FOT-safe supporting functions.


## Invariants
- **INV-RH-01:** For each hop, outputs are computed from reserves and sent to the next pair or final recipient; no unintended token retention


## Permissions
- `internal`/`private` only; callable by Router


## External Interactions
- Calls `ParagonPair.swap`; reads pair reserves/balances for FOT handling


## Failure Modes
- Bubbles up reverts from Pair; input validation done by Router


## Tests Map
- INV-RH-01: `test/Router.t.sol::testMultiHopFOTSupporting()`