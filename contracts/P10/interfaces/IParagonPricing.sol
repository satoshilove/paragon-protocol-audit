// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

interface IParagonRouter {
    /// @notice Swap exact tokens in for minAmountOut of a target token.
    /// Replace with your real router function (Flow / Shield entrypoint).
    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 minAmountOut,
        address[] calldata path,
        address to
    ) external returns (uint256 amountOut);
}

interface IParagonPricing {
    /// @notice Returns USD price (1e18) and lastUpdated timestamp for a token.
    function getPriceUSD(address token)
        external
        view
        returns (uint256 priceE18, uint256 lastUpdated);
}
