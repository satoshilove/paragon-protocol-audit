// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;
interface AggregatorV3Interface {
    function latestRoundData() external view returns (uint80,int256,uint256,uint256,uint80);
    function decimals() external view returns (uint8);
}
contract MockAggregatorV3 is AggregatorV3Interface {
    uint8 public dec; int256 private _ans; uint80 private _rid; uint256 private _upd;
    constructor(uint8 _dec) { dec = _dec; }
    function set(int256 ans, uint80 rid, uint256 upd) external { _ans = ans; _rid = rid; _upd = upd; }
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) { return (_rid,_ans,0,_upd,_rid); }
    function decimals() external view returns (uint8) { return dec; }
}
