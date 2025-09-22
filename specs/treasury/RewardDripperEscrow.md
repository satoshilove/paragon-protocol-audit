# RewardDripperEscrow — SPEC

**Intent:** Hold XPGN rewards and stream them to `farm` at a configurable **tokens/second** rate, with a future **rate schedule**, optional **pull model** (farm has allowance), and a **max drip per tx** cap.

## State
- `rewardToken: IERC20` (immutable) — XPGN reward token.
- `farm: address` — recipient (ParagonFarmController).
- `lastAccrue: uint64` — last timestamp accruals were applied.
- `currentRatePerSec: uint192` — active streaming rate (18-decimals assumed).
- `accrued: uint256` — claimable (yet to be transferred) amount.
- `schedule: RateChange[]` — future `{startTime, ratePerSec}` changes, **strictly increasing** by `startTime`.
- `maxDripPerTx: uint256` — per-transaction send cap (default `type(uint256).max`).
- `farmPullEnabled: bool` — if **true**, escrow approves `farm` for `rewardToken` max allowance; otherwise zero allowance.

## API
- **Admin (onlyOwner)**
  - `setFarm(address newFarm)` — updates recipient; if `farmPullEnabled`, revokes old and grants max allowance to new.
  - `scheduleRate(uint64 startTime, uint192 ratePerSec)` — enqueue future rate; `startTime ≥ now` and `>` last scheduled.
  - `scheduleRateAfter(uint64 delaySeconds, uint192 ratePerSec)` — convenience wrapper for `now + delay`.
  - `clearSchedule()` — delete all pending changes.
  - `fund(uint256 amount)` — pull XPGN from owner into escrow.
  - `setRatePerSec(uint192 ratePerSec)` — **immediate** rate change (applies accrual to now first).
  - `setWeeklyAmount(uint256 tokensPerWeek)` — sets `currentRatePerSec` using ceil(`tokensPerWeek/604800`); accrues first.
  - `setMaxDripPerTx(uint256 newMax)` — must be `> 0`.
  - `setFarmPullEnabled(bool enabled)` — toggles pull model; sets allowance accordingly.
  - `rescue(address token, address to)` — transfer full token balance to `to` (non-zero).
- **Public**
  - `drip() → uint256 sent` — accrues to now, then sends `min(accrued, balance, maxDripPerTx)` to `farm`.
  - **Views:** `pendingAccrued()`, `scheduleCount()`.

## Accrual Model
At any time `t`, additional accrual since `lastAccrue` equals the integral of `ratePerSec` across schedule segments that began `≤ t`.  
- `_previewAccrual()` walks scheduled changes with `startTime ≤ t` to compute `(addl, newLast=t, newRate)`.  
- `_applyAccrual()` adds `addl` into `accrued`, sets `lastAccrue = t`, updates `currentRatePerSec = newRate` and emits `RateApplied` if changed.

## Invariants
- **INV-RDE-01 (Schedule ordering):** Each `RateChange.startTime` is `≥ now` when scheduled and **strictly greater** than the previous item.
- **INV-RDE-02 (Accrual correctness):** `pendingAccrued() == accrued + ∑(rate_i * Δt_i)` for all schedule segments with `startTime ≤ now`.
- **INV-RDE-03 (Monotone accrued):** `accrued` never decreases except when `drip()` reduces it by the **sent** amount.
- **INV-RDE-04 (Immediate rate changes):** `setRatePerSec` and `setWeeklyAmount` **apply accrual to now** before changing the active rate.
- **INV-RDE-05 (Drip bounds):** `sent = min(accrued, rewardToken.balanceOf(this), maxDripPerTx)`; after send, `accrued' = accrued − sent`.
- **INV-RDE-06 (Non-reentrant drip):** `drip()` is `nonReentrant`.
- **INV-RDE-07 (Pull-model safety):** When `farmPullEnabled` toggles, allowance for old `farm` is set to **0** and new `farm` to **max**; `rewardToken` address never changes.
- **INV-RDE-08 (Schedule clear):** `clearSchedule()` does not modify `accrued` or `currentRatePerSec`; only removes **future** changes.
- **INV-RDE-09 (Zero guards):** Constructor, `setFarm`, and `rescue(to)` forbid zero addresses; `setMaxDripPerTx` requires `newMax > 0`.

## Failure Modes
- `Escrow: zero` / `Escrow: zero farm` / `Escrow: zero to` — zero address guards.
- `Escrow: past` — scheduling at a past time.
- `Escrow: not sorted` — non-increasing `startTime`.
- Reverts from `safeTransferFrom/transfer` if balances/allowances insufficient.

## Events
- `FarmUpdated(farm)`
- `Funded(from, amount)`
- `Dripped(accruedBefore, sent, accruedAfter, at)`
- `RateScheduled(startTime, ratePerSec)`
- `RateApplied(at, ratePerSec)`
- `MaxDripPerTxUpdated(newMax)`
- `FarmPullEnabledUpdated(enabled)`

## Tests Map
- **INV-RDE-01:** `test/Dripper.t.sol::testScheduleOrderingAndNoPast()`
- **INV-RDE-02:** `test/Dripper.t.sol::testAccrualAcrossMultipleSegments()`
- **INV-RDE-03:** `test/Dripper.t.sol::testAccruedMonotoneExceptOnDrip()`
- **INV-RDE-04:** `test/Dripper.t.sol::testSetRateAndWeeklyApplyAccrualFirst()`
- **INV-RDE-05:** `test/Dripper.t.sol::testDripRespectsCapAndBalance()`
- **INV-RDE-06:** `test/Dripper.t.sol::testNonReentrantDrip()`
- **INV-RDE-07:** `test/Dripper.t.sol::testPullModelAllowancesOnToggleAndSetFarm()`
- **INV-RDE-08:** `test/Dripper.t.sol::testClearScheduleNoStateChange()`
- **INV-RDE-09:** `test/Dripper.t.sol::testZeroGuardsAndRescue()`
