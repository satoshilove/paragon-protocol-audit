# VoterEscrow — SPEC

**Intent:**  
Lock XPGN into time-decaying ve positions with historical checkpointed reads, while allowing only trusted protocol lockers to create or top up locks on behalf of users.

## State
- `XPGN`
- `WEEK`
- `MIN_LOCK_TIME`
- `MAXTIME`
- `epoch`
- `pointHistory[epoch]`
- `slopeChanges[weekTs]`
- `locked[user]`
- `userPointEpoch[user]`
- `userPointHistory[user][epoch]`
- `rewardDepositors[addr]`

## Invariants
- **INV-VE-01 (Decay monotonic):** Without new deposits or extensions, a user’s ve bias decays over time.
- **INV-VE-02 (Lock bounds):** New or extended lock end must be within `[now + MIN_LOCK_TIME, now + MAXTIME]`.
- **INV-VE-03 (Withdrawal after expiry only):** Withdraw is allowed only once lock end is reached.
- **INV-VE-04 (Checkpoint consistency):** Global and user checkpoints update slope and bias consistently with scheduled slope changes.
- **INV-VE-05 (Trusted third-party creation only):** `create_lock_for(...)` may only be called by approved reward depositors.
- **INV-VE-06 (Trusted third-party top-up only):** `increase_amount_for(...)` may only be called by approved reward depositors.
- **INV-VE-07 (No public grief-locking):** Untrusted third parties cannot create dust locks for arbitrary users.

## Permissions
- **DAO/Admin:** `setRewardDepositor`, `pause`, `unpause`
- **Users:** `create_lock`, `increase_amount`, `increase_unlock_time`, `withdraw`, `checkpoint`
- **Trusted reward depositors:** `create_lock_for`, `increase_amount_for`

## External Interactions
- Pulls XPGN into escrow
- Transfers XPGN out on withdraw

## Failure Modes
- Revert on:
  - zero amount
  - existing lock on create
  - expired lock on top-up/extend
  - overlong unlock time
  - early withdrawal
  - unauthorized third-party create/top-up

## Events
- `Deposit(provider, beneficiary, value, locktime, depositType, ts)`
- `Withdraw(provider, value, ts)`
- `Supply(previousSupply, supply)`
- `Checkpoint(globalEpoch, ts, bias, slope)`
- `RewardDepositorSet(depositor, allowed)`

## Tests Map
- **INV-VE-01:** `test/VoterEscrow.t.sol::testVotingPowerDecayOverTime()`
- **INV-VE-02:** `test/VoterEscrow.t.sol::testLockBoundsEnforced()`
- **INV-VE-03:** `test/VoterEscrow.t.sol::testWithdrawOnlyAfterUnlock()`
- **INV-VE-04:** `test/VoterEscrow.t.sol::testCheckpointSupplyConsistency()`
- **INV-VE-05:** `test/VoterEscrow.t.sol::testOnlyRewardDepositorCanCreateLockFor()`
- **INV-VE-06:** `test/VoterEscrow.t.sol::testOnlyRewardDepositorCanIncreaseAmountFor()`
- **INV-VE-07:** `test/VoterEscrow.t.sol::testCannotDustLockAnotherUserPublicly()`
