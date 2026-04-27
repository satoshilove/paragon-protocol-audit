# SignedUsageAdapterBase — SPEC

**Intent:**  
Provide EIP-712 signed usage claim verification and replay protection for usage adapters.

## State
- `DOMAIN_SEPARATOR`
- `authorizedSigner[addr]`
- `usedDigest[digest]`
- `WEEK`
- `USAGE_CLAIM_TYPEHASH`

## Invariants
- **INV-SUA-01 (Authorized signer only):** Claims are accepted only if signed by an authorized signer.
- **INV-SUA-02 (Replay protection):** Each claim digest may be consumed only once.
- **INV-SUA-03 (Strict epoch binding):** Claim epoch must equal `currentEpoch()`.
- **INV-SUA-04 (Expiry enforced):** Claim deadline must be in the future at execution.
- **INV-SUA-05 (Positive value only):** Claim value must be nonzero.

## Permissions
- **DAO/Admin:** `setSigner`, `pause`, `unpause`
- **Derived adapters:** call `_verifyAndConsume`

## External Interactions
- ECDSA recovery only

## Failure Modes
- Revert on:
  - zero user
  - zero value
  - wrong epoch
  - expired claim
  - reused digest
  - unauthorized signer

## Events
- `SignerSet(signer, allowed)`
- `ClaimConsumed(digest, user, ref, usdValue1e18, epoch)`
- `EmergencyPause(owner)`
- `EmergencyUnpause(owner)`

## Tests Map
- **INV-SUA-01:** `test/SignedUsageAdapterBase.t.sol::testAuthorizedSignerRequired()`
- **INV-SUA-02:** `test/SignedUsageAdapterBase.t.sol::testDigestCannotBeReused()`
- **INV-SUA-03:** `test/SignedUsageAdapterBase.t.sol::testClaimMustMatchCurrentEpoch()`
- **INV-SUA-04:** `test/SignedUsageAdapterBase.t.sol::testExpiredClaimRejected()`
- **INV-SUA-05:** `test/SignedUsageAdapterBase.t.sol::testZeroValueRejected()`
