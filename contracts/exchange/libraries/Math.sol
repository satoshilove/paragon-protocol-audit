// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

/**
 * @title Math
 * @dev A library for mathematical operations used in Paragon protocol
 */
library Math {
    // Computes the square root of a number using the Babylonian method
    function sqrt(uint256 y) internal pure returns (uint256 z) {
        if (y > 3) {
            z = y;
            uint256 x = y / 2 + 1;
            while (x < z) {
                z = x;
                x = (y / x + x) / 2;
            }
        } else if (y != 0) {
            z = 1;
        }
    }

    // Returns the minimum of two numbers
    function min(uint256 x, uint256 y) internal pure returns (uint256) {
        return x <= y ? x : y;
    }
}