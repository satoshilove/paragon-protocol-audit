// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IVoterEscrowMinimal} from "./interfaces/IVoterEscrowMinimal.sol";

/// @title FeeDistributorERC20
/// @notice Distributes weekly ERC20 rewards to ve holders using finalized end-of-week snapshots.
contract FeeDistributorERC20 is Ownable, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 public constant WEEK = 7 days;
    uint256 public constant MAX_CLAIM_WEEKS = 52;

    IERC20 public immutable reward;
    IVoterEscrowMinimal public immutable ve;

    mapping(uint256 => uint256) public epochRewards;
    mapping(uint256 => uint256) public epochSupply;
    mapping(uint256 => bool) public epochFinalized;
    mapping(address => uint256) public userLastClaim;

    event RewardNotified(uint256 indexed weekTs, uint256 amount, address indexed from);
    event EpochFinalized(uint256 indexed weekTs, uint256 veSupply);
    event Claimed(address indexed user, uint256 amount, uint256 fromWeek, uint256 toWeek);

    constructor(address _reward, address _ve, address initialOwner) Ownable(initialOwner) {
        require(_reward != address(0) && _ve != address(0), "0");
        reward = IERC20(_reward);
        ve = IVoterEscrowMinimal(_ve);
    }

    function notifyRewardAmount(uint256 amount) external whenNotPaused nonReentrant {
        require(amount > 0, "amount=0");
        uint256 weekTs = _roundDownWeek(block.timestamp);

        reward.safeTransferFrom(msg.sender, address(this), amount);
        epochRewards[weekTs] += amount;

        emit RewardNotified(weekTs, amount, msg.sender);
    }

    function finalizeEpoch(uint256 weekTs) public whenNotPaused {
        require(weekTs < _roundDownWeek(block.timestamp), "week not closed");
        require(!epochFinalized[weekTs], "already finalized");

        uint256 snapTs = weekTs + WEEK - 1;
        uint256 supply = ve.totalSupplyAtTime(snapTs);

        epochSupply[weekTs] = supply;
        epochFinalized[weekTs] = true;

        emit EpochFinalized(weekTs, supply);
    }

    function batchFinalize(uint256[] calldata weekList) external whenNotPaused {
        for (uint256 i = 0; i < weekList.length; ++i) {
            if (!epochFinalized[weekList[i]]) {
                finalizeEpoch(weekList[i]);
            }
        }
    }

    function claim(address user) external whenNotPaused nonReentrant returns (uint256) {
        require(user != address(0), "user=0");

        (uint256 fromWeek, uint256 toWeek) = claimWindow(user);
        if (fromWeek == 0 || fromWeek > toWeek) return 0;

        uint256 total;
        uint256 processed;
        uint256 lastProcessed = userLastClaim[user];

        for (
            uint256 w = fromWeek;
            w <= toWeek && processed < MAX_CLAIM_WEEKS;
            w += WEEK
        ) {
            if (!epochFinalized[w]) break;

            uint256 amt = epochRewards[w];
            uint256 supply = epochSupply[w];

            if (amt > 0 && supply > 0) {
                uint256 bal = ve.balanceOfAtTime(user, w + WEEK - 1);
                if (bal > 0) {
                    total += (amt * bal) / supply;
                }
            }

            lastProcessed = w;
            processed++;
        }

        if (lastProcessed == userLastClaim[user]) return 0;

        userLastClaim[user] = lastProcessed;

        if (total > 0) {
            reward.safeTransfer(user, total);
        }

        emit Claimed(user, total, fromWeek, lastProcessed);
        return total;
    }

    function claimWindow(address user) public view returns (uint256 fromWeek, uint256 toWeek) {
        uint256 last = userLastClaim[user];

        uint256 end = _roundDownWeek(block.timestamp);
        if (end < WEEK) return (0, 0);
        end -= WEEK; // last fully closed week

        if (last == 0) {
            uint256 lookback = 12 * WEEK;
            fromWeek = end >= lookback ? end - lookback : 0;
        } else {
            fromWeek = last + WEEK;
        }

        if (fromWeek > end) return (0, 0);
        return (fromWeek, end);
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    function _roundDownWeek(uint256 t) internal pure returns (uint256) {
        return (t / WEEK) * WEEK;
    }
}