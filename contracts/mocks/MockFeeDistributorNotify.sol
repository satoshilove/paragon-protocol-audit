// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.25;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract MockFeeDistributorNotify {
    using SafeERC20 for IERC20;

    IERC20 public immutable reward;
    uint256 public lastAmount;

    constructor(address reward_) {
        reward = IERC20(reward_);
    }

    function notifyRewardAmount(uint256 amount) external {
        reward.safeTransferFrom(msg.sender, address(this), amount);
        lastAmount = amount;
    }
}
