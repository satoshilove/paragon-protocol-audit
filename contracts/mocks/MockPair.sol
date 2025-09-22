// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

interface IParagonPair {
    function token0() external view returns (address);
    function token1() external view returns (address);
    function getReserves() external view returns (uint112, uint112, uint32);
}

// test/mocks/MockPair.sol
contract MockPair is IParagonPair {
    address public immutable _t0;
    address public immutable _t1;
    uint112 public r0;
    uint112 public r1;

    constructor(address t0, address t1) {
        _t0 = t0; _t1 = t1;
    }

    function setReserves(uint112 _r0, uint112 _r1) external {
        r0 = _r0; r1 = _r1;
    }

    function token0() external view returns (address) { return _t0; }
    function token1() external view returns (address) { return _t1; }
    function getReserves() external view returns (uint112, uint112, uint32) { return (r0, r1, 0); }
}
