// contracts/mocks/MockFactory.sol
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

contract MockFactory {
    mapping(address => mapping(address => address)) public pairs;

    function setPair(address a, address b, address p) external {
        pairs[a][b] = p;
        pairs[b][a] = p;
    }

    function getPair(address a, address b) external view returns (address) {
        return pairs[a][b];
    }
}