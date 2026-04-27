// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.25;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract MockTraderRewardsNotify {
    using SafeERC20 for IERC20;

    IERC20 public immutable XPGN;
    uint256 public lastEpoch;
    uint256 public lastAmount;

    constructor(address token_) {
        XPGN = IERC20(token_);
    }

    function notifyRewardAmount(uint256 epoch, uint256 amount) external {
        XPGN.safeTransferFrom(msg.sender, address(this), amount);
        lastEpoch = epoch;
        lastAmount = amount;
    }
}
