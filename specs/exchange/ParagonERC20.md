# ParagonERC20 (LP Token) — SPEC


**Intent:** ERC-20 LP token with mint/burn restricted to Pair; optional EIP-2612 permit support.


## State
- Standard ERC-20 mappings; `nonces` and `DOMAIN_SEPARATOR` if permit


## Invariants
- **INV-LP-01:** Only `ParagonPair` can `mint`/`burn` LP; totalSupply and balances remain consistent
- **INV-LP-02:** `permit` honors EIP-2612 (signature validity, nonces monotonic)


## Permissions
- Pair: `mint`, `burn`
- Public: `transfer`, `approve`, `permit` (if supported)


## External Interactions
- None beyond ERC-20 standard


## Failure Modes
- Revert on invalid permit, insufficient balance/allowance


## Events
- `Transfer`, `Approval`


## Tests Map
- INV-LP-01: `test/LP.t.sol::testPairOnlyMintBurn()`
- INV-LP-02: `test/LP.t.sol::testPermit()`