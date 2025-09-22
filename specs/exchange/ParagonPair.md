# ParagonPair — SPEC


**Intent:** Constant-product AMM pair with fee on swap and optional protocol fee minting.


## State (key)
- `reserve0/reserve1` — last synced reserves
- `price0CumulativeLast/price1CumulativeLast` — TWAP accumulators
- `kLast` — last reserve product when protocol fee is enabled


## Invariants
- **INV-EX-01:** After swap, `reserve0*reserve1` ≥ previous k (accounting for fee)
- **INV-EX-02:** `sync` cannot set reserves below actual token balances
- **INV-EX-03:** `skim` only transfers excess balances to caller


## Permissions
- Public: `swap`, `mint`, `burn`, `skim`, `sync`
- DAO/Admin (via Factory): toggle protocol fee, fee recipient


## External Interactions
- Pull/push ERC20 tokens; emits `Mint/Burn/Swap/Sync`


## Failure Modes
- Revert on insufficient liquidity, overflow, or invariant violation


## Tests Map
- INV-EX-01: `test/Exchange.t.sol::testSwapInvariantFuzz()`
- INV-EX-02: `test/Exchange.t.sol::testSyncCannotUnderflow()`