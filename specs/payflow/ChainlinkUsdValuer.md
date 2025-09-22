# ChainlinkUsdValuer — SPEC

**Intent:** Convert `(token, amount)` into **USD (1e18)** using Chainlink feeds with optional per‑feed staleness.

## State
- `feeds[token] → { agg: IAggregatorV3, staleAfter: seconds }`

## Invariants
- **INV-UV-01:** `usdValue(token, amt)` requires feed configured, `answer > 0`, `answeredInRound ≥ roundId`, `updatedAt != 0`, and `(now - updatedAt) ≤ staleAfter` if set.
- **INV-UV-02:** Proper decimals normalization of token and price to 1e18.

## Permissions
- Owner: `setFeed(token, aggregator, staleAfter)`

## External Interactions
- Reads `latestRoundData()` and `decimals()` from aggregator; token `decimals()`

## Failure Modes
- Revert with `no feed`, `bad px`, `incomplete round`, or `stale`

## Events
- `FeedSet(token, aggregator, staleAfter)`

## Tests Map
- INV-UV-01: `test/Valuer.t.sol::testChainlinkChecks()`
- INV-UV-02: `test/Valuer.t.sol::testDecimalsNormalization()`
