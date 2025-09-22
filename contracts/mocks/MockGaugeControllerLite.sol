// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IGaugeControllerLite {
    function n_gauges() external view returns (uint256);
    function gaugesAt(uint256 i) external view returns (address);
    function totalWeight() external view returns (uint256);
    function gaugeWeight(address gauge) external view returns (uint256);
}

contract MockGaugeControllerLite is IGaugeControllerLite {
    address[] public gauges;
    mapping(address => uint256) public weight;
    uint256 public tot;

    function addGauge(address g, uint256 w) external {
        gauges.push(g);
        weight[g] = w;
        tot += w;
    }

    function n_gauges() external view returns (uint256) { return gauges.length; }
    function gaugesAt(uint256 i) external view returns (address) { return gauges[i]; }
    function gaugeWeight(address g) external view returns (uint256) { return weight[g]; }
    function totalWeight() external view returns (uint256) { return tot; }
}
