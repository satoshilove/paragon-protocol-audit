// SPDX-License-Identifier: GPL-3.0-or-later
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

    // mutable before finalization
    mapping(uint256 => uint256) public epochBudget;

    // frozen at finalization
    mapping(uint256 => uint256) public epochFinalBudget;
    mapping(uint256 => bool) public epochFinalized;
    mapping(uint256 => uint256) public epochFinalTotalPoints;
    mapping(uint256 => mapping(address => bool)) public claimed;

    mapping(address => bool) public rewardNotifiers;

    uint256 public minLockWeeks = 52;
    uint256 public maxLockWeeks = 208;
    uint16 public gasKickbackBips = 0;

    event BudgetNotified(uint256 indexed epoch, uint256 amount, address indexed from);
    event EpochFinalized(uint256 indexed epoch, uint256 totalPoints, uint256 finalBudget);
    event Claimed(
        uint256 indexed epoch,
        address indexed user,
        uint256 share,
        uint256 lockedAmount,
        uint256 unlockTime,
        uint256 tokenId
    );
    event ExistingLockToppedUp(address indexed user, uint256 amountAdded, uint256 existingUnlockTime);
    event RewardNotifierSet(address indexed notifier, bool allowed);
    event LockConfig(uint256 minWeeks, uint256 maxWeeks, uint16 gasKickbackBips);
    event EmergencyWithdraw(address indexed token, address indexed to, uint256 amount);

    modifier onlyNotifierOrOwner() {
        require(msg.sender == owner() || rewardNotifiers[msg.sender], "not notifier");
        _;
    }

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

    function setRewardNotifier(address notifier, bool allowed) external onlyOwner {
        require(notifier != address(0), "notifier=0");
        rewardNotifiers[notifier] = allowed;
        emit RewardNotifierSet(notifier, allowed);
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

    /// @notice Fund trader rewards for a specific epoch before finalization.
    /// @dev Uses actual received delta and rejects funding once the epoch is finalized.
    function notifyRewardAmount(uint256 epoch, uint256 amount) external onlyNotifierOrOwner whenNotPaused {
        require(amount > 0, "amount=0");
        require(!epochFinalized[epoch], "epoch finalized");

        uint256 balBefore = XPGN.balanceOf(address(this));
        XPGN.safeTransferFrom(msg.sender, address(this), amount);
        uint256 received = XPGN.balanceOf(address(this)) - balBefore;

        require(received > 0, "received=0");

        epochBudget[epoch] += received;
        emit BudgetNotified(epoch, received, msg.sender);
    }

    /// @notice Finalize a closed epoch after funding is in place.
    /// @dev Restricted to owner/notifier so third parties cannot freeze an unfunded epoch.
    function finalizeEpoch(uint256 epoch) public onlyNotifierOrOwner whenNotPaused {
        require(epoch < usage.currentEpoch(), "epoch not closed");
        require(!epochFinalized[epoch], "already finalized");

        uint256 totalPts = usage.totalOf(epoch);
        uint256 budget = epochBudget[epoch];

        require(totalPts > 0, "no points");
        require(budget > 0, "no budget");

        epochFinalized[epoch] = true;
        epochFinalTotalPoints[epoch] = totalPts;
        epochFinalBudget[epoch] = budget;

        emit EpochFinalized(epoch, totalPts, budget);
    }

    function batchFinalize(uint256[] calldata epochs) external onlyNotifierOrOwner whenNotPaused {
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

        uint256 budget = epochFinalBudget[epoch];
        require(budget > 0, "no budget");

        uint256 share = (budget * pts) / tot;
        require(share > 0, "dust");

        claimed[epoch][account] = true;

        uint256 kick = (share * gasKickbackBips) / 10_000;
        uint256 lockAmt = share - kick;

        if (kick > 0) {
            XPGN.safeTransfer(receiver, kick);
        }

        uint256 tokenId;
        uint256 unlockTime;

        (bool ok, uint256 existingAmount, uint256 existingEnd) = _readLock(receiver);
        require(ok, "lock read failed");

        XPGN.forceApprove(address(ve), 0);
        XPGN.forceApprove(address(ve), lockAmt);

        uint256 targetMin = _ceilToWeek(block.timestamp + (minLockWeeks * WEEK));
        uint256 targetMax = _ceilToWeek(block.timestamp + (maxLockWeeks * WEEK));

        if (existingAmount == 0) {
            unlockTime = targetMin;
            if (unlockTime > targetMax) unlockTime = targetMax;

            if (useSolidlyOrder) {
                tokenId = ve.create_lock_for(lockAmt, unlockTime, receiver);
            } else {
                tokenId = ve.create_lock_for(receiver, lockAmt, unlockTime);
            }
        } else {
            require(existingEnd > block.timestamp, "expired lock exists; withdraw first");
            require(existingEnd >= targetMin, "existing lock too short");

            _increaseAmountFor(receiver, lockAmt);
            unlockTime = existingEnd;

            emit ExistingLockToppedUp(receiver, lockAmt, existingEnd);
        }

        XPGN.forceApprove(address(ve), 0);

        emit Claimed(epoch, receiver, share, lockAmt, unlockTime, tokenId);
    }

    function emergencyWithdraw(address token, address to, uint256 amount) external onlyOwner {
        require(to != address(0), "zero");
        IERC20(token).safeTransfer(to, amount);
        emit EmergencyWithdraw(token, to, amount);
    }

    function _readLock(address user) internal view returns (bool ok, uint256 amount, uint256 end) {
        (bool success, bytes memory data) =
            address(ve).staticcall(abi.encodeWithSignature("locked(address)", user));

        if (!success || data.length < 64) {
            return (false, 0, 0);
        }

        (int128 amt, uint256 lockEnd) = abi.decode(data, (int128, uint256));
        if (amt <= 0) {
            return (true, 0, lockEnd);
        }

        return (true, uint256(uint128(amt)), lockEnd);
    }

    function _increaseAmountFor(address user, uint256 amount) internal {
        (bool success,) =
            address(ve).call(abi.encodeWithSignature("increase_amount_for(address,uint256)", user, amount));
        require(success, "ve top-up failed");
    }

    function _ceilToWeek(uint256 t) internal pure returns (uint256) {
        return ((t + WEEK - 1) / WEEK) * WEEK;
    }
}
