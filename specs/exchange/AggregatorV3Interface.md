# AggregatorV3Interface — SPEC (Interface)


**Intent:** Canonical Chainlink price feed interface used by `ParagonOracle`.


## Functions
- `latestRoundData()` → `(roundId, answer, startedAt, updatedAt, answeredInRound)`
- `decimals()` → `uint8`


## Invariants
- **INV-AG-01:** ConAggregatorV3Interface.md
sumers must verify `answer > 0`, `updatedAt` within staleness threshold, and `answeredInRound >= roundId`


## Permissions
- N/A (interface)


## External Interactions
- Read-only by Oracle


## Tests Map
- INV-AG-01: `test/Oracle.t.sol::testChainlinkConsumerChecks()`