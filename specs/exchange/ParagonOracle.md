# ParagonOracle — SPEC


**Intent:** Provide price quotes to Exchange/Payflow using Chainlink-style feeds and/or AMM TWAP, with staleness and liquidity guards.


## State
- `staleThresholdSec` — maximum age for oracle rounds
- `feed[token]` / `pairOracle[pair]` — configured sources
- Decimals normalization cache


## Invariants
- **INV-OR-01:** Returned price must be > 0, not stale, decimals-normalized; reverts otherwise
- **INV-OR-02:** If using AMM TWAP, observation window ≥ minWindow and pool liquidity ≥ minLiquidity


## Permissions
- DAO/Admin: set feeds, set thresholds/bounds


## External Interactions
- Reads `AggregatorV3Interface.latestRoundData()` and/or pair cumulative prices


## Failure Modes
- Revert on stale/zero/overflow; circuit breaker event


## Events
- `FeedSet(asset, feed)`, `StaleThresholdSet(seconds)`


## Tests Map
- INV-OR-01: `test/Oracle.t.sol::testChainlinkStalenessAndZero()`
- INV-OR-02: `test/Oracle.t.sol::testTwapWindowLiquidityBounds()`