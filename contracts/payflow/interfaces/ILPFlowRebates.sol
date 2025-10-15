// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

interface ILPFlowRebates {
    /// @notice Notify the system to attribute `amount` of `rewardToken` to LP flow on a hop (tokenIn -> tokenOut).
    function notify(address tokenIn, address tokenOut, address rewardToken, uint256 amount) external;
}
