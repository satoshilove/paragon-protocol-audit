# ParagonFarmController — SPEC (Final, Dripper-Integrated)

**Contract:** `ParagonFarmController.sol`  
**Intent:** Master farm contract that tracks LP staking across pools, accrues block-based rewards, supports referral + auto-yield integrations, takes a capped performance fee on harvests, and can auto-top-up rewards from a streaming `RewardDripperEscrow` without ever touching users’ staked principal (even when the LP token **is** the reward token).

---

## 1. State

### 1.1 Core config

- `rewardToken: IERC20 immutable` — reward token (XPGN).
- `rewardPerBlock: uint256` — global reward emission per block.
- `totalAllocPoint: uint256` — sum of all pool `allocPoint`.
- `startBlock: uint256` — emissions start block.
- `emissionsPaused: bool` — when `true`, pools update `lastRewardBlock` but emit **0** rewards.

### 1.2 Roles & pause

- Inherits `Ownable`, `AccessControl`, `Pausable`, `ReentrancyGuard`.
- `GUARDIAN_ROLE: bytes32` — may call `pause()`.
- `pause()` — guardian-only; pauses user flows (deposit / withdraw / harvest).
- `unpause()` — owner-only (DAO / timelock).

### 1.3 Integrations

- `referralManager: IReferralManager` — optional; called on deposits with non-zero `referrer`.
- `autoYieldRouter: address` — optional; special router that can call `depositFor` on behalf of users.
- `autoYieldDeposited[pid][user]: uint256` — amount that came in via `autoYieldRouter` (for UI/analytics).

### 1.4 Pools & users

- `PoolInfo[] public poolInfo` where each pool has:
  - `lpToken: IERC20` — staked token.
  - `allocPoint: uint256` — relative share of emissions.
  - `lastRewardBlock: uint256` — last block where rewards were accrued.
  - `accRewardPerShare: uint256` — cumulative rewards per LP share (× 1e12).
  - `harvestDelay: uint256` — per-pool minimum delay (seconds) before rewards can be claimed.
  - `totalStaked: uint256` — total LP tokens staked in this pool.
  - `rewardTokenStaked: uint256` — amount of `rewardToken` that is staked as LP *in this pool*.
- `userInfo[pid][user] → UserInfo`:
  - `amount: uint256` — LP tokens staked by user.
  - `rewardDebt: uint256` — standard “debt” for MasterChef accounting.
  - `lastDepositTime: uint256` — timestamp of the last *non–auto-yield* deposit.
  - `unpaid: uint256` — accumulated rewards that could not yet be paid (insufficient farm balance or harvestDelay not reached).
- Global principal-protection cache:
  - `totalRewardTokenStakedAsLP: uint256` — sum of `rewardTokenStaked` over all pools; used to ensure rewards come only from “free” tokens, not users’ principal.

### 1.5 Dripper automation

- `dripper: IRewardDripper` — optional streaming escrow (typically `RewardDripperEscrow`).
- `lowWaterDays: uint256` — target runway in days (default: `3`).
- `dripCooldownSecs: uint64` — min seconds between dripper calls (default: `900` = 15 min).
- `lastDripAt: uint64` — last time a successful drip occurred.
- `minDripAmount: uint256` — minimum `pendingAccrued` in dripper before attempting a drip (default: `1e18`).

### 1.6 Performance fee

- `uint16 public constant MAX_PERF_FEE_BIPS = 500;` — hard cap 5.00%.
- `feeRecipient: address` — destination of performance fee on harvest.
- `performanceFeeBips: uint16` — current fee in basis points (0–500).

---

## 2. API

### 2.1 Admin (onlyOwner)

**Core config**

- `setRewardPerBlock(uint256 _rpb)`  
  - Calls `massUpdateAllPools()` first, then updates `rewardPerBlock` and emits `RewardPerBlockUpdated(oldRate, newRate)`.

- `setEmissionsPaused(bool _paused)`  
  - Sets `emissionsPaused` and emits `EmissionsPaused(_paused)`.

**Integrations**

