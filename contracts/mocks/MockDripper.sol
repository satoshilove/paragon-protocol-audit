// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

contract MockDripper is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    struct RateChange {
        uint64  startTime;     // when this rate becomes active
        uint192 ratePerSec;    // tokens/sec (assume 18d token)
    }

    uint256 public constant WEEK = 7 days;

    IERC20  public immutable rewardToken;
    address public farm;

    uint64  public lastAccrue;          // last timestamp accrual applied
    uint192 public currentRatePerSec;   // active streaming rate
    uint256 public accrued;             // claimable (not yet sent)

    RateChange[] public schedule;       // strictly increasing by startTime

    uint256 public maxDripPerTx = type(uint256).max;
    bool    public farmPullEnabled;

    event FarmUpdated(address farm);
    event Funded(address indexed from, uint256 amount);
    event Dripped(uint256 accruedBefore, uint256 sent, uint256 accruedAfter, uint256 at);
    event RateScheduled(uint64 startTime, uint192 ratePerSec);
    event RateApplied(uint256 at, uint192 ratePerSec);
    event MaxDripPerTxUpdated(uint256 newMax);
    event FarmPullEnabledUpdated(bool enabled);

    // ✅ Pass initial owner to OZ v5 Ownable
    constructor(address _token, address _farm, address _owner) Ownable(_owner) {
        if (_token == address(0)) revert("Escrow: zero");
        if (_farm  == address(0)) revert("Escrow: zero farm");
        rewardToken = IERC20(_token);
        farm = _farm;
        lastAccrue = uint64(block.timestamp);
    }

    // ───────────────────────── Admin ─────────────────────────

    function setFarm(address newFarm) external onlyOwner {
        if (newFarm == address(0)) revert("Escrow: zero farm");

        if (farmPullEnabled) {
            // ✅ OZ v5: use forceApprove
            rewardToken.forceApprove(farm, 0);
            rewardToken.forceApprove(newFarm, type(uint256).max);
        }

        farm = newFarm;
        emit FarmUpdated(newFarm);
    }

    function scheduleRate(uint64 startTime, uint192 ratePerSec) external onlyOwner {
        _schedulePush(startTime, ratePerSec);
    }

    function scheduleRateAfter(uint64 delaySeconds, uint192 ratePerSec) external onlyOwner {
        uint64 start = uint64(block.timestamp) + delaySeconds;
        _schedulePush(start, ratePerSec); // internal helper avoids external-call compile issue
    }

    function clearSchedule() external onlyOwner {
        delete schedule; // does NOT touch accrued or currentRatePerSec
    }

    function fund(uint256 amount) external onlyOwner {
        rewardToken.safeTransferFrom(msg.sender, address(this), amount);
        emit Funded(msg.sender, amount);
    }

    function setRatePerSec(uint192 ratePerSec) external onlyOwner {
        _applyAccrual(uint64(block.timestamp));
        currentRatePerSec = ratePerSec;
        emit RateApplied(block.timestamp, ratePerSec);
    }

    function setWeeklyAmount(uint256 tokensPerWeek) external onlyOwner {
        _applyAccrual(uint64(block.timestamp));
        // ceilDiv(tokensPerWeek, WEEK)
        uint256 r = (tokensPerWeek + WEEK - 1) / WEEK;
        if (r > type(uint192).max) r = type(uint192).max;
        currentRatePerSec = uint192(r);
        emit RateApplied(block.timestamp, currentRatePerSec);
    }

    function setMaxDripPerTx(uint256 newMax) external onlyOwner {
        if (newMax == 0) revert("Escrow: max=0");
        maxDripPerTx = newMax;
        emit MaxDripPerTxUpdated(newMax);
    }

    function setFarmPullEnabled(bool enabled) external onlyOwner {
        if (enabled == farmPullEnabled) {
            emit FarmPullEnabledUpdated(enabled);
            return;
        }
        farmPullEnabled = enabled;
        // ✅ OZ v5: use forceApprove to set/reset allowance
        if (enabled) {
            rewardToken.forceApprove(farm, type(uint256).max);
        } else {
            rewardToken.forceApprove(farm, 0);
        }
        emit FarmPullEnabledUpdated(enabled);
    }

    function rescue(address token, address to) external onlyOwner {
        if (to == address(0)) revert("Escrow: zero to");
        uint256 bal = IERC20(token).balanceOf(address(this));
        IERC20(token).safeTransfer(to, bal);
    }

    // ───────────────────────── Public ─────────────────────────

    function drip() external nonReentrant returns (uint256 sent) {
        _applyAccrual(uint64(block.timestamp));

        uint256 bal = rewardToken.balanceOf(address(this));
        uint256 amt = accrued;
        if (amt > bal) amt = bal;
        if (amt > maxDripPerTx) amt = maxDripPerTx;

        uint256 before = accrued;
        if (amt > 0) {
            accrued = before - amt;
            rewardToken.safeTransfer(farm, amt);
        }
        emit Dripped(before, amt, accrued, block.timestamp);
        return amt;
    }

    // Views
    function pendingAccrued() external view returns (uint256) {
        (uint256 addl,,) = _previewAccrual(uint64(block.timestamp));
        return accrued + addl;
    }

    function scheduleCount() external view returns (uint256) {
        return schedule.length;
    }

    // ─────────────────────── Internals ───────────────────────

    function _schedulePush(uint64 startTime, uint192 ratePerSec) internal {
        if (startTime < block.timestamp) revert("Escrow: past");
        uint256 n = schedule.length;
        if (n > 0 && startTime <= schedule[n - 1].startTime) revert("Escrow: not sorted");
        schedule.push(RateChange({startTime: startTime, ratePerSec: ratePerSec}));
        emit RateScheduled(startTime, ratePerSec);
    }

    function _applyAccrual(uint64 toTs) internal {
        (uint256 addl, uint64 newLast, uint192 newRate) = _previewAccrual(toTs);
        if (addl > 0) accrued += addl;
        if (newRate != currentRatePerSec) {
            currentRatePerSec = newRate;
            emit RateApplied(newLast, newRate);
        }
        lastAccrue = newLast;
    }

    function _previewAccrual(uint64 toTs)
        internal
        view
        returns (uint256 addl, uint64 newLast, uint192 newRate)
    {
        uint64 from = lastAccrue;
        uint192 rate = currentRatePerSec;
        addl = 0;

        uint256 n = schedule.length;
        for (uint256 i = 0; i < n; ++i) {
            RateChange memory rc = schedule[i];
            if (rc.startTime <= from) { rate = rc.ratePerSec; continue; }
            if (rc.startTime > toTs) break;
            addl += uint256(rate) * (rc.startTime - from);
            rate = rc.ratePerSec;
            from = rc.startTime;
        }
        if (toTs > from) addl += uint256(rate) * (toTs - from);
        return (addl, toTs, rate);
    }
}
