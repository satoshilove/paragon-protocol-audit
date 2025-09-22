// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

contract MockFarmNotifier {
    event Notified(uint256 indexed pid, uint256 amount);
    mapping(uint256 => uint256) public notified;

    // Primary signature some emitters call
    function notifyRewardAmount(uint256 pid, uint256 amount) external returns (bool) {
        notified[pid] += amount;
        emit Notified(pid, amount);
        return true;
    }

    // Alternate signature used by other emitters
    function notifyRewardAmount(uint256 pid, address /*rewardToken*/, uint256 amount)
        external
        returns (bool)
    {
        notified[pid] += amount;
        emit Notified(pid, amount);
        return true;
    }
}