- `setReferralManager(address _ref)` — sets `referralManager`.
- `setAutoYieldRouter(address _router)` — sets `autoYieldRouter`.

**Dripper integration**

Primary unified setter:

- `setDripperConfig(address _dripper, uint256 _days, uint64 _cooldown, uint256 _min)`  
  - Sets `dripper`, `lowWaterDays`, `dripCooldownSecs`, `minDripAmount`.  
  - Emits `DripperConfigUpdated(dripper, lowWaterDays, dripCooldownSecs, minDripAmount)`.

Backwards-compatible convenience aliases (used by JS tests & older tooling):

- `setDripper(address _dripper)` — calls `setDripperConfig(_dripper, lowWaterDays, dripCooldownSecs, minDripAmount)`.
- `setLowWaterDays(uint256 _days)` — sets `lowWaterDays` and emits `DripperConfigUpdated(...)`.
- `setDripCooldownSecs(uint64 _secs)` — sets `dripCooldownSecs` and emits `DripperConfigUpdated(...)`.
- `setMinDripAmount(uint256 _min)` — sets `minDripAmount` and emits `DripperConfigUpdated(...)`.

**Pools**

- `addPool(uint256 _allocPoint, IERC20 _lpToken, uint256 _harvestDelay)`  
  - Calls `massUpdateAllPools()`.
  - Pushes new `PoolInfo` with initial `lastRewardBlock = max(block.number, startBlock)`.
  - Updates `totalAllocPoint += _allocPoint`.
  - Emits `PoolAdded(pid, lpToken, allocPoint, harvestDelay)`.

- `setPool(uint256 _pid, uint256 _allocPoint, uint256 _harvestDelay)`  
  - Calls `massUpdateAllPools()`.
  - Adjusts `totalAllocPoint` and updates pool’s `allocPoint` and `harvestDelay`.
  - Emits `PoolUpdated(pid, allocPoint, harvestDelay)`.

- `massUpdateAllPools()` — iterates all pools, calling `updatePool(i)`.

**Fees**

- `setPerformanceFee(address _recipient, uint16 _bips)`  
  - Requires `_recipient != address(0)` and `_bips <= MAX_PERF_FEE_BIPS`.
  - Updates `feeRecipient`, `performanceFeeBips`.
  - Emits `PerformanceFeeUpdated(recipient, bips)`.

**Pause / roles**

- `pause()` — `onlyRole(GUARDIAN_ROLE)`; pauses user flows (but not admin/config).
- `unpause()` — `onlyOwner`; resumes user flows.

### 2.2 Dripper automation

- `pokeDripper()` — external, permissionless; calls internal `_maybeTopUpFromDripper()`.

Internal logic:

- `_maybeTopUpFromDripper()`:
  - No-op if:
    - `dripper == address(0)` OR
    - `emissionsPaused` OR
    - `rewardPerBlock == 0` OR
    - `block.timestamp < lastDripAt + dripCooldownSecs`.
  - Computes target runway:  
    `need = rewardPerBlock * 115200 * lowWaterDays` (≈ 115,200 blocks/day).
  - If `_availableRewards() >= need`, returns (enough runway).
  - Otherwise, tries in `try/catch`:
    - `pendingAccrued = dripper.pendingAccrued()`
    - If `pendingAccrued >= minDripAmount`:
      - Calls `dripper.drip()`; on success:
        - Updates `lastDripAt = uint64(block.timestamp)`
        - Emits `DripperPoked(sent, _availableRewards())`
  - Any errors from dripper are swallowed (no reverts).

### 2.3 User flows

All user flows are `nonReentrant`. `depositFor`, `harvest`, `withdraw` are gated by `whenNotPaused`.

