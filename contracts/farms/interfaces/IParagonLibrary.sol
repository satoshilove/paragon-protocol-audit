// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import "../../exchange/interfaces/IParagonFactory.sol";
import "../../exchange/interfaces/IParagonPair.sol";

/**
 * @title ParagonLibrary
 * @dev Library for swap and liquidity calculations in Paragon protocol
 */
library ParagonLibrary {
    // Returns sorted token addresses, used to handle return values from pairs sorted in this order
    function sortTokens(address tokenA, address tokenB) internal pure returns (address token0, address token1) {
        require(tokenA != tokenB, "ParagonLibrary: IDENTICAL_ADDRESSES");
        (token0, token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        require(token0 != address(0), "ParagonLibrary: ZERO_ADDRESS");
    }

    // Calculates the CREATE2 address for a pair without making any external calls
    function pairFor(address factory, address tokenA, address tokenB) internal view returns (address pair) {
        (address token0, address token1) = sortTokens(tokenA, tokenB);
        pair = address(uint160(uint256(keccak256(abi.encodePacked(
            hex'ff',
            factory,
            keccak256(abi.encodePacked(token0, token1)),
            IParagonFactory(factory).INIT_CODE_PAIR_HASH()
        )))));
    }

    // Fetches and sorts the reserves for a pair
    function getReserves(address factory, address tokenA, address tokenB) internal view returns (uint256 reserveA, uint256 reserveB) {
        (address token0,) = sortTokens(tokenA, tokenB);
        (uint112 reserve0, uint112 reserve1,) = IParagonPair(pairFor(factory, tokenA, tokenB)).getReserves();
        (reserveA, reserveB) = tokenA == token0 ? (reserve0, reserve1) : (reserve1, reserve0);
    }

    // Given some amount of an asset and pair reserves, returns an equivalent amount of the other asset
    function quote(uint256 amountA, uint256 reserveA, uint256 reserveB) internal pure returns (uint256 amountB) {
        require(amountA > 0, "ParagonLibrary: INSUFFICIENT_AMOUNT");
        require(reserveA > 0 && reserveB > 0, "ParagonLibrary: INSUFFICIENT_LIQUIDITY");
        amountB = (amountA * reserveB) / reserveA;
    }

    // Given an input amount of an asset and pair reserves, returns the maximum output amount of the other asset
    function getAmountOut(uint256 amountIn, uint256 reserveIn, uint256 reserveOut, uint32 swapFeeBips) internal pure returns (uint256 amountOut) {
        require(amountIn > 0, "ParagonLibrary: INSUFFICIENT_INPUT_AMOUNT");
        require(reserveIn > 0 && reserveOut > 0, "ParagonLibrary: INSUFFICIENT_LIQUIDITY");
        uint256 amountInWithFee = amountIn * (10000 - swapFeeBips);
        uint256 numerator = amountInWithFee * reserveOut;
        uint256 denominator = (reserveIn * 10000) + amountInWithFee;
        amountOut = numerator / denominator;
    }

    // Given an output amount of an asset and pair reserves, returns a required input amount of the other asset
    function getAmountIn(uint256 amountOut, uint256 reserveIn, uint256 reserveOut, uint32 swapFeeBips) internal pure returns (uint256 amountIn) {
        require(amountOut > 0, "ParagonLibrary: INSUFFICIENT_OUTPUT_AMOUNT");
        require(reserveIn > 0 && reserveOut > 0, "ParagonLibrary: INSUFFICIENT_LIQUIDITY");
        uint256 numerator = reserveIn * amountOut * 10000;
        uint256 denominator = (reserveOut - amountOut) * (10000 - swapFeeBips);
        amountIn = (numerator / denominator) + 1;
    }

    // Performs chained getAmountOut calculations on any number of pairs
    function getAmountsOut(address factory, uint256 amountIn, address[] memory path) internal view returns (uint[] memory amounts) {
        require(path.length >= 2, "ParagonLibrary: INVALID_PATH");
        amounts = new uint[](path.length);
        amounts[0] = amountIn;
        uint32 swapFeeBips = IParagonFactory(factory).swapFeeBips();
        for (uint256 i = 0; i < path.length - 1; i++) {
            (uint256 reserveIn, uint256 reserveOut) = getReserves(factory, path[i], path[i + 1]);
            amounts[i + 1] = getAmountOut(amounts[i], reserveIn, reserveOut, swapFeeBips);
        }
    }

    // Performs chained getAmountIn calculations on any number of pairs
    function getAmountsIn(address factory, uint256 amountOut, address[] memory path) internal view returns (uint[] memory amounts) {
        require(path.length >= 2, "ParagonLibrary: INVALID_PATH");
        amounts = new uint[](path.length);
        amounts[amounts.length - 1] = amountOut;
        uint32 swapFeeBips = IParagonFactory(factory).swapFeeBips();
        for (uint256 i = path.length - 1; i > 0; i--) {
            (uint256 reserveIn, uint256 reserveOut) = getReserves(factory, path[i - 1], path[i]);
            amounts[i - 1] = getAmountIn(amounts[i], reserveIn, reserveOut, swapFeeBips);
        }
    }
}