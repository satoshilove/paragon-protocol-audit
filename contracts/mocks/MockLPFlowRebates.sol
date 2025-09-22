// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

contract MockLPFlowRebates {
    uint256 public count;
    address public notifier;

    function setNotifier(address _notifier) external {
        notifier = _notifier;
    }

    function notify(address tokenIn, address tokenOut, address rewardToken, uint256 amount) external {
        require(msg.sender == notifier, "only notifier");
        count++;
    }
}