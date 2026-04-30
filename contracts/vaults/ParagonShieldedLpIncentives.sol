// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.25;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IVoterEscrowLocking} from "../dao/interfaces/IVoterEscrowLocking.sol";

interface IShieldedLpVaultView {
    function activePositionsCount(address user) external view returns (uint256);
    function activePrincipal(address user) external view returns (uint256);
    function positionsLength(address user) external view returns (uint256);
    function positions(address user, uint256 idx)
        external
        view
        returns (uint256 amount, uint64 unlockTime, uint16 tier, uint16 penaltyBips, uint256 rewardDebt, uint256 shares);
}

contract ParagonShieldedLpIncentives is Ownable, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 public constant WEEK = 7 days;

    IERC20 public immutable rewardToken;
    IVoterEscrowLocking public immutable ve;
    IShieldedLpVaultView public immutable vault;

    bool public immutable useSolidlyOrder;

    mapping(uint256 => uint256) public epochBudget;
    mapping(uint256 => uint256) public epochFinalBudget;
    mapping(uint256 => bool) public epochFinalized;
    mapping(uint256 => uint256) public epochFinalTotalPoints;
    mapping(uint256 => uint16) public epochFinalMaxUserShareBips;
    mapping(uint256 => uint256) public epochFinalClaimWindowEpochs;
    mapping(uint256 => mapping(address => uint256)) public epochUserPoints;
    mapping(uint256 => uint256) public epochTotalPoints;
    mapping(uint256 => mapping(address => bool)) public claimed;

    mapping(address => bool) public rewardNotifiers;
    mapping(bytes32 => bool) public processedRefs;

    uint256 public minLockWeeks = 16;
    uint256 public maxLockWeeks = 104;
    uint256 public maxPointsPerRecord = 1_000_000e18;
    uint256 public maxPointsPerUserPerEpoch = 10_000_000e18;
    uint256 public claimWindowEpochs = 26;
    uint256 public unfinalizedRecoveryEpochs = 8;
    uint256 public minEligibleStake = 1e18;
    uint16 public gasKickbackBips = 0;
    uint16 public maxUserShareBips = 3000;
    mapping(uint256 => uint256) public epochClaimedAmount;
    mapping(uint256 => uint256) public epochRecoveredAmount;

    event RewardNotifierSet(address indexed notifier, bool allowed);
    event EligibilityConfigSet(uint256 minEligibleStake);
    event LockConfigSet(
        uint256 minWeeks,
        uint256 maxWeeks,
        uint16 gasKickbackBips,
        uint256 maxPointsPerRecord,
        uint256 maxPointsPerUserPerEpoch,
        uint16 maxUserShareBips,
        uint256 claimWindowEpochs,
        uint256 unfinalizedRecoveryEpochs
    );
    event UsefulLiquidityRecorded(
        uint256 indexed epoch,
        address indexed user,
        uint256 points,
        bytes32 indexed ref
    );
    event BonusBudgetNotified(uint256 indexed epoch, uint256 amount, address indexed from);
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
    event EmergencyWithdraw(address indexed token, address indexed to, uint256 amount);
    event EpochBudgetRecovered(uint256 indexed epoch, uint256 amount, address indexed to);

    modifier onlyNotifierOrOwner() {
        require(msg.sender == owner() || rewardNotifiers[msg.sender], "not notifier");
        _;
    }

    constructor(
        address initialOwner,
        address rewardToken_,
        address vault_,
        address ve_,
        bool useSolidlyOrder_
    ) Ownable(initialOwner) {
        require(rewardToken_ != address(0) && vault_ != address(0) && ve_ != address(0), "zero addr");
        rewardToken = IERC20(rewardToken_);
        vault = IShieldedLpVaultView(vault_);
        ve = IVoterEscrowLocking(ve_);
        useSolidlyOrder = useSolidlyOrder_;

        (bool ok, bytes memory data) = ve_.staticcall(abi.encodeWithSignature("token()"));
        require(ok && data.length >= 32 && abi.decode(data, (address)) == rewardToken_, "ve token mismatch");
    }

    function currentEpoch() public view returns (uint256) {
        return block.timestamp / WEEK;
    }

    function setRewardNotifier(address notifier, bool allowed) external onlyOwner {
        require(notifier != address(0), "notifier=0");
        rewardNotifiers[notifier] = allowed;
        emit RewardNotifierSet(notifier, allowed);
    }

    function setEligibilityConfig(uint256 minEligibleStake_) external onlyOwner {
        require(minEligibleStake_ > 0, "min stake=0");
        minEligibleStake = minEligibleStake_;
        emit EligibilityConfigSet(minEligibleStake_);
    }

    function setLockConfig(
        uint256 minWeeks_,
        uint256 maxWeeks_,
        uint16 gasKickbackBips_,
        uint256 maxPointsPerRecord_,
        uint256 maxPointsPerUserPerEpoch_,
        uint16 maxUserShareBips_,
        uint256 claimWindowEpochs_,
        uint256 unfinalizedRecoveryEpochs_
    ) external onlyOwner {
        require(minWeeks_ >= 4 && maxWeeks_ >= minWeeks_ && maxWeeks_ <= 207, "bad weeks");
        require(gasKickbackBips_ <= 1000, "kickback>10%");
        require(maxPointsPerRecord_ > 0, "record cap=0");
        require(maxPointsPerUserPerEpoch_ >= maxPointsPerRecord_, "user cap<record");
        require(maxUserShareBips_ > 0 && maxUserShareBips_ <= 10_000, "bad share cap");
        require(claimWindowEpochs_ > 0 && claimWindowEpochs_ <= 104, "bad claim window");
        require(unfinalizedRecoveryEpochs_ >= 4 && unfinalizedRecoveryEpochs_ <= 104, "bad recovery window");
        minLockWeeks = minWeeks_;
        maxLockWeeks = maxWeeks_;
        gasKickbackBips = gasKickbackBips_;
        maxPointsPerRecord = maxPointsPerRecord_;
        maxPointsPerUserPerEpoch = maxPointsPerUserPerEpoch_;
        maxUserShareBips = maxUserShareBips_;
        claimWindowEpochs = claimWindowEpochs_;
        unfinalizedRecoveryEpochs = unfinalizedRecoveryEpochs_;
        emit LockConfigSet(
            minWeeks_,
            maxWeeks_,
            gasKickbackBips_,
            maxPointsPerRecord_,
            maxPointsPerUserPerEpoch_,
            maxUserShareBips_,
            claimWindowEpochs_,
            unfinalizedRecoveryEpochs_
        );
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    function notifyRewardAmount(uint256 epoch, uint256 amount) external nonReentrant onlyNotifierOrOwner whenNotPaused {
        require(amount > 0, "amount=0");
        require(!epochFinalized[epoch], "epoch finalized");
        require(epoch >= currentEpoch(), "past epoch");
        require(epoch <= currentEpoch() + 8, "epoch too far");

        uint256 balBefore = rewardToken.balanceOf(address(this));
        rewardToken.safeTransferFrom(msg.sender, address(this), amount);
        uint256 received = rewardToken.balanceOf(address(this)) - balBefore;

        require(received > 0, "received=0");

        epochBudget[epoch] += received;
        emit BonusBudgetNotified(epoch, received, msg.sender);
    }

    function recordUsefulLiquidity(
        address user,
        uint256 points,
        bytes32 ref
    ) external onlyNotifierOrOwner whenNotPaused {
        _recordUsefulLiquidity(user, points, ref);
    }

    function batchRecordUsefulLiquidity(
        address[] calldata users,
        uint256[] calldata pointsList,
        bytes32[] calldata refs
    ) external onlyNotifierOrOwner whenNotPaused {
        uint256 len = users.length;
        require(len == pointsList.length && len == refs.length, "length mismatch");
        for (uint256 i = 0; i < len; ++i) {
            if (!_hasActiveStake(users[i])) continue;
            _recordUsefulLiquidity(users[i], pointsList[i], refs[i]);
        }
    }

    function finalizeEpoch(uint256 epoch) public onlyNotifierOrOwner whenNotPaused {
        require(epoch < currentEpoch(), "epoch not closed");
        require(!epochFinalized[epoch], "already finalized");

        uint256 totalPoints = epochTotalPoints[epoch];
        uint256 budget = epochBudget[epoch];

        epochFinalized[epoch] = true;
        epochFinalTotalPoints[epoch] = totalPoints;
        epochFinalBudget[epoch] = budget;
        epochFinalMaxUserShareBips[epoch] = maxUserShareBips;
        epochFinalClaimWindowEpochs[epoch] = claimWindowEpochs;

        emit EpochFinalized(epoch, totalPoints, budget);
    }

    function claim(uint256 epoch) external nonReentrant whenNotPaused {
        _claimTo(epoch, msg.sender, msg.sender);
    }

    function claimable(address user, uint256 epoch) external view returns (uint256) {
        if (!epochFinalized[epoch] || claimed[epoch][user]) return 0;
        if (currentEpoch() > epoch + epochFinalClaimWindowEpochs[epoch]) return 0;
        uint256 pts = epochUserPoints[epoch][user];
        uint256 totalPts = epochFinalTotalPoints[epoch];
        uint256 budget = epochFinalBudget[epoch];
        if (pts == 0 || totalPts == 0 || budget == 0) return 0;
        return _cappedShare(epoch, budget, pts, totalPts);
    }

    function hasActiveStake(address user) external view returns (bool) {
        return _hasActiveStake(user);
    }

    function rescue(address token, address to, uint256 amount) external onlyOwner {
        require(to != address(0), "to=0");
        require(token != address(rewardToken), "protected");
        IERC20(token).safeTransfer(to, amount);
        emit EmergencyWithdraw(token, to, amount);
    }

    function recoverEpochBudget(uint256 epoch, address to) external onlyOwner {
        require(to != address(0), "to=0");

        uint256 recoverable;
        if (epochFinalized[epoch]) {
            require(currentEpoch() > epoch + epochFinalClaimWindowEpochs[epoch], "claim window open");
            recoverable = epochFinalBudget[epoch] - epochClaimedAmount[epoch] - epochRecoveredAmount[epoch];
        } else {
            require(epoch + unfinalizedRecoveryEpochs < currentEpoch(), "recovery window open");
            recoverable = epochBudget[epoch] - epochRecoveredAmount[epoch];
        }

        require(recoverable > 0, "nothing recoverable");
        epochRecoveredAmount[epoch] += recoverable;
        rewardToken.safeTransfer(to, recoverable);
        emit EpochBudgetRecovered(epoch, recoverable, to);
    }

    function _recordUsefulLiquidity(address user, uint256 points, bytes32 ref) internal {
        require(user != address(0), "user=0");
        require(points > 0, "points=0");
        require(points <= maxPointsPerRecord, "points too high");
        require(ref != bytes32(0), "ref=0");
        require(!processedRefs[ref], "ref used");
        require(_hasActiveStake(user), "no active stake");

        uint256 epoch = currentEpoch();
        require(!epochFinalized[epoch], "epoch finalized");
        require(epochUserPoints[epoch][user] + points <= maxPointsPerUserPerEpoch, "user points too high");

        processedRefs[ref] = true;
        epochUserPoints[epoch][user] += points;
        epochTotalPoints[epoch] += points;

        emit UsefulLiquidityRecorded(epoch, user, points, ref);
    }

    function _claimTo(uint256 epoch, address account, address receiver) internal {
        require(msg.sender == account, "only self claim");
        require(!claimed[epoch][account], "already claimed");
        require(epochFinalized[epoch], "epoch not finalized");
        require(currentEpoch() <= epoch + epochFinalClaimWindowEpochs[epoch], "claim window closed");

        uint256 pts = epochUserPoints[epoch][account];
        uint256 totalPts = epochFinalTotalPoints[epoch];
        require(pts > 0 && totalPts > 0, "no points");

        uint256 budget = epochFinalBudget[epoch];
        require(budget > 0, "no budget");

        uint256 share = _cappedShare(epoch, budget, pts, totalPts);
        require(share > 0, "dust");

        claimed[epoch][account] = true;
        epochClaimedAmount[epoch] += share;

        uint256 kick = (share * gasKickbackBips) / 10_000;
        uint256 lockAmt = share - kick;

        if (kick > 0) {
            rewardToken.safeTransfer(receiver, kick);
        }

        uint256 tokenId;
        uint256 unlockTime;

        (bool ok, uint256 existingAmount, uint256 existingEnd) = _readLock(receiver);
        require(ok, "lock read failed");

        rewardToken.forceApprove(address(ve), 0);
        rewardToken.forceApprove(address(ve), lockAmt);

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
            if (existingEnd < targetMin) {
                ve.increase_unlock_time_for(receiver, targetMin);
                unlockTime = targetMin;
            } else {
                unlockTime = existingEnd;
            }

            _increaseAmountFor(receiver, lockAmt);

            emit ExistingLockToppedUp(receiver, lockAmt, unlockTime);
        }

        rewardToken.forceApprove(address(ve), 0);

        emit Claimed(epoch, receiver, share, lockAmt, unlockTime, tokenId);
    }

    function _hasActiveStake(address user) internal view returns (bool) {
        if (vault.activePrincipal(user) < minEligibleStake) return false;

        uint256 len = vault.positionsLength(user);
        for (uint256 i = 0; i < len; ++i) {
            (uint256 amount, uint64 unlockTime,,,,) = vault.positions(user, i);
            if (amount > 0 && unlockTime > block.timestamp) return true;
        }
        return false;
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

    function _cappedShare(uint256 epoch, uint256 budget, uint256 pts, uint256 totalPts) internal view returns (uint256) {
        uint256 rawShare = (budget * pts) / totalPts;
        uint256 maxShare = (budget * epochFinalMaxUserShareBips[epoch]) / 10_000;
        return rawShare < maxShare ? rawShare : maxShare;
    }

    function _ceilToWeek(uint256 t) internal pure returns (uint256) {
        return ((t + WEEK - 1) / WEEK) * WEEK;
    }
}
