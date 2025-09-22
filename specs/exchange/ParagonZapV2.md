# ParagonZapV2 — SPEC


**Intent:** One-click add/remove liquidity by auto-splitting input assets and routing via Router with safety limits.


## Behavior
- Accept single-token or dual-token inputs; computes optimal swap to balance pool ratio; optionally uses permits


## Invariants
- **INV-ZP-01:** Never spends more than user-approved amounts; respects `minLpOut` / `maxTokenIn` constraints
- **INV-ZP-02:** No custody of user funds after tx; residual dust returned to user


## Permissions
- Public user functions; DAO can set per-pool safety caps (optional)


## External Interactions
- Calls Router for swaps & liquidity; approves tokens transiently (reset to 0 after use)


## Failure Modes
- Revert on insufficient output, slippage breach, or unsafe pool state


## Events
- `ZapAddLiquidity`, `ZapRemoveLiquidity`


## Tests Map
- INV-ZP-01: `test/Zap.t.sol::testBoundsAndApprovals()`
- INV-ZP-02: `test/Zap.t.sol::testDustReturned()`