// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @dev Minimal interface to enforce PAD-23 token match (farm must expose rewardToken()).
interface IFarmRewardToken {
    function rewardToken() external view returns (address);
}

/**
 * @title RewardDripperEscrow (Hardened / CertiK-ready)
 * @notice Streams rewards to a configured farm using internal accrual accounting.
 *
 * Fixes / Protections:
 *  - PAD-13: Pull-model removed entirely (no allowances; only drip()).
 *  - PAD-14: Preserves future startTime (no rewinding lastAccrue when now < lastAccrue).
 *  - PAD-19: scheduleIndex cursor prevents unbounded iteration over historical entries.
 *  - PAD-23: Enforces farm.rewardToken() == escrow.rewardToken (constructor + setFarm).
 *  - PAD-25: Monotonic accrual; never re-accrues already-accounted intervals.
 *
 * Additional hardening (recommended):
 *  - Optional dripCooldownSecs + minDripAmount to avoid spam/dust drips.
 *  - Safer rescue: rewardToken rescue limited to "excess" above (accrued + pendingAddl).
 *  - Scheduling guard: scheduled startTime must be >= max(now, lastAccrue, lastScheduled).
 */
contract RewardDripperEscrow is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    struct RateChange {
        uint64  startTime;   // when this rate becomes active (unix)
        uint192 ratePerSec;  // tokens per second (token decimals-native)
    }

    IERC20  public immutable rewardToken;
    address public farm;

    // Accrual state
    uint64  public lastAccrue;        // last timestamp we updated accruals (can be future start)
    uint192 public currentRatePerSec; // active streaming rate
    uint256 public accrued;           // claimable (not yet dripped)

    // Schedule state (sorted ascending by startTime)
    RateChange[] public schedule;
    uint256 public scheduleIndex;     // cursor into schedule (PAD-19)

    // Rate limiting layers
    uint256 public maxDripPerTx = type(uint256).max; // hard cap per drip
    uint256 public minDripAmount = 0;                // ignore dust drips if >0
    uint64  public dripCooldownSecs = 0;             // optional cooldown
    uint64  public lastDripAt = 0;

    event FarmUpdated(address indexed farm);
    event Funded(address indexed from, uint256 amount);
    event Dripped(uint256 accruedBefore, uint256 sent, uint256 accruedAfter, uint64 at);
    event RateScheduled(uint64 startTime, uint192 ratePerSec);
    event RateApplied(uint64 at, uint192 ratePerSec);
    event MaxDripPerTxUpdated(uint256 newMax);
    event MinDripAmountUpdated(uint256 newMin);
    event DripCooldownUpdated(uint64 newCooldown);
    event ScheduleCleared();
    event Rescued(address indexed token, address indexed to, uint256 amount);

    constructor(
        address owner_,
        IERC20 token_,
        address farm_,
        uint64 startTime_,
        uint192 ratePerSec_
    ) Ownable(owner_) {
        require(owner_ != address(0), "Escrow: zero owner");
        require(address(token_) != address(0), "Escrow: zero token");
        require(farm_ != address(0), "Escrow: zero farm");

        rewardToken = token_;
        _enforceFarmTokenMatch(farm_, address(token_)); // PAD-23
        farm = farm_;

        // Allow delayed activation by setting lastAccrue in the future
        uint64 nowTs = uint64(block.timestamp);
        lastAccrue = startTime_ > 0 ? startTime_ : nowTs;
        currentRatePerSec = ratePerSec_;

        emit FarmUpdated(farm_);
        emit RateApplied(lastAccrue, ratePerSec_);
    }

    // ───────────────────────────── Admin ─────────────────────────────

    function setFarm(address newFarm) external onlyOwner {
        require(newFarm != address(0), "Escrow: zero farm");
        _enforceFarmTokenMatch(newFarm, address(rewardToken)); // PAD-23
        farm = newFarm;
        emit FarmUpdated(newFarm);
    }

    /// @notice Add a future rate change.
    /// @dev Must be >= now, >= lastAccrue, and strictly increasing vs last scheduled.
    function scheduleRate(uint64 startTime, uint192 ratePerSec) external onlyOwner {
        uint64 nowTs = uint64(block.timestamp);
        require(startTime >= nowTs, "Escrow: past");
        // Prevent weirdness / backward application: don't schedule earlier than lastAccrue.
        // (If you want an immediate change, use setRatePerSec / setWeeklyAmount)
        require(startTime >= lastAccrue, "Escrow: < lastAccrue");

        uint256 len = schedule.length;
        if (len > 0) {
            require(startTime > schedule[len - 1].startTime, "Escrow: not sorted");
        }
        schedule.push(RateChange({ startTime: startTime, ratePerSec: ratePerSec }));
        emit RateScheduled(startTime, ratePerSec);
    }

    function scheduleRateAfter(uint64 delaySeconds, uint192 ratePerSec) external onlyOwner {
        uint64 startTime = uint64(block.timestamp) + delaySeconds;
        require(startTime >= uint64(block.timestamp), "Escrow: overflow");
        require(startTime >= lastAccrue, "Escrow: < lastAccrue");

        uint256 len = schedule.length;
        if (len > 0) {
            require(startTime > schedule[len - 1].startTime, "Escrow: not sorted");
        }
        schedule.push(RateChange({ startTime: startTime, ratePerSec: ratePerSec }));
        emit RateScheduled(startTime, ratePerSec);
    }

    /// @notice Clears all scheduled rate changes.
    function clearSchedule() external onlyOwner {
        delete schedule;
        scheduleIndex = 0;
        emit ScheduleCleared();
    }

    /// @notice Owner funds the escrow (rewardToken must be approved).
    function fund(uint256 amount) external onlyOwner {
        rewardToken.safeTransferFrom(msg.sender, address(this), amount);
        emit Funded(msg.sender, amount);
    }

    /// @notice Set rate per second immediately (applies accrual up to now first).
    function setRatePerSec(uint192 ratePerSec) external onlyOwner {
        _applyAccrual();
        currentRatePerSec = ratePerSec;
        emit RateApplied(uint64(block.timestamp), ratePerSec);
    }

    /// @notice Helper: set weekly drip amount (tokens/week) -> per-second rate (ceiling division).
    function setWeeklyAmount(uint256 tokensPerWeek) external onlyOwner {
        _applyAccrual();
        uint192 rps = uint192((tokensPerWeek + 604799) / 604800);
        currentRatePerSec = rps;
        emit RateApplied(uint64(block.timestamp), rps);
    }

    function setMaxDripPerTx(uint256 newMax) external onlyOwner {
        require(newMax > 0, "Escrow: zero max");
        maxDripPerTx = newMax;
        emit MaxDripPerTxUpdated(newMax);
    }

    function setMinDripAmount(uint256 newMin) external onlyOwner {
        minDripAmount = newMin;
        emit MinDripAmountUpdated(newMin);
    }

    function setDripCooldown(uint64 newCooldownSecs) external onlyOwner {
        dripCooldownSecs = newCooldownSecs;
        emit DripCooldownUpdated(newCooldownSecs);
    }

    // ───────────────────────────── Public: drip ─────────────────────────────

    /// @notice Sends accrued rewards to farm, capped by maxDripPerTx, escrow balance, and optional cooldown/dust.
    /// @dev All outflows go through accounting (PAD-13).
    function drip() external nonReentrant returns (uint256 sent) {
        _applyAccrual();

        if (dripCooldownSecs != 0) {
            require(uint64(block.timestamp) >= lastDripAt + dripCooldownSecs, "Escrow: cooldown");
        }

        uint256 bal = rewardToken.balanceOf(address(this));
        uint256 toSend = accrued <= bal ? accrued : bal;
        if (toSend > maxDripPerTx) toSend = maxDripPerTx;

        if (minDripAmount != 0 && toSend < minDripAmount) {
            // Do not send dust; keep accrued for later.
            emit Dripped(accrued, 0, accrued, uint64(block.timestamp));
            return 0;
        }

        if (toSend > 0) {
            accrued -= toSend;
            rewardToken.safeTransfer(farm, toSend);
            lastDripAt = uint64(block.timestamp);
        }

        emit Dripped(accrued + toSend, toSend, accrued, uint64(block.timestamp));
        return toSend;
    }

    // ───────────────────────────── Views ─────────────────────────────

    function pendingAccrued() external view returns (uint256) {
        (uint256 addl,,,) = _previewAccrualWithIndex();
        return accrued + addl;
    }

    function scheduleCount() external view returns (uint256) {
        return schedule.length;
    }

    /// @notice Tokens that are "excess" (not needed to cover already-accrued + pending accrual).
    function excessRewardToken() public view returns (uint256) {
        (uint256 addl,,,) = _previewAccrualWithIndex();
        uint256 reserved = accrued + addl;
        uint256 bal = rewardToken.balanceOf(address(this));
        return bal > reserved ? (bal - reserved) : 0;
    }

    // ───────────────────────────── Internals ─────────────────────────────

    function _applyAccrual() internal {
        (uint256 addl, uint64 newLast, uint192 newRate, uint256 newIndex) = _previewAccrualWithIndex();

        if (addl > 0) accrued += addl;

        // PAD-14: If called before startTime, newLast == lastAccrue (no rewind)
        lastAccrue = newLast;

        // PAD-19: advance cursor so old schedule entries aren't re-walked forever
        scheduleIndex = newIndex;

        if (newRate != currentRatePerSec) {
            currentRatePerSec = newRate;
            emit RateApplied(newLast, newRate);
        }
    }

    function _previewAccrualWithIndex()
        internal
        view
        returns (uint256 addl, uint64 newLast, uint192 newRate, uint256 newIndex)
    {
        uint64 t0 = lastAccrue;
        uint64 t  = uint64(block.timestamp);
        uint192 r = currentRatePerSec;

        addl = 0;
        newRate = r;

        // PAD-14: before future start time -> no changes
        if (t <= t0) {
            return (0, t0, r, scheduleIndex);
        }

        uint256 i = scheduleIndex;
        uint256 len = schedule.length;

        // Walk only from scheduleIndex forward (PAD-19)
        while (i < len && schedule[i].startTime <= t) {
            uint64 cut = schedule[i].startTime;

            // PAD-25: never move t0 backwards; only accrue forward slices
            if (cut > t0) {
                if (r > 0) addl += uint256(r) * (cut - t0);
                t0 = cut;
            }

            // Apply the rate at this cut (even if cut <= t0, still safe; cursor moves forward)
            r = schedule[i].ratePerSec;

            unchecked { ++i; }
        }

        // Accrue from t0 to now
        if (t > t0 && r > 0) {
            addl += uint256(r) * (t - t0);
        }

        return (addl, t, r, i);
    }

    function _enforceFarmTokenMatch(address farm_, address token_) internal view {
        require(IFarmRewardToken(farm_).rewardToken() == token_, "Escrow: farm token mismatch");
    }

    // ───────────────────────────── Safety ─────────────────────────────

    /// @notice Rescue tokens accidentally sent here.
    /// @dev For rewardToken, only "excess" above reserved (accrued + pending) is withdrawable.
    function rescue(address token, address to, uint256 amount) external onlyOwner {
        require(to != address(0), "Escrow: zero to");
        require(amount > 0, "Escrow: zero amount");

        if (token == address(rewardToken)) {
            uint256 ex = excessRewardToken();
            require(amount <= ex, "Escrow: exceeds excess");
        }

        IERC20(token).safeTransfer(to, amount);
        emit Rescued(token, to, amount);
    }
}
