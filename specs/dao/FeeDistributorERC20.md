# FeeDistributorERC20 — SPEC

**Intent:**  
Receive weekly ERC20 protocol fee rewards and let ve holders claim them pro-rata based on **finalized end-of-week ve balance snapshots**.

## State
- `reward` — immutable reward token for this distributor
- `ve` — `VoterEscrow` snapshot source
- `epochRewards[weekTs]` — reward funded for a week
- `epochSupply[weekTs]` — finalized ve supply snapshot for that week
- `epochFinalized[weekTs]` — whether week snapshot is finalized
- `userLastClaim[user]` — last fully processed week
- `rewardNotifiers[addr]` — approved reward funders

## Invariants
- **INV-FD-01 (Single reward token):** Distributor only accounts one immutable reward token.
- **INV-FD-02 (Actual received accounting):** `notifyRewardAmount(amount)` credits only actual received balance delta.
- **INV-FD-03 (Closed weeks only):** `finalizeEpoch(weekTs)` may only finalize fully closed weeks.
- **INV-FD-04 (Snapshot-based claims):** Claims use `ve.balanceOfAtTime(user, weekTs + WEEK - 1)` divided by finalized `epochSupply[weekTs]`.
- **INV-FD-05 (No unfinalized claim leakage):** Claim loop stops when it reaches an unfinalized week.
- **INV-FD-06 (Bounded processing):** Claim processing is bounded by `MAX_CLAIM_WEEKS`.

## Permissions
- **DAO/Admin:** `setRewardNotifier`, `pause`, `unpause`, `emergencyWithdraw`
- **Notifier/Owner:** `notifyRewardAmount(amount)`
- **Anyone/Ops bot:** `finalizeEpoch`, `batchFinalize`
- **Anyone:** `claim(user)`

## External Interactions
- Pulls `reward` token into the contract
- Reads `ve.totalSupplyAtTime(ts)` and `ve.balanceOfAtTime(user, ts)`
- Transfers reward token to claimant

## Failure Modes
- Revert on:
  - zero amount funding
  - zero received amount
  - notifier unauthorized
  - finalizing current/open week
  - duplicate finalization

## Events
- `RewardNotified(weekTs, amount, from)`
- `EpochFinalized(weekTs, veSupply)`
- `Claimed(user, amount, fromWeek, toWeek)`
- `RewardNotifierSet(notifier, allowed)`
- `EmergencyWithdraw(token, to, amount)`

## Tests Map
- **INV-FD-01:** `test/FeeDistributorERC20.t.sol::testImmutableRewardToken()`
- **INV-FD-02:** `test/FeeDistributorERC20.t.sol::testNotifyUsesActualReceivedDelta()`
- **INV-FD-03:** `test/FeeDistributorERC20.t.sol::testFinalizeClosedWeeksOnly()`
- **INV-FD-04:** `test/FeeDistributorERC20.t.sol::testClaimUsesWeekEndSnapshots()`
- **INV-FD-05:** `test/FeeDistributorERC20.t.sol::testClaimStopsAtFirstUnfinalizedWeek()`
- **INV-FD-06:** `test/FeeDistributorERC20.t.sol::testClaimBoundedByMaxWeeks()`