- `depositFor(uint256 _pid, uint256 _amount, address _user, address _referrer)`  
  - Requires `msg.sender == _user || msg.sender == autoYieldRouter`.
  - `updatePool(_pid)` first.
  - If user already has `amount > 0`, their pending reward (based on current `accRewardPerShare`) is added to `user.unpaid`.
  - If `_amount > 0`:
    - Pulls tokens: `pool.lpToken.safeTransferFrom(msg.sender, address(this), _amount)`.
    - Updates `user.amount`, `pool.totalStaked`.
    - If `lpToken == rewardToken`:
      - Increments `pool.rewardTokenStaked` and `totalRewardTokenStakedAsLP`.
    - If `msg.sender != autoYieldRouter`:
      - `user.lastDepositTime = block.timestamp`.
    - Else:
      - Increments `autoYieldDeposited[_pid][_user]` and emits `AutoYieldDeposit(user, pid, amount)`.
  - Updates `user.rewardDebt = user.amount * accRewardPerShare / 1e12`.
  - If `_referrer` and `referralManager` are non-zero, calls `referralManager.recordReferral(_user, _referrer)`.
  - Emits `Deposit(_user, _pid, _amount)`.

- `harvest(uint256 _pid)`  
  - `updatePool(_pid)`.
  - Computes `pending = user.amount * accRewardPerShare / 1e12 - user.rewardDebt`.
  - `gross = user.unpaid + pending`; resets `user.rewardDebt` to current and `user.unpaid = 0`.
  - If `gross == 0` or `block.timestamp < user.lastDepositTime + harvestDelay`:
    - Defers: `user.unpaid = gross` and returns (no transfer).
  - Otherwise:
    - `available = _availableRewards()`.
    - `pay = min(gross, available)`.
    - If `pay > 0`:
      - `fee = performanceFeeBips > 0 ? pay * performanceFeeBips / 10000 : 0`.
      - `net = pay - fee`.
      - If `fee > 0`, transfers `fee` to `feeRecipient` and emits `HarvestFeeTaken(user, pid, fee)`.
      - If `net > 0`, transfers `net` to user and emits `Harvest(user, pid, net)`.
    - If `gross > pay`, sets `user.unpaid = gross - pay`.

- `withdraw(uint256 _pid, uint256 _amount)`  
  - Requires `user.amount >= _amount`.
  - `updatePool(_pid)`.
  - Computes `pending` and `gross` as in `harvest`.
  - If `block.timestamp ≥ user.lastDepositTime + harvestDelay`, attempts harvest (same fee logic) into user; otherwise keeps `gross` in `user.unpaid`.
  - If `_amount > 0`:
    - Decrements `user.amount`, `pool.totalStaked`.
    - If `lpToken == rewardToken`, decrements `pool.rewardTokenStaked` and `totalRewardTokenStakedAsLP`.
    - Transfers `_amount` to user and emits `Withdraw(user, pid, amount)`.
  - Updates `user.rewardDebt`.

- `emergencyWithdraw(uint256 _pid)`  
  - **Not** paused (available even in emergencies).
  - Reads `amount = user.amount`; requires `amount > 0`.
  - Sets `user.amount = 0`, `rewardDebt = 0`, `unpaid = 0`.
  - Decrements `pool.totalStaked` and, if applicable, `pool.rewardTokenStaked` and `totalRewardTokenStakedAsLP`.
  - Transfers `amount` to user and emits `EmergencyWithdraw(user, pid, amount)`.

### 2.4 Views

- `pendingReward(uint256 _pid, address _user) → uint256`  
  - Simulates `updatePool` effect on `accRewardPerShare` (if applicable) and returns `user.unpaid + (user.amount * acc / 1e12 − user.rewardDebt)`.

- `pendingRewardAfterFee(uint256 _pid, address _user) → (uint256 net, uint256 gross)`  
  - Public view wrapper that calls `pendingReward` and applies `performanceFeeBips` to compute `net`.

- `claimableRewardAfterFee(uint256 _pid, address _user) → uint256`  
  - Returns `0` if harvestDelay not satisfied; otherwise `pendingRewardAfterFee().net`.

- `availableRewards() → uint256`  
  - Wrapper for `_availableRewards()`:
    - `bal = rewardToken.balanceOf(address(this))`
    - Returns `bal > totalRewardTokenStakedAsLP ? (bal − totalRewardTokenStakedAsLP) : 0`.

- `poolLength() → uint256` — `poolInfo.length`.

