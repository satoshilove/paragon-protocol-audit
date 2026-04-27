// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.25;

contract MockGaugeControllerFinal {
    uint256 public currentEpoch;
    address[] public gaugeList;
    mapping(uint256 => bool) public epochFinalized;
    mapping(uint256 => uint256) public totalWeightFinal;
    mapping(uint256 => mapping(address => uint256)) public gaugeWeightFinal;

    function setCurrentEpoch(uint256 ep) external {
        currentEpoch = ep;
    }

    function setEpochFinalized(uint256 ep, bool val) external {
        epochFinalized[ep] = val;
    }

    function setGaugeList(address[] calldata list) external {
        delete gaugeList;
        for (uint256 i = 0; i < list.length; ++i) {
            gaugeList.push(list[i]);
        }
    }

    function setGaugeWeight(uint256 ep, address gauge, uint256 w) external {
        gaugeWeightFinal[ep][gauge] = w;
    }

    function setTotalWeight(uint256 ep, uint256 w) external {
        totalWeightFinal[ep] = w;
    }

    function n_gauges() external view returns (uint256) {
        return gaugeList.length;
    }

    function gaugesAt(uint256 i) external view returns (address) {
        return gaugeList[i];
    }

    function epoch() external view returns (uint256) {
        return currentEpoch;
    }
}
