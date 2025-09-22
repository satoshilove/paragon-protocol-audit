// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import "../interfaces/IParagonFactory.sol";
import "../interfaces/IParagonPair.sol";
import "../../XpgnToken/XPGNToken.sol";
/**
 * @title ParagonLibrary
 * @dev Pure/view helpers for Paragon swaps and liquidity math.
 * - Deterministic pair address using Factory’s INIT_CODE_PAIR_HASH
 * - Dynamic fee via Factory.swapFeeBips()
 * - Optional pause guard for XPGN pairs
 */
library ParagonLibrary {
    // ───────────────────────────── helpers ─────────────────────────────
    function sortTokens(address tokenA, address tokenB)
        internal
        pure
        returns (address token0, address token1)
    {
        require(tokenA != tokenB, "ParagonLibrary: IDENTICAL_ADDRESSES");
        (token0, token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        require(token0 != address(0), "ParagonLibrary: ZERO_ADDRESS");
    }

    /// @notice Deterministically computes the pair address using the factory’s INIT_CODE_PAIR_HASH
    function pairFor(address factory, address tokenA, address tokenB)
        internal
        view
        returns (address pair)
    {
        (address token0, address token1) = sortTokens(tokenA, tokenB);
        bytes32 initCodeHash = IParagonFactory(factory).INIT_CODE_PAIR_HASH();
        pair = address(uint160(uint256(keccak256(abi.encodePacked(
            hex"ff",
            factory,
            keccak256(abi.encodePacked(token0, token1)),
            initCodeHash
        )))));
    }

    /// @notice Returns reserves aligned to (tokenA, tokenB)
    function getReserves(address factory, address tokenA, address tokenB)
        internal
        view
        returns (uint112 reserveA, uint112 reserveB, uint32 blockTimestampLast)
    {
        // Optional token-specific pause guard via factory-configured XPGN
        address xpgn = IParagonFactory(factory).xpgnToken();
        if (xpgn != address(0) && (tokenA == xpgn || tokenB == xpgn)) {
            require(!XPGNToken(xpgn).paused(), "XPGN_TOKEN_PAUSED");
        }
        address pair = pairFor(factory, tokenA, tokenB);
        (uint112 r0, uint112 r1, uint32 ts) = IParagonPair(pair).getReserves();
        (address token0,) = sortTokens(tokenA, tokenB);
        (reserveA, reserveB) = tokenA == token0 ? (r0, r1) : (r1, r0);
        blockTimestampLast = ts;
    }

    // ───────────────────────────── math ─────────────────────────────
    function quote(uint256 amountA, uint256 reserveA, uint256 reserveB)
        internal
        pure
        returns (uint256 amountB)
    {
        require(amountA > 0, "ParagonLibrary: INSUFFICIENT_AMOUNT");
        require(reserveA > 0 && reserveB > 0, "ParagonLibrary: INSUFFICIENT_LIQUIDITY");
        amountB = (amountA * reserveB) / reserveA;
    }

    function getAmountOut(
        uint256 amountIn,
        uint256 reserveIn,
        uint256 reserveOut,
        uint32 swapFeeBips
    ) internal pure returns (uint256 amountOut) {
        require(amountIn > 0, "ParagonLibrary: INSUFFICIENT_INPUT_AMOUNT");
        require(reserveIn > 0 && reserveOut > 0, "ParagonLibrary: INSUFFICIENT_LIQUIDITY");
        uint256 amountInWithFee = amountIn * (10000 - swapFeeBips);
        uint256 numerator = amountInWithFee * reserveOut;
        uint256 denominator = reserveIn * 10000 + amountInWithFee;
        amountOut = numerator / denominator;
    }

    function getAmountIn(
        uint256 amountOut,
        uint256 reserveIn,
        uint256 reserveOut,
        uint32 swapFeeBips
    ) internal pure returns (uint256 amountIn) {
        require(amountOut > 0, "ParagonLibrary: INSUFFICIENT_OUTPUT_AMOUNT");
        require(reserveIn > 0 && reserveOut > 0, "ParagonLibrary: INSUFFICIENT_LIQUIDITY");
        uint256 numerator = reserveIn * amountOut * 10000;
        uint256 denominator = (reserveOut - amountOut) * (10000 - swapFeeBips);
        amountIn = (numerator / denominator) + 1; // round up
    }

    function getAmountsOut(address factory, uint256 amountIn, address[] memory path)
        internal
        view
        returns (uint256[] memory amounts)
    {
        require(path.length >= 2, "ParagonLibrary: INVALID_PATH");
        amounts = new uint256[](path.length);
        amounts[0] = amountIn;

        for (uint256 i = 0; i < path.length - 1; ++i) {
            (uint112 reserveIn, uint112 reserveOut,) = getReserves(factory, path[i], path[i + 1]);
            address pair = pairFor(factory, path[i], path[i + 1]);
            uint32 feeBips = IParagonFactory(factory).getEffectiveSwapFeeBips(pair);
            amounts[i + 1] = getAmountOut(amounts[i], reserveIn, reserveOut, feeBips);
        }
    }

    function getAmountsIn(address factory, uint256 amountOut, address[] memory path)
        internal
        view
        returns (uint256[] memory amounts)
    {
        require(path.length >= 2, "ParagonLibrary: INVALID_PATH");
        amounts = new uint256[](path.length);
        amounts[amounts.length - 1] = amountOut;

        for (uint256 i = path.length - 1; i > 0; --i) {
            (uint112 reserveIn, uint112 reserveOut,) = getReserves(factory, path[i - 1], path[i]);
            address pair = pairFor(factory, path[i - 1], path[i]);
            uint32 feeBips = IParagonFactory(factory).getEffectiveSwapFeeBips(pair);
            amounts[i - 1] = getAmountIn(amounts[i], reserveIn, reserveOut, feeBips);
        }
    }
}