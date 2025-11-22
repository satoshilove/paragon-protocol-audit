// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

// Note: SafeMath is not needed in Solidity ^0.8.0 due to built-in overflow protection
// This library is provided for compatibility but should generally not be used
// Consider removing this library and using native arithmetic operators instead

/**
 * @title SafeMath
 * @dev A library for performing overflow-safe math, courtesy of DappHub (https://github.com/dapphub/ds-math)
 * @notice WARNING: This library is deprecated in Solidity ^0.8.0 - use built-in overflow protection instead
 */
library SafeMath {
    function add(uint256 x, uint256 y) internal pure returns (uint256 z) {
        // In Solidity ^0.8.0, this is equivalent to: return x + y;
        z = x + y;
        require(z >= x, 'SafeMath: addition overflow');
    }

    function sub(uint256 x, uint256 y) internal pure returns (uint256 z) {
        // In Solidity ^0.8.0, this is equivalent to: return x - y;
        require(y <= x, 'SafeMath: subtraction underflow');
        z = x - y;
    }

    function mul(uint256 x, uint256 y) internal pure returns (uint256 z) {
        // In Solidity ^0.8.0, this is equivalent to: return x * y;
        if (x == 0) return 0;
        z = x * y;
        require(z / x == y, 'SafeMath: multiplication overflow');
    }

    function div(uint256 x, uint256 y) internal pure returns (uint256 z) {
        // In Solidity ^0.8.0, this is equivalent to: return x / y;
        require(y > 0, 'SafeMath: division by zero');
        z = x / y;
    }
}