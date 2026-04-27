# UsagePointsAdapter — SPEC

**Intent:**  
Allow trusted protocol callers like Payflow to forward real usage events directly into `UsagePoints`.

## State
- `usagePoints`
- `allowedCallers[addr]`

## Invariants
- **INV-UPA-01 (Trusted callers only):** Only allowed callers may forward usage actions.
- **INV-UPA-02 (Direct forwarding):** Adapter does not mutate scoring logic; it only forwards to `UsagePoints`.

## Permissions
- **DAO/Admin:** `setCaller`
- **Allowed callers:** forwarding functions

## External Interactions
- Calls relevant `UsagePoints` hook functions

## Failure Modes
- Revert on unauthorized caller
- Revert on zero-address caller config

## Events
- `CallerSet(caller, allowed)`

## Tests Map
- **INV-UPA-01:** `test/UsagePointsAdapter.t.sol::testOnlyAllowedCallerMayForward()`
- **INV-UPA-02:** `test/UsagePointsAdapter.t.sol::testForwardingCallsCorrectUsageHook()`
