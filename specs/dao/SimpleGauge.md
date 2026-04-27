# SimpleGauge — SPEC

**Intent:**  
Accept stake deposits, stream XPGN rewards over a fixed duration, and let stakers claim pro-rata accrued emissions.

## State
- `stakingToken`
- `rewardToken`
- `controller`
- `minter`
- `DURATION`
- `periodFinish`
- `rewardRate`
- `lastUpdateTime`
- `rewardPerTokenStored`
- `totalSupply`
- `balanceOf[user]`
- `userRewardPerTokenPaid[user]`
- `rewards[user]`

## Invariants
- **INV-SG-01 (Reward accounting correctness):** On stake, withdraw, getReward, and notify, accrued rewards are preserved via reward-per-token accounting.
- **INV-SG-02 (Authorized notify only):** Only `minter` may call `notifyRewardAmount`.
- **INV-SG-03 (Leftover rollover):** Mid-period notify rolls leftover reward forward into new rate.
- **INV-SG-04 (Rate bounded by balance):** `rewardRate <= rewardToken.balanceOf(this) / DURATION`.
- **INV-SG-05 (Non-reentrant state changes):** Stake, withdraw, getReward, notify are non-reentrant.

## Permissions
- **DAO/Admin:** `setMinter`, `pause`, `unpause`
- **Users:** `stake`, `withdraw`, `getReward`, `exit`
- **Authorized minter:** `notifyRewardAmount`

## External Interactions
- Pulls staking token on stake
- Transfers staking token on withdraw
- Pulls reward token from minter on notify
- Transfers reward token on claim

## Failure Modes
- Revert on:
  - zero stake / zero withdraw
  - insufficient balance
  - unauthorized notify
  - zero reward rate
  - reward rate too high

## Events
- `Notified(amount, newRate, periodFinish)`
- `Staked(user, amount)`
- `Withdrawn(user, amount)`
- `RewardPaid(user, amount)`
- `SetMinter(minter)`

## Tests Map
- **INV-SG-01:** `test/SimpleGauge.t.sol::testAccrualAndClaimExact()`
- **INV-SG-02:** `test/SimpleGauge.t.sol::testOnlyMinterCanNotify()`
- **INV-SG-03:** `test/SimpleGauge.t.sol::testLeftoverRollsForward()`
- **INV-SG-04:** `test/SimpleGauge.t.sol::testRewardRateBoundedByBalance()`
- **INV-SG-05:** `test/SimpleGauge.t.sol::testNonReentrantFlows()`