(Optionally, repo may also expose `getUserOverview(pid, user)` for UI, combining `[amount, pending, autoYieldDeposited, lastDepositTime]`.)

---

## 3. Invariants

### 3.1 Pools & accounting

- **INV-FARM-01 (Accrual math):**  
  For any pool with `lpSupply > 0`, `totalAllocPoint > 0`, and `!emissionsPaused`, a call to `updatePool(pid)` increases `accRewardPerShare` by  
  `reward * 1e12 / lpSupply`, where `reward` is computed as:  
  `blocks * rewardPerBlock * allocPoint / totalAllocPoint`.

- **INV-FARM-02 (RewardDebt rule):**  
  After any user action that changes `amount`,  
  `user.rewardDebt == user.amount * pool.accRewardPerShare / 1e12`.

- **INV-FARM-03 (Harvest delay):**  
  Rewards are only transferred if `block.timestamp ≥ user.lastDepositTime + harvestDelay`.  
  Otherwise, all pending is moved into `user.unpaid` and not transferred.

- **INV-FARM-04 (Alloc sum):**  
  `totalAllocPoint` always equals the sum of all `pool.allocPoint` after any add/set/batch changes.

- **INV-FARM-05 (Non-reentrancy):**  
  `depositFor`, `withdraw`, `harvest`, `emergencyWithdraw` are `nonReentrant`.

### 3.2 Dripper safety

- **INV-FARM-06 (Runway guard):**  
  `_maybeTopUpFromDripper()` only calls `drip()` if  
  `_availableRewards() < rewardPerBlock * 115200 * lowWaterDays`.

- **INV-FARM-07 (Cooldown):**  
  `_maybeTopUpFromDripper()` requires  
  `block.timestamp ≥ lastDripAt + dripCooldownSecs`,  
  otherwise returns early.

- **INV-FARM-08 (Min amount & resilience):**  
  - Requires `dripper.pendingAccrued() ≥ minDripAmount` to attempt drip.  
  - Any errors from `pendingAccrued()` or `drip()` are caught via `try/catch` and **never** revert user flows or pool updates.

- **INV-FARM-09 (Underfunded dripper):**  
  When the dripper has `balance == 0` but `pendingAccrued > 0`, calls to `updatePool` still succeed; `_availableRewards()` stays unchanged and `drip()` (if called) simply sends `0`.

### 3.3 Fees

- **INV-FARM-10 (Fee cap):**  
  `performanceFeeBips ≤ MAX_PERF_FEE_BIPS` at all times.

- **INV-FARM-11 (Fee calculation):**  
  For any harvestable `pay`,  
  `fee = pay * performanceFeeBips / 10000` and `net = pay − fee`,  
  with `fee` transferred to `feeRecipient` and `net` to the user.

### 3.4 Reward safety

- **INV-FARM-12 (Principal protection):**  
  Reward transfers always come from `_availableRewards()` = `balanceOf(rewardToken) − totalRewardTokenStakedAsLP`.  
  This ensures that when the LP token equals `rewardToken`, users’ staked principal is never spent as “rewards”.

---

## 4. External Interactions

- **ERC-20 tokens**
  - `lpToken.safeTransferFrom(msg.sender, this, amount)`
  - `lpToken.safeTransfer(user, amount)`
  - `rewardToken.safeTransfer(user/feeRecipient, amount)`

- **Referral manager**
  - `referralManager.recordReferral(user, referrer)` when both non-zero.

- **Dripper**
  - `dripper.pendingAccrued()`
  - `dripper.drip()`

All dripper calls are wrapped in `try/catch` and cannot break user flows.

---

## 5. Failure Modes

- Admin:
  - Zero recipient in `setPerformanceFee` ⇒ revert `"zero recipient"`.
  - Zero reward token in constructor ⇒ revert `"zero reward token"`.
- Pools:
  - Withdraw more than staked ⇒ revert `"insufficient"`.
  - Emergency withdraw with zero amount ⇒ revert `"nothing to withdraw"`.
