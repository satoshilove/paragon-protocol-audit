# TraderRewardsLocker — SPEC

**Intent:**  
Distribute trader rewards by epoch using `UsagePoints` shares, then auto-lock rewards into `VoterEscrow` subject to minimum lock policy.

## State
- `XPGN` — immutable reward token
- `usage` — points source
- `ve` — `VoterEscrow`
- `useSolidlyOrder`
- `epochBudget[epoch]` — mutable pre-finalization funding
- `epochFinalBudget[epoch]` — frozen reward budget used for claims
- `epochFinalized[epoch]`
- `epochFinalTotalPoints[epoch]`
- `claimed[epoch][user]`
- `rewardNotifiers[addr]`
- `minLockWeeks`
- `maxLockWeeks`
- `gasKickbackBips`

## Invariants
- **INV-TRL-01 (Funding before finalization only):** `notifyRewardAmount(epoch, amount)` reverts once `epochFinalized[epoch] == true`.
- **INV-TRL-02 (Frozen claim budget):** Claims always use `epochFinalBudget[epoch]`, never mutable `epochBudget[epoch]`.
- **INV-TRL-03 (Trusted finalization only):** Only owner/notifier may finalize epochs, preventing grief-freezing of unfunded epochs.
- **INV-TRL-04 (No empty finalization):** Epoch finalization requires both nonzero `usage.totalOf(epoch)` and nonzero budget.
- **INV-TRL-05 (One claim per epoch per user):** `claimed[epoch][user]` is write-once.
- **INV-TRL-06 (Minimum reward-lock semantics):**
  - new auto-locks must use a lock length within `[minLockWeeks, maxLockWeeks]`
  - existing-lock top-ups require `existingEnd >= targetMin`
- **INV-TRL-07 (Trusted ve interaction only):** Existing-lock top-ups rely on `VoterEscrow.increase_amount_for`.

## Permissions
- **DAO/Admin:** `setRewardNotifier`, `setLockConfig`, `pause`, `unpause`, `emergencyWithdraw`
- **Notifier/Owner:** `notifyRewardAmount`, `finalizeEpoch`, `batchFinalize`
- **Users:** `claim(epoch)`

## External Interactions
- Pulls XPGN into locker on notify
- Reads usage points from `UsagePoints`
- Creates new ve locks or tops up existing ones
- Optionally transfers gas kickback to user

## Failure Modes
- Revert on:
  - funding finalized epoch
  - finalizing unfunded or zero-point epoch
  - claim before finalization
  - zero-share / dust claim
  - expired existing lock
  - existing lock shorter than required minimum reward lock
  - ve top-up failure

## Events
- `BudgetNotified(epoch, amount, from)`
- `EpochFinalized(epoch, totalPoints, finalBudget)`
- `Claimed(epoch, user, share, lockedAmount, unlockTime, tokenId)`
- `ExistingLockToppedUp(user, amountAdded, existingUnlockTime)`
- `RewardNotifierSet(notifier, allowed)`
- `LockConfig(minWeeks, maxWeeks, gasKickbackBips)`
- `EmergencyWithdraw(token, to, amount)`

## Tests Map
- **INV-TRL-01:** `test/TraderRewardsLocker.t.sol::testCannotFundAfterFinalization()`
- **INV-TRL-02:** `test/TraderRewardsLocker.t.sol::testClaimsUseFrozenFinalBudget()`
- **INV-TRL-03:** `test/TraderRewardsLocker.t.sol::testOnlyNotifierOrOwnerCanFinalize()`
- **INV-TRL-04:** `test/TraderRewardsLocker.t.sol::testCannotFinalizeWithoutBudgetAndPoints()`
- **INV-TRL-05:** `test/TraderRewardsLocker.t.sol::testUserCanClaimOnlyOncePerEpoch()`
- **INV-TRL-06:** `test/TraderRewardsLocker.t.sol::testExistingLockMustMeetMinRewardLock()`
- **INV-TRL-07:** `test/TraderRewardsLocker.t.sol::testExistingLockerTopUpPathWorks()`
