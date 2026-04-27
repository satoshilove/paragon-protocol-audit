// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.25;

contract MockFarmNotify {
    uint256 public lastPid;
    uint256 public lastAmount;

    function notifyGaugeReward(uint256 pid, uint256 amount) external {
        lastPid = pid;
        lastAmount = amount;
    }
}
