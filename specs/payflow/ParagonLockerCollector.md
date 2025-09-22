# ParagonLockerCollector — SPEC

**Intent:** Receive arbitrary reward tokens from Executor, swap to **XPGN** via Router, deposit into **stXPGN (ERC-4626)**, and send resulting shares to `receiver`.

## State
- `router: IParagonRouterV2Like`
- `stxpgnVault: IERC4626Like` — vault that holds XPGN; `asset()` must be the XPGN token
- `xpgn: address` — cached from `IERC4626Like(stxpgnVault).asset()` (immutable expectation)
- `receiver: address` — destination for stXPGN shares
- `allowedToken[token] → bool` — allowlist of harvestable tokens  
- **Constants:** `DEFAULT_DEADLINE_SECS = 600`, `MAX_PATH_LEN = 5`

## Invariants
- **INV-LC-01 (Path validity):** For `harvest/harvestMany`, `path.length ∈ [2, MAX_PATH_LEN]`, `path[0] == tokenIn`, and `path[path.length-1] == xpgn`; else revert (`PathInvalid/PathTooLong`).
- **INV-LC-02 (Atomic convert-and-deposit):** On success, contract swaps all `tokenIn` → **XPGN**, deposits **all** XPGN into `stxpgnVault`, and transfers **all** resulting shares to `receiver` (no residue kept).
- **INV-LC-03 (No lingering approvals/funds):** Uses exact/force approvals; does not retain unnecessary allowances or token balances after completion; owner may `sweep` accidental tokens.
- **INV-LC-04 (Vault asset safety):** `setVault(newVault)` must satisfy `IERC4626Like(newVault).asset() == xpgn` and `newVault != address(0)`. Changing the vault cannot change the underlying asset away from XPGN.
- **INV-LC-05 (Allowlist enforcement):** `harvest/harvestMany` revert if `allowedToken[tokenIn] != true`. Owner-only mutators emit events.

## Permissions
- **Owner:** `setReceiver`, `setRouter`, `setVault` (per **INV-LC-04**), `setAllowedToken(s)`, `sweep(token,to)`
- **Public:** `harvest(tokenIn, amountIn, path, minOut)`, `harvestMany(tokens[], amounts[], paths[], mins[])`  
- **Note:** Mutating functions are **nonReentrant**.

## External Interactions
- Router swap (FOT-safe function where available)  
- ERC-4626 `deposit(asset, receiver)` on `stxpgnVault`

## Failure Modes
- `TokenNotAllowed`, `PathInvalid/PathTooLong`, `NothingToHarvest` (zero input), router revert (slippage/minOut), invalid vault (`setVault` fails **INV-LC-04**)

## Events
- `Harvested(tokenIn, amountIn, xpgnOut, stxpgnShares)`
- `AllowedTokenSet(token, allowed)`
- `ReceiverSet(receiver)`, `RouterSet(router)`, `VaultSet(vault)`

## Tests Map
- **INV-LC-01:** `test/Locker.t.sol::testPathAndAllowlist()`
- **INV-LC-02:** `test/Locker.t.sol::testFullDepositAndTransfer()`
- **INV-LC-03:** `test/Locker.t.sol::testNoResidueAndApprovals()`
- **INV-LC-04:** `test/Locker.t.sol::testSetVaultEnforcesXPGNAsset()`
- **INV-LC-05:** `test/Locker.t.sol::testAllowlistRequired()`
