// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

interface IBoostManager {
    function getBoost(address user, uint256 pid) external view returns (uint256);
}
