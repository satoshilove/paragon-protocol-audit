// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {IVoterEscrowMinimal} from "./interfaces/IVoterEscrowMinimal.sol";

/// @notice Weekly ERC20 fee distributor for ve-style voting escrow.
///         FIX: sample both total supply and user balances at END-OF-WEEK (weekTs + WEEK - 1)
///         and only distribute for fully completed weeks.
contract FeeDistributorERC20 is Ownable, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;

    uint256 public constant WEEK = 7 days;

    IERC20 public immutable reward;   // XPGN (or any ERC20)
    IVoterEscrowMinimal public immutable ve;

    // epoch (rounded week start) => amount funded for that epoch
    mapping(uint256 => uint256) public epochRewards;

    // epoch (rounded week start) => ve total supply snapshot @ end-of-week (week + WEEK - 1)
    mapping(uint256 => uint256) public epochSupply;

    // user => last claimed epoch (rounded week start)
    mapping(address => uint256) public userLastClaim;

    event Notified(uint256 indexed weekTs, uint256 amount, uint256 veSupply);
    event Claimed(address indexed user, uint256 amount, uint256 fromWeek, uint256 toWeek);

    constructor(address _reward, address _ve, address initialOwner) Ownable(initialOwner) {
        require(_reward != address(0) && _ve != address(0), "0");
        reward = IERC20(_reward);
        ve = IVoterEscrowMinimal(_ve);
    }

    /// @notice Fund current epoch. Snapshots ve total supply at END-OF-WEEK to match claim-side sampling.
    function notifyRewardAmount(uint256 amount) external nonReentrant whenNotPaused {
        require(amount > 0, "amount=0");

        uint256 weekTs = _roundDownWeek(block.timestamp);

        // pull funds first
        reward.safeTransferFrom(msg.sender, address(this), amount);

        // FIX: sample at end-of-week so numerator/denominator use the same timestamp
        uint256 snapTs = weekTs + WEEK - 1;
        uint256 supply = ve.totalSupplyAtTime(snapTs);

        epochSupply[weekTs] = supply;
        epochRewards[weekTs] += amount;

        emit Notified(weekTs, amount, supply);
    }

    /// @notice Claim rewards accrued for fully completed weeks.
    function claim(address user) external nonReentrant whenNotPaused returns (uint256) {
        require(user != address(0), "user=0");

        (uint256 fromWeek, uint256 toWeek) = claimWindow(user);
        if (fromWeek == 0 || fromWeek > toWeek) return 0;

        uint256 total;
        for (uint256 w = fromWeek; w <= toWeek; w += WEEK) {
            uint256 amt = epochRewards[w];
            if (amt == 0) continue;

            uint256 supply = epochSupply[w];
            if (supply == 0) continue;

            // FIX: sample user at end-of-week to match supply snapshot
            uint256 bal = ve.balanceOfAtTime(user, w + WEEK - 1);
            if (bal == 0) continue;

            total += (amt * bal) / supply;
        }

        // advance cursor before external transfer
        userLastClaim[user] = toWeek;

        if (total > 0) {
            reward.safeTransfer(user, total);
        }

        emit Claimed(user, total, fromWeek, toWeek);
        return total;
    }

    /// @notice Returns the inclusive [fromWeek, toWeek] of fully completed epochs to pay.
    ///         FIX: exclude the current (still-open) week; default to last 12 completed weeks on first claim.
    function claimWindow(address user) public view returns (uint256 fromWeek, uint256 toWeek) {
        uint256 last = userLastClaim[user];

        // last fully-completed week (current week's start minus one week)
        uint256 end = _roundDownWeek(block.timestamp);
        end = end >= WEEK ? end - WEEK : 0;

        if (end == 0) return (0, 0); // nothing completed yet

        uint256 start;
        if (last == 0) {
            // default window: last 12 completed weeks, with underflow guard
            start = end >= WEEK * 12 ? end - WEEK * 12 : 0;
        } else {
            start = last + WEEK;
        }

        if (start > end) return (0, 0);
        return (start, end);
    }

    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }

    function _roundDownWeek(uint256 t) internal pure returns (uint256) {
        return (t / WEEK) * WEEK;
    }
}
