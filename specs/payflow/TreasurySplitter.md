# TreasurySplitter — SPEC

**Intent:** Split protocol revenue tokens sitting on this contract into **60/35/5** for lockers/DAO/backstop.

## State
- `sink60`, `sink35`, `sink05`

## Invariants
- **INV-TS-01:** `setSinks` requires non‑zero sinks and emits `SinksUpdated`.
- **INV-TS-02:** `distribute(token)` sends exactly `60%/35%/5%` of current balance; emits `Distributed` with totals.

## Permissions
- Owner: `setSinks`, `distribute`, `sweep`

## External Interactions
- ERC‑20 transfers only

## Failure Modes
- No sinks (revert), zero balance (emit with zeros ok)

## Events
- `SinksUpdated(sink60, sink35, sink05)`, `Distributed(token, total, p60, p35, p05)`

## Tests Map
- INV-TS-01: `test/Splitter.t.sol::testSetSinks()`
- INV-TS-02: `test/Splitter.t.sol::testDistributeExactPercents()`
