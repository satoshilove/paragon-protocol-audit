// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

interface IUsagePointsView {
    function pointsOf(address user, uint256 epoch) external view returns (uint256);
    function totalOf(uint256 epoch) external view returns (uint256);
}

interface IVoterEscrowLike {
    // Preferred: create_lock_for(to, amount, unlock_time)
    function create_lock_for(address to, uint256 amount, uint256 unlock_time) external returns (uint256 tokenId);
    // Solidly order fallback: create_lock_for(amount, unlock_time, to)
    function create_lock_for(uint256 amount, uint256 unlock_time, address to) external returns (uint256 tokenId);
}

/// @title TraderRewardsLocker — turns weekly trade rewards into **auto-locked ve**
contract TraderRewardsLocker is Ownable, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    IERC20 public immutable XPGN;
    IUsagePointsView public immutable usage;
    IVoterEscrowLike public immutable ve;

    // Switch for signature order
    bool public immutable useSolidlyOrder;

    // epoch => funded amount
    mapping(uint256 => uint256) public epochBudget;
    // epoch => user => claimed?
    mapping(uint256 => mapping(address => bool)) public claimed;

    // Lock config
    uint256 public minLockWeeks = 52;     // 1 year default
    uint256 public maxLockWeeks = 208;    // 4 years cap (safety)
    uint16  public gasKickbackBips = 0;   // optional % paid to wallet (unlocked), default 0

    event BudgetNotified(uint256 indexed epoch, uint256 amount, address indexed from);
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
        usage = IUsagePointsView(_usagePoints);
        ve = IVoterEscrowLike(_ve);
        useSolidlyOrder = _useSolidlyOrder;
    }

    // --- Admin ---

    function setLockConfig(uint256 _minWeeks, uint256 _maxWeeks, uint16 _kickbackBips) external onlyOwner {
        require(_minWeeks >= 1 && _maxWeeks >= _minWeeks && _maxWeeks <= 208, "bad weeks");
        require(_kickbackBips <= 1000, "kickback>10%");
        minLockWeeks = _minWeeks;
        maxLockWeeks = _maxWeeks;
        gasKickbackBips = _kickbackBips;
        emit LockConfig(_minWeeks, _maxWeeks, _kickbackBips);
    }

    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }

    /// @notice Fund a specific epoch. Treasury must `approve` this contract beforehand.
    function notifyRewardAmount(uint256 epoch, uint256 amount) external whenNotPaused {
        require(amount > 0, "amount=0");
        XPGN.safeTransferFrom(msg.sender, address(this), amount);
        epochBudget[epoch] += amount;
        emit BudgetNotified(epoch, amount, msg.sender);
    }

    /// @notice Claim and auto-lock caller’s share for an epoch.
    function claim(uint256 epoch) external nonReentrant whenNotPaused {
        _claimTo(epoch, msg.sender, msg.sender);
    }

    /// @notice Relayed claim to a receiver (e.g., for sponsors).
    function claimFor(uint256 epoch, address account, address receiver) external nonReentrant whenNotPaused {
        require(account != address(0) && receiver != address(0), "zero");
        _claimTo(epoch, account, receiver);
    }

    // --- Internals ---

    function _claimTo(uint256 epoch, address account, address receiver) internal {
        require(!claimed[epoch][account], "already claimed");

        uint256 pts = usage.pointsOf(account, epoch);
        uint256 tot = usage.totalOf(epoch);
        require(pts > 0 && tot > 0, "no points");

        uint256 budget = epochBudget[epoch];
        require(budget > 0, "no budget");

        uint256 share = (budget * pts) / tot;
        require(share > 0, "dust");

        // Mark claimed BEFORE external calls
        claimed[epoch][account] = true;

        // Optional small kickback
        uint256 kick = (share * gasKickbackBips) / 10_000;
        uint256 lockAmt = share - kick;

        // Pay kickback
        if (kick > 0) {
            XPGN.safeTransfer(receiver, kick);
        }

        // Approve ve and create lock
        XPGN.forceApprove(address(ve), 0);
        XPGN.forceApprove(address(ve), lockAmt);

        // Align unlock to week boundary (ceil), clamp to max
        uint256 targetMin = block.timestamp + (minLockWeeks * 1 weeks);
        uint256 targetMax = block.timestamp + (maxLockWeeks * 1 weeks);

        uint256 unlockTime = _ceilToWeek(targetMin);
        uint256 maxUnlock = _ceilToWeek(targetMax);
        if (unlockTime > maxUnlock) unlockTime = maxUnlock;

        uint256 tokenId;
        if (useSolidlyOrder) {
            // ve.create_lock_for(uint256 amount, uint256 unlock_time, address to)
            tokenId = ve.create_lock_for(lockAmt, unlockTime, receiver);
        } else {
            // ve.create_lock_for(address to, uint256 amount, uint256 unlock_time)
            tokenId = ve.create_lock_for(receiver, lockAmt, unlockTime);
        }

        emit Claimed(epoch, receiver, share, lockAmt, unlockTime, tokenId);
    }

    // --- Safety ---

    function emergencyWithdraw(address token, address to, uint256 amount) external onlyOwner {
        require(to != address(0), "zero");
        IERC20(token).safeTransfer(to, amount);
        emit EmergencyWithdraw(token, to, amount);
    }

    // --- Utils ---

    function _ceilToWeek(uint256 t) internal pure returns (uint256) {
        uint256 WEEK = 1 weeks;
        return ((t + WEEK - 1) / WEEK) * WEEK;
    }
}
