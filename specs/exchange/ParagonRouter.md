# ParagonRouter — SPEC


**Intent:** Path-based liquidity routing with slippage/deadline checks and FOT-safe flows.


## Invariants
- **INV-RO-01:** Respect `amountOutMin` and `deadline`
- **INV-RO-02:** No dust loss on add/remove liquidity beyond fee rounding


## Permissions
- Public swapping/liquidity APIs
- DAO: parameter setters (max slippage)


## Edge Cases
- FOT tokens; differing decimals; empty liquidity; permit function paths


## Tests Map
- INV-RO-01: `test/Router.t.sol::testMinOutDeadline()`
- FOT paths: `test/Router_FOT.t.sol::*`