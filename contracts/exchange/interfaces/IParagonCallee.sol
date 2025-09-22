// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

/**
 * @title IParagonCallee
 * @dev Interface for Paragon flash loan callbacks
 */
interface IParagonCallee {
    function paragonCall(address sender, uint256 amount0, uint256 amount1, bytes calldata data) external;
}