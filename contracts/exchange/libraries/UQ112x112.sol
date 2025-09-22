// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

/**
 * @title UQ112x112
 * @dev A library for handling binary fixed point numbers (https://en.wikipedia.org/wiki/Q_(number_format))
 * @notice Range: [0, 2**112 - 1], Resolution: 1 / 2**112
 */
library UQ112x112 {
    uint224 constant Q112 = 2**112;

    // Encode a uint112 as a UQ112x112
    function encode(uint112 y) internal pure returns (uint224 z) {
        z = uint224(y) * Q112; // never overflows
    }

    // Divide a UQ112x112 by a uint112, returning a UQ112x112
    function uqdiv(uint224 x, uint112 y) internal pure returns (uint224 z) {
        z = x / uint224(y);
    }
}