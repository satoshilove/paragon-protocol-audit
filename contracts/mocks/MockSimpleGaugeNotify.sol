// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract MockSimpleGaugeNotify {
    event Notified(uint256 amount);
    uint256 public totalNotified;
    IERC20 public immutable token;

    constructor(IERC20 _token){ token = _token; }

    // EmissionsMinter calls this after safeIncreaseAllowance
    function notifyRewardAmount(uint256 amt) external {
        // pull (like a typical Gauge does on notify)
        require(token.transferFrom(msg.sender, address(this), amt), "pull fail");
        totalNotified += amt;
        emit Notified(amt);
    }
}
