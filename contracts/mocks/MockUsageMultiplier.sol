// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.25;

contract MockUsageMultiplier {
    mapping(address => uint256) public customMultiplier;

    function setMultiplier(address user, uint256 bps) external {
        customMultiplier[user] = bps;
    }

    function multiplierBps(address user) external view returns (uint256) {
        uint256 m = customMultiplier[user];
        return m == 0 ? 10_000 : m;
    }

    function applyDecay(address) external {}
}
