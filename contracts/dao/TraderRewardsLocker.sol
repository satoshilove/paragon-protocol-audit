// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IVoterEscrowLocking} from "./interfaces/IVoterEscrowLocking.sol";

interface IUsagePointsLockerView {
    function pointsOf(address user, uint256 epoch) external view returns (uint256);
    function totalOf(uint256 epoch) external view returns (uint256);
    function currentEpoch() external view returns (uint256);
}

contract TraderRewardsLocker is Ownable, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 public constant WEEK = 7 days;

    IERC20 public immutable XPGN;
    IUsagePointsLockerView public immutable usage;
    IVoterEscrowLocking public immutable ve;

    bool public immutable useSolidlyOrder;

    mapping(uint256 => uint256) public epochBudget;
    mapping(uint256 => bool) public epochFinalized;
    mapping(uint256 => uint256) public epochFinalTotalPoints;
    mapping(uint256 => mapping(address => bool)) public claimed;

    uint256 public minLockWeeks = 52;
    uint256 public maxLockWeeks = 208;
    uint16 public gasKickbackBips = 0;

    event BudgetNotified(uint256 indexed epoch, uint256 amount, address indexed from);
    event EpochFinalized(uint256 indexed epoch, uint256 totalPoints);
    event Claimed(
        uint256 indexed epoch,
        address indexed user,
        uint256 share,
        uint256 lockedAmount,
        uint256 unlockTime,
        uint256 tokenId
    );
    event LockConfig(uint256 minWeeks, uint256 maxWeeks, uint16 gasKickbackBips);
    event EmergencyWithdraw(address token, address to, uint256 amount);

    constructor(
        address _owner,
        address _xpgn,
        address _usagePoints,
        address _ve,
        bool _useSolidlyOrder
    ) Ownable(_owner) {
        require(_xpgn != address(0) && _usagePoints != address(0) && _ve != address(0), "zero addr");
        XPGN = IERC20(_xpgn);
        usage = IUsagePointsLockerView(_usagePoints);
        ve = IVoterEscrowLocking(_ve);
        useSolidlyOrder = _useSolidlyOrder;
    }

    function setLockConfig(uint256 _minWeeks, uint256 _maxWeeks, uint16 _kickbackBips) external onlyOwner {
        require(_minWeeks >= 1 && _maxWeeks >= _minWeeks && _maxWeeks <= 208, "bad weeks");
        require(_kickbackBips <= 1000, "kickback>10%");
        minLockWeeks = _minWeeks;
        maxLockWeeks = _maxWeeks;
        gasKickbackBips = _kickbackBips;
        emit LockConfig(_minWeeks, _maxWeeks, _kickbackBips);
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    function notifyRewardAmount(uint256 epoch, uint256 amount) external onlyOwner whenNotPaused {
        require(amount > 0, "amount=0");
        XPGN.safeTransferFrom(msg.sender, address(this), amount);
        epochBudget[epoch] += amount;
        emit BudgetNotified(epoch, amount, msg.sender);
    }

    /// @notice Finalize only after epoch closes.
    /// @dev Fixes early-claim / undercount exploit class flagged by audit.
    function finalizeEpoch(uint256 epoch) public whenNotPaused {
        require(epoch < usage.currentEpoch(), "epoch not closed");
        require(!epochFinalized[epoch], "already finalized");

        uint256 totalPts = usage.totalOf(epoch);
        epochFinalized[epoch] = true;
        epochFinalTotalPoints[epoch] = totalPts;

        emit EpochFinalized(epoch, totalPts);
    }

    function batchFinalize(uint256[] calldata epochs) external whenNotPaused {
        for (uint256 i = 0; i < epochs.length; ++i) {
            if (!epochFinalized[epochs[i]]) {
                finalizeEpoch(epochs[i]);
            }
        }
    }

    function claim(uint256 epoch) external nonReentrant whenNotPaused {
        _claimTo(epoch, msg.sender, msg.sender);
    }

    function _claimTo(uint256 epoch, address account, address receiver) internal {
        require(msg.sender == account, "only self claim");
        require(!claimed[epoch][account], "already claimed");
        require(epochFinalized[epoch], "epoch not finalized");

        uint256 pts = usage.pointsOf(account, epoch);
        uint256 tot = epochFinalTotalPoints[epoch];
        require(pts > 0 && tot > 0, "no points");

        uint256 budget = epochBudget[epoch];
        require(budget > 0, "no budget");

        uint256 share = (budget * pts) / tot;
        require(share > 0, "dust");

        claimed[epoch][account] = true;

        uint256 kick = (share * gasKickbackBips) / 10_000;
        uint256 lockAmt = share - kick;

        if (kick > 0) {
            XPGN.safeTransfer(receiver, kick);
        }

        XPGN.forceApprove(address(ve), 0);
        XPGN.forceApprove(address(ve), lockAmt);

        uint256 targetMin = block.timestamp + (minLockWeeks * WEEK);
        uint256 targetMax = block.timestamp + (maxLockWeeks * WEEK);

        uint256 unlockTime = _ceilToWeek(targetMin);
        uint256 maxUnlock = _ceilToWeek(targetMax);
        if (unlockTime > maxUnlock) unlockTime = maxUnlock;

        uint256 tokenId;
        if (useSolidlyOrder) {
            tokenId = ve.create_lock_for(lockAmt, unlockTime, receiver);
        } else {
            tokenId = ve.create_lock_for(receiver, lockAmt, unlockTime);
        }

        emit Claimed(epoch, receiver, share, lockAmt, unlockTime, tokenId);
    }

    function emergencyWithdraw(address token, address to, uint256 amount) external onlyOwner {
        require(to != address(0), "zero");
        IERC20(token).safeTransfer(to, amount);
        emit EmergencyWithdraw(token, to, amount);
    }

    function _ceilToWeek(uint256 t) internal pure returns (uint256) {
        return ((t + WEEK - 1) / WEEK) * WEEK;
    }
}