- General:
  - Standard ERC-20 `safeTransferFrom/transfer` failures if balances/allowances are insufficient.

---

## 6. Events

- **User**
  - `Deposit(address indexed user, uint256 indexed pid, uint256 amount)`
  - `Withdraw(address indexed user, uint256 indexed pid, uint256 amount)`
  - `Harvest(address indexed user, uint256 indexed pid, uint256 netAmount)`
  - `EmergencyWithdraw(address indexed user, uint256 indexed pid, uint256 amount)`

- **Pools/Admin**
  - `PoolAdded(uint256 indexed pid, address lpToken, uint256 allocPoint, uint256 harvestDelay)`
  - `PoolUpdated(uint256 indexed pid, uint256 allocPoint, uint256 harvestDelay)`
  - `RewardPerBlockUpdated(uint256 oldRate, uint256 newRate)`
  - `EmissionsPaused(bool paused)`

- **Auto-yield**
  - `AutoYieldDeposit(address indexed user, uint256 indexed pid, uint256 amount)`

- **Fees**
  - `PerformanceFeeUpdated(address indexed recipient, uint16 feeBips)`
  - `HarvestFeeTaken(address indexed user, uint256 indexed pid, uint256 feeAmount)`

- **Dripper**
  - `DripperPoked(uint256 sent, uint256 availableAfter)`
  - `DripperConfigUpdated(address dripper, uint256 lowWaterDays, uint64 cooldown, uint256 minDrip)`

---

## 7. Tests Map (JS + Solidity)

Examples (adapt to your actual file names):

- **INV-FARM-01/02:**  
  `test/farms/ParagonFarmController.core.spec.js::INV-FARM-01` (accrual math)  
  `test/farms/ParagonFarmController.core.spec.js::INV-FARM-02` (rewardDebt rule)

- **INV-FARM-03 (harvest delay):**  
  `test/farms/ParagonFarmController.core.spec.js::INV-FARM-03`

- **INV-FARM-04 (alloc sum):**  
  `test/farms/ParagonFarmController.core.spec.js::ADMIN-FARM-ALLOC-01`

- **INV-FARM-05 (nonReentrant):**  
  `test/farms/ParagonFarmController.security.spec.js::INV-FARM-REENTRANCY-01`

- **INV-FARM-06/07/08/09 (dripper guards):**  
  `test/farms/DripperFarm.handshake.spec.js`  
  `test/farms/ParagonFarmController.security.spec.js::INV-FARM-EDGE-01`  
  `test/farms/ParagonFarmController.security.spec.js::INV-FARM-ATTACK-01`

- **INV-FARM-10/11 (fee cap & calc):**  
  `test/farms/ParagonFarmController.core.spec.js::INV-FARM-13`

- **INV-FARM-12 (principal protection):**  
  `test/farms/ParagonFarmController.core.spec.js::INV-FARM-PRINCIPAL-01`


---

# RewardDripperEscrow — SPEC (Final)

**Contract:** `RewardDripperEscrow.sol`  
**Intent:** Hold XPGN rewards and stream them to `farm` at a configurable **tokens/second** rate, with a future **rate schedule**, an optional **pull model** (farm has allowance), and a **per-tx drip cap**, while exposing a clean, accrual-correct `pendingAccrued()` view.

---

## 1. State

- `IERC20 public immutable rewardToken` — XPGN reward token.
- `address public farm` — recipient (e.g., `ParagonFarmController`).
- `uint64 public lastAccrue` — last timestamp used for accrual.
- `uint192 public currentRatePerSec` — active streaming rate (assumes 18-decimals token).
- `uint256 public accrued` — claimable but not yet sent amount.
- `RateChange[] public schedule` — future rate changes `{ uint64 startTime; uint192 ratePerSec; }`, sorted strictly by `startTime`.
- `uint256 public maxDripPerTx` — per-transaction cap on how much can flow out (default `type(uint256).max`).
- `bool public farmPullEnabled` — when `true`, escrow approves `farm` for `rewardToken` max allowance; when `false`, allowance is zero.

---

## 2. API

### 2.1 Admin (onlyOwner)

