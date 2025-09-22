// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

contract MockVeBalance {
    mapping(address => uint256) public bal;

    function setBalance(address a, uint256 v) external { bal[a] = v; }
    function balanceOf(address a) external view returns (uint256) { return bal[a]; }
}
