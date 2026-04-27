# FarmUsageAdapter — SPEC

**Intent:**  
Verify signed farm retention usage claims and forward them into `UsagePoints`.

## State
- inherits `SignedUsageAdapterBase`
- `usagePoints` — `UsagePoints`

## Invariants
- **INV-FUA-01 (Verified claims only):** Forwarding occurs only after `_verifyAndConsume`.
- **INV-FUA-02 (Event mirrors signed epoch):** Emitted event uses signed claim epoch.
- **INV-FUA-03 (Replay protection inherited):** Same signed claim cannot be reused.

## Permissions
- **DAO/Admin:** signer management via base
- **Anyone:** may submit a valid signed claim

## External Interactions
- Calls `usagePoints.onLiquidityRetained(...)`

## Failure Modes
- Revert on invalid or replayed signed claim

## Events
- `FarmRetentionRecorded(user, usdValue1e18, ref, epoch)`

## Tests Map
- **INV-FUA-01:** `test/FarmUsageAdapter.t.sol::testVerifiedClaimsOnly()`
- **INV-FUA-02:** `test/FarmUsageAdapter.t.sol::testEventEpochMatchesSignedEpoch()`
- **INV-FUA-03:** `test/FarmUsageAdapter.t.sol::testReplayRejected()`
