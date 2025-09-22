# ParagonFactory — SPEC


**Intent:** Deploy and index `ParagonPair` pools; manage protocol fee recipient; enforce deterministic pair addresses.


## State
- `mapping(address => mapping(address => address)) getPair` — tokenA↔tokenB → pair
- `address[] allPairs` — list of created pairs
- `address feeTo` — recipient of protocol fees (if enabled)
- `address feeToSetter` or Admin/DAO — authority to set `feeTo`
- `bytes32 INIT_CODE_PAIR_HASH` — creation code hash for deterministic `pairFor`


## Invariants
- **INV-FA-01:** `createPair(tokenA, tokenB)` reverts if `tokenA == tokenB`, either token is zero, or pair exists
- **INV-FA-02:** Pairs are created with sorted tokens and deterministic address (`create2`) consistent with `INIT_CODE_PAIR_HASH`
- **INV-FA-03:** Only authorized (DAO/Admin) can change `feeTo` and the recipient is nonzero


## Permissions
- Public: `allPairs`, `getPair`, `allPairsLength`
- DAO/Admin: `setFeeTo`, `setFeeToSetter` (if present)


## External Interactions
- Deploys `ParagonPair` via `create2`; emits `PairCreated`


## Failure Modes
- Revert on duplicate/identical/zero addresses; event emitted on create; no silent failures


## Events
- `PairCreated(token0, token1, pair, index)`; `SetFeeTo(newFeeTo)`; `SetFeeToSetter(newSetter)`


## Tests Map
- INV-FA-01: `test/Factory.t.sol::testCreatePairGuards()`
- INV-FA-02: `test/Factory.t.sol::testDeterministicAddress()`
- INV-FA-03: `test/Factory.t.sol::testSetFeeToBounds()`