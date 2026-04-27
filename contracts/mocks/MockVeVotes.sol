// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.25;

contract MockVeVotes {
    mapping(address => uint256) public balanceOf;

    function setBalance(address user, uint256 amount) external {
        balanceOf[user] = amount;
    }
}