- `setFarm(address newFarm)`  
  - Requires `newFarm != address(0)`.  
  - If `farmPullEnabled == true`:
    - `forceApprove(oldFarm, 0)`
    - `forceApprove(newFarm, type(uint256).max)`  
  - Updates `farm` and emits `FarmUpdated(newFarm)`.

- `scheduleRate(uint64 startTime, uint192 ratePerSec)`  
  - Adds future rate change:
    - `startTime >= block.timestamp`
    - If `schedule.length > 0`, requires `startTime > schedule[last].startTime`.
  - Emits `RateScheduled(startTime, ratePerSec)`.

- `scheduleRateAfter(uint64 delaySeconds, uint192 ratePerSec)`  
  - Convenience wrapper with `startTime = block.timestamp + delaySeconds`.
  - Same ordering constraints as `scheduleRate`.

- `clearSchedule()`  
  - `delete schedule;` — does not change `accrued` or `currentRatePerSec`.

- `fund(uint256 amount)`  
  - Transfers `amount` XPGN from owner to escrow.  
  - Emits `Funded(owner, amount)`.

- `setRatePerSec(uint192 ratePerSec)`  
  - Calls `_applyAccrual()` to bring `accrued` up to now.  
  - Sets `currentRatePerSec = ratePerSec` and emits `RateApplied(now, ratePerSec)`.

- `setWeeklyAmount(uint256 tokensPerWeek)`  
  - Calls `_applyAccrual()`.  
  - Sets `currentRatePerSec` to `ceil(tokensPerWeek / 604800)` (7 days).  
  - Emits `RateApplied(now, newRate)`.

- `setMaxDripPerTx(uint256 newMax)`  
  - Requires `newMax > 0`.  
  - Updates `maxDripPerTx` and emits `MaxDripPerTxUpdated(newMax)`.

- `setFarmPullEnabled(bool enabled)`  
  - Updates `farmPullEnabled`.  
  - If `enabled`:
    - `rewardToken.forceApprove(farm, type(uint256).max)`  
  - Else:
    - `rewardToken.forceApprove(farm, 0)`  
  - Emits `FarmPullEnabledUpdated(enabled)`.

- `rescue(address token, address to)`  
  - Requires `to != address(0)`.  
  - Transfers **full** balance of `token` to `to`.

### 2.2 Public

- `drip() external nonReentrant returns (uint256 sent)`  
  - Calls `_applyAccrual()` first.
  - Let:
    - `bal = rewardToken.balanceOf(address(this))`
    - `toSend = min(accrued, bal, maxDripPerTx)`
  - If `toSend > 0`:
    - `accrued -= toSend`
    - `rewardToken.safeTransfer(farm, toSend)`
  - Emits `Dripped(accruedBefore, sent, accruedAfter, at)` where:
    - `accruedBefore = accrued + toSend`
    - `accruedAfter = accrued`
    - `at = uint64(block.timestamp)`
  - Returns `sent`.

- **Views**
  - `pendingAccrued() → uint256`  
    - Uses `_previewAccrual()` to compute additional accrual since `lastAccrue` and returns `accrued + addl`.
  - `scheduleCount() → uint256` — `schedule.length`.

---

## 3. Accrual Model

Internal helpers:

- `_previewAccrual() internal view returns (uint256 addl, uint64 newLast, uint192 newRate)`  
  - Starts from:
    - `t0 = lastAccrue == 0 ? now : lastAccrue`
    - `t = now`
    - `r = currentRatePerSec`
  - Iterates over all `schedule[i]` with `schedule[i].startTime <= t`:
    - For each change:
      - Accrues `r * (cut − t0)` if `cut > t0`.
      - Sets `r = schedule[i].ratePerSec`, `t0 = cut`.
  - After schedule loop, if `t > t0`, accrues `r * (t − t0)`.
  - Returns:
    - `addl` — additional tokens accrued since `lastAccrue`.
    - `newLast = t`.
    - `newRate = r`.

