# ParagonFarmController — SPEC

**Intent:** Master farm contract that tracks LP staking across pools, accrues block-based rewards (with optional epoch schedule), supports referral + boost integrations, takes a capped performance fee on harvests, and can auto-top-up rewards from a streaming **RewardDripperEscrow**.

---

## State

### Core config
- `rewardToken: IERC20` — reward token (XPGN).
- `rewardPerBlock: uint256` — current global RPB (may be set directly or derived from epochs).
- `totalAllocPoint: uint256` — sum of pool `allocPoint`.
- `startBlock: uint256` — emissions start.

### Integrations
- `referralManager: IReferralManager` — optional; records referrers.
- `boostManager: IBoostManager` — optional; returns boost in **bps** per user/pool.
- `govPower: IParagonGovPower` — optional; recomputed on user actions.

### Pools & users
- `PoolInfo[] poolInfo` where each pool has:
  - `lpToken: IERC20`
  - `allocPoint: uint256`
  - `lastRewardBlock: uint256`
  - `accRewardPerShare: uint256` (scaled 1e12)
  - `harvestDelay: uint256` (sec)
  - `vestingDuration: uint256` (sec, informational in this version)
  - `totalStaked: uint256`
- `userInfo[pid][user] → UserInfo`:
  - `amount`, `rewardDebt`, `lastDepositTime`.
- `rewardTokenStakedTotal: uint256` — amount of `rewardToken` staked as LP across pools (protects principal).
- `autoYieldRouter: address` + `autoYieldDeposited[pid][user]`.

### Epoch emissions (optional)
- `epochs: EmissionEpoch[]` with `{ endBlock, rewardPerBlock }` (end inclusive).
- `currentEpochIndex: uint256`
- `epochsEnabled: bool`
- `emissionsPaused: bool`

### Dripper automation
- `dripper: IRewardDripper`
- `lowWaterDays: uint256` — target runway (default **3** days).
- `dripCooldownSecs: uint64` — min interval between drips (default **900**).
- `lastDripAt: uint64`
- `minDripAmount: uint256` — minimum pending accrued in dripper to attempt drip (default **1e18**).

### Performance fee
- `MAX_PERF_FEE_BIPS = 500` (5.00% hard cap)
- `feeRecipient: address`
- `performanceFeeBips: uint16`

---

## API

### Admin (onlyOwner)
- **Integrations:** `setReferralManager`, `setBoostManager`, `setGovPower`, `setAutoYieldRouter`.
- **Emissions direct:** `setRewardPerBlock`, `setEmissionsPaused(bool)`.
- **Epochs:** `enableEpochs(bool)`, `setEpochs(endBlocks[], rewards[])` (strictly ascending), `configureSuperFarm90d(superRPB, baseRPB)`, `configureSuperFarm90dDefault()`.
- **Pools:** `addPool(alloc, lp, harvestDelay, vestingDuration)`, `setPool(pid, alloc, harvestDelay, vestingDuration)`, `setAllocPointsBatch(pids[], allocs[])`.
- **Fees:** `setPerformanceFee(recipient, bips)` (≤ **500**).
- **Dripper:** `setDripper(addr)`, `setLowWaterDays(days)`, `setDripCooldownSecs(secs)`, `setMinDripAmount(amount)`.

### User flows
- `depositFor(pid, amount, user, referrer)` — pulls `amount` from `msg.sender`. If `msg.sender != autoYieldRouter`, sets `lastDepositTime = now`; otherwise records `autoYieldDeposited`.
- `harvest(pid)` — pays pending net rewards (after fee) if `now ≥ lastDepositTime + harvestDelay`.
- `withdraw(pid, amount)` — harvests (subject to delay), then withdraws stake.
- `emergencyWithdraw(pid)` — withdraws stake, zeroes user accounting, no rewards.

### Views
- `poolLength()`, `poolLpToken(pid)`, `pendingReward(pid, user)`, `pendingRewardAfterFee(pid, user)`, `getUserOverview(pid, user)`.
- `pokeDripper()` — public convenience to trigger a guarded top-up (no state change if guards fail).

---

## Invariants

### Pools & accounting
- **INV-FARM-01 (Accrual math):** `accRewardPerShare` increases by `reward * 1e12 / lpSupply` where `reward` is computed across the exact block interval and epoch segments.
- **INV-FARM-02 (RewardDebt rule):** After each user action, `rewardDebt = amount * accRewardPerShare / 1e12`.
- **INV-FARM-03 (Harvest delay):** Harvest only pays if `now ≥ lastDepositTime + harvestDelay`. Otherwise, pending is not transferred (but accounting updates).
- **INV-FARM-04 (No negative allocTotal):** `totalAllocPoint` equals the sum of pool `allocPoint` after adds/sets/batch sets.
- **INV-FARM-05 (Non-reentrancy):** `depositFor`, `withdraw`, `harvest`, `emergencyWithdraw` are `nonReentrant`.

