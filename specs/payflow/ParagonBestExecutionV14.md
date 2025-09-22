# ParagonBestExecutionV14 — SPEC

**Intent:** EIP‑712 intent ledger and signature checker. Supports EOAs and EIP‑1271 smart‑wallets; backward‑compatible with historical typehash variants. Consumes nonces atomically to prevent replay.

## State
- `DOMAIN_SEPARATOR` (EIP‑712)
- `mapping(address=>uint256) nonces`
- Typehashes: `INTENT_TYPEHASH`, `INTENT_TYPEHASH_SPACES`, `INTENT_TYPEHASH_OLD`

## API
- `verify(SwapIntent it, bytes sig) → bool`
- `consume(SwapIntent it, bytes sig)` — reverts unless signature valid, deadline ok, and `nonce == nonces[user]`; then `nonces[user]++`.
- `hashIntent(SwapIntent it) → bytes32`
- `cancel(uint256 expectedNonce)` — idempotent cancel if matches.
- `nextNonce(address user)`

## Invariants
- **INV-BE-01:** Nonce monotonic per user; `consume` or `cancel` increments by exactly 1.
- **INV-BE-02:** Accepts EOA (ECDSA) or EIP‑1271 (magic value) signatures.
- **INV-BE-03:** Rejects zero addresses, expired deadlines, or nonce mismatch.

## Events
- `BestExecution(user, tokenIn, tokenOut, amountIn, amountOut, recipient, executor, nonce)`
- `IntentCanceled(user, nonce)`

## Tests Map
- INV-BE-01: `test/BestExec.t.sol::testNonceMonotonic()`
- INV-BE-02: `test/BestExec.t.sol::testEOAAnd1271()`
- INV-BE-03: `test/BestExec.t.sol::testInvalids()`
