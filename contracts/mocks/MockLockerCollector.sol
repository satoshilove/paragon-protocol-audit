// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

contract MockLockerCollector {
    event Locked(address indexed user, address indexed token, uint256 amount);
    function onLock(address user, address token, uint256 amount) external {
        emit Locked(user, token, amount);
    }
}
