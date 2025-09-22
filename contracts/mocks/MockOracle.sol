// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

interface IParagonOracle {
    function getAmountsOutUsingTwap(
        uint256 amountIn,
        address[] memory path,
        uint32 timeWindow
    ) external view returns (uint256[] memory);
}

/**
 * @dev Minimal oracle for tests:
 * - path must be length 2
 * - price1e18[token] is the price of 1 token in base units (1e18 = 1 base)
 * - returns [amountIn, amountIn * price(tokenIn)]
 */
contract MockOracle is IParagonOracle {
    // token => price in base token (1e18 = 1 base)
    mapping(address => uint256) public price1e18;

    function setPrice(address token, uint256 price) external {
        price1e18[token] = price;
    }

    function getAmountsOutUsingTwap(
        uint256 amountIn,
        address[] memory path,
        uint32 /* timeWindow */
    ) external view override returns (uint256[] memory) {
        require(path.length == 2, "path must be 2");
        uint256 p = price1e18[path[0]];
        require(p != 0, "no price");

        uint256[] memory result = new uint256[](2);
        result[0] = amountIn;
        result[1] = (amountIn * p) / 1e18;
        return result;
    }
}