- `_applyAccrual()`  
  - Calls `_previewAccrual()`; adds `addl` into `accrued`, updates `lastAccrue`, and if `newRate != currentRatePerSec` sets `currentRatePerSec = newRate` and emits `RateApplied(newLast, newRate)`.

---

## 4. Invariants

- **INV-RDE-01 (Schedule ordering):**  
  Each `RateChange.startTime` is `≥ now` at insertion and strictly greater than the previous entry’s `startTime`.

- **INV-RDE-02 (Accrual correctness):**  
  `pendingAccrued()` equals `accrued + ∑(rate_i * Δt_i)` over all time segments since `lastAccrue` up to `now`, respecting scheduled rate changes.

- **INV-RDE-03 (Monotone accrued):**  
  `accrued` is non-decreasing over time except when reduced exactly by `sent` in `drip()`.

- **INV-RDE-04 (Immediate rate changes):**  
  `setRatePerSec` and `setWeeklyAmount` always apply accrual up to the current timestamp before updating `currentRatePerSec`.

- **INV-RDE-05 (Drip bounds):**  
  In any call to `drip()`:
  - `sent == min(accrued_before, balance, maxDripPerTx)`
  - `accrued_after == accrued_before − sent`.

- **INV-RDE-06 (Non-reentrancy):**  
  `drip()` is marked `nonReentrant`.

- **INV-RDE-07 (Pull-model safety):**  
  When `farmPullEnabled` toggles or `setFarm` is called, allowances are updated such that:
  - Old `farm` has allowance `0`.
  - New `farm` has allowance `type(uint256).max` if `farmPullEnabled == true`, otherwise `0`.

- **INV-RDE-08 (Schedule clear):**  
  `clearSchedule()` only deletes `schedule` and does not modify `accrued`, `lastAccrue`, or `currentRatePerSec`.

- **INV-RDE-09 (Zero guards):**  
  Constructor, `setFarm`, and `rescue(token, to)` forbid zero addresses; `setMaxDripPerTx` requires `newMax > 0`.

---

## 5. Failure Modes

- Zero address guards:
  - `"Escrow: zero"` / `"Escrow: zero farm"` / `"Escrow: zero to"`.
- Schedule:
  - `"Escrow: past"` if `startTime < now`.
  - `"Escrow: not sorted"` if `startTime` is not strictly greater than the last scheduled change.
- Standard ERC-20 failures:
  - `safeTransferFrom` / `safeTransfer` revert if balances/allowances are insufficient.

---

## 6. Events

- `FarmUpdated(address indexed farm)`
- `Funded(address indexed from, uint256 amount)`
- `Dripped(uint256 accruedBefore, uint256 sent, uint256 accruedAfter, uint64 at)`
- `RateScheduled(uint64 startTime, uint192 ratePerSec)`
- `RateApplied(uint64 at, uint192 ratePerSec)`
- `MaxDripPerTxUpdated(uint256 newMax)`
- `FarmPullEnabledUpdated(bool enabled)`

---

## 7. Tests Map

- **INV-RDE-01:** ordering & no past schedule  
  `test/dripper/RewardDripperEscrow.spec.js::INV-RDE-01`

- **INV-RDE-02/03:** accrual over multiple segments, monotonicity  
  `test/dripper/RewardDripperEscrow.spec.js::INV-RDE-02/03`

- **INV-RDE-04:** `setRatePerSec` / `setWeeklyAmount` apply accrual first  
  `test/dripper/RewardDripperEscrow.spec.js::INV-RDE-04`

- **INV-RDE-05:** `drip` respects `maxDripPerTx` and actual token balance  
  `test/dripper/RewardDripperEscrow.spec.js::INV-RDE-05`

- **INV-RDE-06:** non-reentrancy  
  `test/dripper/RewardDripperEscrow.spec.js::INV-RDE-06`

- **INV-RDE-07:** pull-model allowances  
  `test/dripper/RewardDripperEscrow.spec.js::INV-RDE-07`

- **INV-RDE-08/09:** `clearSchedule`, zero guards, rescue  
  `test/dripper/RewardDripperEscrow.spec.js::INV-RDE-08/09`