### Emissions & epochs
- **INV-FARM-06 (Epoch ordering):** `endBlocks` strictly increasing in `setEpochs`; `currentEpochIndex` always points to the first epoch whose `endBlock ≥ current block` (or past-end sentinel).
- **INV-FARM-07 (Derived RPB):** When epochs enabled, `rewardPerBlock` equals `epochs[currentEpochIndex].rewardPerBlock` (or `0` if past last epoch).
- **INV-FARM-08 (Paused emissions):** If `emissionsPaused` or `totalAllocPoint == 0` or `lpSupply == 0`, a pool update sets `lastRewardBlock = current block` and accrues **0**.

### Dripper safety
- **INV-FARM-09 (Runway guard):** `_maybeTopUpFromDripper()` triggers only if `available < rewardPerBlock * blocksPerDay * lowWaterDays`.
- **INV-FARM-10 (Throttle):** A drip attempt requires `block.timestamp ≥ lastDripAt + dripCooldownSecs`.
- **INV-FARM-11 (Min amount & resilience):** Requires `dripper.pendingAccrued() ≥ minDripAmount`; external calls are wrapped in `try/catch` so user flows never revert due to dripper.
- **INV-FARM-12 (No recursion):** If `msg.sender == dripper`, top-up is skipped.

### Fees & boosts
- **INV-FARM-13 (Fee cap):** `performanceFeeBips ≤ 500` (5%); harvest fee = `pending * bips / 10000`, paid to `feeRecipient`.
- **INV-FARM-14 (Boost bounds):** If `boostManager` set, `pending` is multiplied by `(10000 + boostBips)/10000` (no underflow/overflow for uint256 path).

### Reward safety
- **INV-FARM-15 (Principal protection):** Rewards can only be paid from `_availableRewards() = balanceOf(rewardToken) - rewardTokenStakedTotal` (never spend users’ staked principal even when the LP token is the reward token).

---

## External Interactions
- **ERC-20:** `lpToken.safeTransferFrom/transfer`; `rewardToken.safeTransfer`.
- **Referrals:** `referralManager.recordReferral(user, referrer)` if both set.
- **Boosts:** `boostManager.getBoost(user, pid)` to scale pending.
- **Gov power:** `govPower.recompute(user)` called after deposit/harvest/withdraw (best-effort via `try/catch`).
- **Dripper:** `dripper.pendingAccrued()` and `dripper.drip()` (permissionless top-up, guarded).

---

## Failure Modes
- Admin guards: zero addresses (reward token in ctor), epoch lists length mismatch or unsorted (`"epochs: length mismatch"`, `"epochs: not sorted"`).
- Pool ops: add with zero LP address, withdraw more than staked (`"Farm: insufficient"`), emergency withdraw with zero amount.
- Harvest gating: harvest before delay simply yields no transfer.
- Dripper: guarded; failures are swallowed (no revert of user flows).

---

## Events
- **User:** `Deposit(user, pid, amount)`, `Withdraw(user, pid, amount)`, `EmergencyWithdraw(user, pid, amount)`, `Harvest(user, pid, netAmount)`.
- **Pools/Admin:** `PoolAdded(pid, lp, alloc)`, `PoolUpdated(pid, alloc, harvestDelay, vestingDuration)`, `AllocPointsBatchSet(count)`, `MassPoolUpdate(count)`.
- **Emissions:** `RewardPerBlockUpdated(newRate)`, `EmissionsPaused(paused)`, `EpochsReplaced(count)`, `EpochsEnabled(enabled)`, `SuperFarmConfigured(endSuper, endBase, superRPB, baseRPB)`.
- **Integrations:** `AutoYieldRouterUpdated(router)`, `AutoYieldDeposit(user, pid, amount, router)`, `GovPowerUpdated(govPower)`.
- **Fees:** `PerformanceFeeUpdated(recipient, bips)`, `HarvestFeeTaken(user, pid, feeAmount)`.
- **Dripper:** `DripperUpdated(dripper)`, `LowWaterDaysUpdated(days)`, `DripperCooldownUpdated(secs)`, `MinDripAmountUpdated(amount)`, `DripperPoked(sent, availableAfter)`.

---

## Tests Map (suggested)
- **INV-FARM-01/02:** `test/Farm.t.sol::testAccrualAndRewardDebt()`
- **INV-FARM-03:** `test/Farm.t.sol::testHarvestDelayGating()`
- **INV-FARM-04:** `test/Farm.t.sol::testTotalAllocPointConsistency()`
- **INV-FARM-05:** `test/Farm.t.sol::testNonReentrancyGuards()`
- **INV-FARM-06/07:** `test/Farm.t.sol::testEpochScheduleAndDerivedRPB()`
- **INV-FARM-08:** `test/Farm.t.sol::testPausedOrZeroSupplyAccruesZero()`
- **INV-FARM-09/10/11/12:** `test/Farm.t.sol::testDripperRunwayCooldownMinAndNoRecursion()`
- **INV-FARM-13:** `test/Farm.t.sol::testPerformanceFeeCapAndPayment()`
- **INV-FARM-14:** `test/Farm.t.sol::testBoostApplicationBounds()`
- **INV-FARM-15:** `test/Farm.t.sol::testAvailableRewardsNeverDipIntoPrincipal()`
