# LiquidityUsageAdapter — SPEC

**Intent:**  
Verify signed liquidity-related usage claims and forward them into `UsagePoints`.

## State
- inherits `SignedUsageAdapterBase`
- `usagePoints` — `UsagePoints`

## Invariants
- **INV-LUA-01 (Verified claims only):** Forwarding occurs only after `_verifyAndConsume`.
- **INV-LUA-02 (Exact event forwarding):** `submitLiquidityAdded` and `submitLiquidityRetained` emit the same signed `epoch` in events.
- **INV-LUA-03 (No replay):** Same signed claim cannot be resubmitted.

## Permissions
- **DAO/Admin:** signer management via base
- **Anyone:** may submit a valid signed claim

## External Interactions
- Calls `usagePoints.onLiquidityAdded(...)`
- Calls `usagePoints.onLiquidityRetained(...)`

## Failure Modes
- Revert on invalid or replayed signed claim

## Events
- `LiquidityAddedRecorded(user, usdValue1e18, ref, epoch)`
- `LiquidityRetainedRecorded(user, usdValue1e18, ref, epoch)`

## Tests Map
- **INV-LUA-01:** `test/LiquidityUsageAdapter.t.sol::testVerifiedClaimsOnly()`
- **INV-LUA-02:** `test/LiquidityUsageAdapter.t.sol::testEventEpochMatchesSignedEpoch()`
- **INV-LUA-03:** `test/LiquidityUsageAdapter.t.sol::testReplayRejected()`
