# VoterEscrow — SPEC

**Intent:** Lock XPGN to receive time-decayed voting power (“veXPGN”) used by the GaugeController.

## State
- `token` — address of XPGN
- `maxLockDuration` — max lock length (e.g., 2y)
- `locks[user]` → `{ amount, unlockTime }`
- (If present) historical checkpoints for total supply / user for view functions

## Invariants
- **INV-VE-01 (Monotonic decay):** Absent new locks/extends, a user’s voting power never increases over time.
- **INV-VE-02 (Bounds):** `unlockTime` ≤ `block.timestamp + maxLockDuration`; cannot lock zero; cannot extend beyond bound.
- **INV-VE-03 (Withdrawal rule):** Withdraw only after `unlockTime` and only up to locked amount.
- **INV-VE-04 (Supply consistency):** Total ve supply equals the sum of users’ voting power under the model.

## Permissions
- **Public:** `createLock`, `increaseAmount`, `extendLock`, `withdraw`
- **DAO/Admin:** may set `maxLockDuration` (bounded), pause if supported

## External Interactions
- Transfers XPGN in/out on lock/withdraw; emits events for indexers

## Failure Modes
- Revert on early withdraw, zero amount, over-max duration, paused

## Events
- `LockCreated(user, amount, unlock)`
- `LockIncreased(user, amount)`
- `LockExtended(user, newUnlock)`
- `Withdrawn(user, amount)`

## Tests Map
- **INV-VE-01:** `test/VE.t.sol::testVotingPowerDecay()`
- **INV-VE-02:** `test/VE.t.sol::testLockBounds()`
- **INV-VE-03:** `test/VE.t.sol::testWithdrawAfterUnlockOnly()`
- **INV-VE-04:** `test/VE.t.sol::testTotalSupplyConsistency()`
