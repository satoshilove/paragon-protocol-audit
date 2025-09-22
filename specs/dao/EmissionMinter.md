# EmissionsMinter — SPEC

**Intent:** Mint XPGN per epoch (within caps) and fund the `GaugeEmitter` (and optionally other sinks).

## State
- `token` — XPGN (IMintable)
- `emitter` — GaugeEmitter
- `epochEmission` — target amount per epoch
- `emissionCap` — hard cap per epoch
- `nextEpochAt`, `epochLength`

## Invariants
- **INV-EM-01 (Cap):** `epochEmission ≤ emissionCap`; setters enforce bounds.
- **INV-EM-02 (Once per epoch):** `mintAndFund()` may only succeed once per epoch; updates `nextEpochAt`.
- **INV-EM-03 (Directed funding):** All freshly minted tokens for an epoch are transferred to `emitter` (or configured sinks) exactly.

## Permissions
- **DAO/Admin:** `setEpochEmission`, `setCap`, `setEmitter`, `setEpochLength`
- **Ops/Bot:** `mintAndFund()` (callable by anyone, effect gated by time)

## External Interactions
- Calls `token.mint(amount)` and transfers to `emitter`

## Failure Modes
- Revert on cap exceed, too early epoch, zero emitter

## Events
- `EpochEmissionSet(amount)`, `CapSet(amount)`
- `Minted(epoch, amount, emitter)`

## Tests Map
- **INV-EM-01:** `test/DAO.t.sol::testEmissionCap()`
- **INV-EM-02:** `test/DAO.t.sol::testMintOncePerEpoch()`
- **INV-EM-03:** `test/DAO.t.sol::testAllMintedGoesToEmitter()`
