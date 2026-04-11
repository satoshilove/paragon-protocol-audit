// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

/**
 * @title IP10Router
 * @notice Adapter interface to your existing Paragon Router / Flow contracts.
 *
 * @dev
 * - You SHOULD NOT change your Router implementation.
 * - Instead, you can:
 *     (a) Make your router implement this interface directly, OR
 *     (b) Create a thin adapter that forwards to your router/Flow entrypoint.
 *
 * - The goal is: P10IndexManager only knows about THIS interface, not router internals.
 */
interface IP10Router {
    /**
     * @notice Swap exact `amountIn` of `tokenIn` into `tokenOut`, sending to `to`.
     * @param amountIn    Exact amount of tokenIn to spend.
     * @param amountOutMin Minimum acceptable amount of tokenOut (slippage guard).
     * @param path        Swap path, e.g. [tokenIn, ..., tokenOut].
     * @param to          Recipient of tokenOut (usually the P10 manager/vault).
     * @return amountOut  Actual amount of tokenOut received.
     *
     * @dev
     * - MUST revert on failure (no partial fills).
     * - Internally this can call your Flow / Shield / batch router.
     */
    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to
    ) external returns (uint256 amountOut);
}

/**
 * @title IP10Pricing
 * @notice Adapter to your existing Pricing & Oracles module.
 *
 * @dev
 * - This MUST implement the full safety stack:
 *     - Chainlink + Pyth/Redstone
 *     - Freshness limits
 *     - Deviation bounds
 *     - TWAP sanity
 * - If any risk check fails, `isSafe` MUST be false (P10 will revert mints).
 */
interface IP10Pricing {
    /**
     * @notice Get a safe USD price for `token` with all guards applied.
     * @param token Address of the asset.
     * @return priceE18   Price in USD, 1e18 scale (e.g. $1.23 => 1.23e18).
     * @return lastUpdated Last on-chain time this price was updated.
     * @return isSafe     True if all risk checks passed.
     */
    function getSafePriceUSD(address token)
        external
        view
        returns (uint256 priceE18, uint256 lastUpdated, bool isSafe);
}
