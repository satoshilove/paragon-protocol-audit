// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

contract RewardDripperEscrow is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    struct RateChange {
        uint64  startTime;     // when this rate becomes active (unix)
        uint192 ratePerSec;    // tokens per second, 18-decimals assumed
    }

    IERC20  public immutable rewardToken;     // XPGN
    address public farm;                      // ParagonFarmController
    uint64  public lastAccrue;                // last timestamp we updated accruals
    uint192 public currentRatePerSec;         // active streaming rate
    uint256 public accrued;                   // claimable (not yet dripped)

    RateChange[] public schedule;             // upcoming rate changes (sorted ascending)

    // New: Cap per-tx outflow
    uint256 public maxDripPerTx = type(uint256).max;

    // New: Optional pull-model toggle
    bool public farmPullEnabled;

    event FarmUpdated(address indexed farm);
    event Funded(address indexed from, uint256 amount);
    event Dripped(uint256 accruedBefore, uint256 sent, uint256 accruedAfter, uint64 at);
    event RateScheduled(uint64 startTime, uint192 ratePerSec);
    event RateApplied(uint64 at, uint192 ratePerSec);
    // New events
    event MaxDripPerTxUpdated(uint256 newMax);
    event FarmPullEnabledUpdated(bool enabled);

    constructor(
        address owner_,
        IERC20 token_,
        address farm_,
        uint64 startTime_,
        uint192 ratePerSec_
    ) Ownable(owner_) {
        require(address(token_) != address(0) && farm_ != address(0), "Escrow: zero");
        rewardToken = token_;
        farm        = farm_;
        lastAccrue  = startTime_ > 0 ? startTime_ : uint64(block.timestamp);
        currentRatePerSec = ratePerSec_;
        emit FarmUpdated(farm_);
        emit RateApplied(lastAccrue, ratePerSec_);
    }

    // ---- Admin ----
    function setFarm(address newFarm) external onlyOwner {
        require(newFarm != address(0), "Escrow: zero farm");
        if (farmPullEnabled) {
            rewardToken.forceApprove(farm, 0); // Revoke old
            rewardToken.forceApprove(newFarm, type(uint256).max); // Approve new
        }
        farm = newFarm;
        emit FarmUpdated(newFarm);
    }

    /// @notice Add a future rate change (becomes active at startTime). Must be >= now and strictly increasing.
    function scheduleRate(uint64 startTime, uint192 ratePerSec) external onlyOwner {
        require(startTime >= block.timestamp, "Escrow: past");
        if (schedule.length > 0) {
            require(startTime > schedule[schedule.length - 1].startTime, "Escrow: not sorted");
        }
        schedule.push(RateChange({ startTime: startTime, ratePerSec: ratePerSec }));
        emit RateScheduled(startTime, ratePerSec);
    }

    /// @notice New: Add a future rate change starting after a delay (relative to now).
    function scheduleRateAfter(uint64 delaySeconds, uint192 ratePerSec) external onlyOwner {
        uint64 startTime = uint64(block.timestamp) + delaySeconds;
        require(startTime >= block.timestamp, "Escrow: past"); // Overflow safety
        if (schedule.length > 0) {
            require(startTime > schedule[schedule.length - 1].startTime, "Escrow: not sorted");
        }
        schedule.push(RateChange({ startTime: startTime, ratePerSec: ratePerSec }));
        emit RateScheduled(startTime, ratePerSec);
    }

    /// @notice New: Clear all scheduled rate changes.
    function clearSchedule() external onlyOwner {
        delete schedule;
    }

    /// @notice Owner funds the escrow (XPGN must be approved)
    function fund(uint256 amount) external onlyOwner {
        rewardToken.safeTransferFrom(msg.sender, address(this), amount);
        emit Funded(msg.sender, amount);
    }

    /// @notice New: Directly set the rate per second (immediate).
    function setRatePerSec(uint192 ratePerSec) external onlyOwner {
        _applyAccrual();
        currentRatePerSec = ratePerSec;
        emit RateApplied(uint64(block.timestamp), ratePerSec);
    }

    /// @notice Helper: set a weekly drip amount (tokens/week) -> internal per-second rate.
    function setWeeklyAmount(uint256 tokensPerWeek) external onlyOwner {
        _applyAccrual(); // finalize to current time before changing rate
        // 604800 = 7 * 24 * 3600
        uint192 rps = uint192((tokensPerWeek + 604799) / 604800); // Ceiling division to avoid truncation
        currentRatePerSec = rps;
        emit RateApplied(uint64(block.timestamp), rps);
    }

    /// @notice New: Set the max drip per transaction.
    function setMaxDripPerTx(uint256 newMax) external onlyOwner {
        require(newMax > 0, "Escrow: zero max");
        maxDripPerTx = newMax;
        emit MaxDripPerTxUpdated(newMax);
    }

    /// @notice New: Toggle pull-model for farm (approves max allowance if enabled).
    function setFarmPullEnabled(bool enabled) external onlyOwner {
        farmPullEnabled = enabled;
        if (enabled) {
            rewardToken.forceApprove(farm, type(uint256).max);
        } else {
            rewardToken.forceApprove(farm, 0);
        }
        emit FarmPullEnabledUpdated(enabled);
    }

    // ---- Public: top-up Farm ----
    function drip() external nonReentrant returns (uint256 sent) {
        _applyAccrual();
        uint256 bal = rewardToken.balanceOf(address(this));
        uint256 toSend = accrued <= bal ? accrued : bal;
        toSend = toSend <= maxDripPerTx ? toSend : maxDripPerTx;
        if (toSend > 0) {
            accrued -= toSend;
            rewardToken.safeTransfer(farm, toSend);
        }
        emit Dripped(accrued + toSend, toSend, accrued, uint64(block.timestamp));
        return toSend;
    }

    // ---- Views ----
    function pendingAccrued() external view returns (uint256) {
        (uint256 addl,,) = _previewAccrual();
        return accrued + addl;
    }

    function scheduleCount() external view returns (uint256) {
        return schedule.length;
    }

    // ---- Internals ----
    function _applyAccrual() internal {
        (uint256 addl, uint64 newLast, uint192 newRate) = _previewAccrual();
        if (addl > 0) accrued += addl;
        lastAccrue = newLast;
        if (newRate != currentRatePerSec) {
            currentRatePerSec = newRate;
            emit RateApplied(newLast, newRate);
        }
    }

    function _previewAccrual() internal view returns (uint256 addl, uint64 newLast, uint192 newRate) {
        uint64 t0 = lastAccrue == 0 ? uint64(block.timestamp) : lastAccrue;
        uint64 t  = uint64(block.timestamp);
        uint192 r = currentRatePerSec;

        addl = 0;
        uint256 i = 0;
        // Walk through any scheduled rate changes that have started
        while (i < schedule.length && schedule[i].startTime <= t) {
            uint64 cut = schedule[i].startTime;
            if (cut > t0 && r > 0) {
                addl += uint256(r) * (cut - t0);
            }
            r = schedule[i].ratePerSec;
            t0 = cut;
            unchecked { ++i; }
        }
        if (t > t0 && r > 0) {
            addl += uint256(r) * (t - t0);
        }
        newLast = t;
        newRate = r;
    }

    // ---- Safety ----
    function rescue(address token, address to) external onlyOwner {
        require(to != address(0), "Escrow: zero to");
        IERC20 erc20 = IERC20(token);
        erc20.safeTransfer(to, erc20.balanceOf(address(this)));
    }
}