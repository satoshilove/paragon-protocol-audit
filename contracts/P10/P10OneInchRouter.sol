// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IP10Router} from "./interfaces/IP10Core.sol";
import {IParagon1inchAdapter, I1inchRouterV6} from "../your-existing-path/Paragon1inchAdapter.sol"; // reuse your adapter interface

contract P10OneInchRouter is IP10Router {
    using SafeERC20 for IERC20;

    IParagon1inchAdapter public immutable adapter;
    address public immutable payflowExecutor; // can be P10IndexManager itself or a dedicated address

    constructor(address _adapter, address _payflowExecutor) {
        adapter = IParagon1inchAdapter(_adapter);
        payflowExecutor = _payflowExecutor;
    }

    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to
    ) external override returns (uint256 amountOut) {
        require(path.length == 2, "P10: only 2-hop for now");
        address tokenIn = path[0];
        address tokenOut = path[1];

        IERC20(tokenIn).safeTransferFrom(msg.sender, address(adapter), amountIn);

        // Build minimal valid 1inch description (you can reuse the same strict desc logic you already have in the adapter)
        I1inchRouterV6.SwapDescription memory desc = I1inchRouterV6.SwapDescription({
            srcToken: IERC20(tokenIn),
            dstToken: IERC20(tokenOut),
            srcReceiver: payable(address(adapter)),
            dstReceiver: payable(address(adapter)),
            amount: amountIn,
            minReturnAmount: amountOutMin,
            flags: 0
        });

        // Call your existing adapter (it already has all the security checks, exact-in, approval cleanup, etc.)
        amountOut = adapter.execute(
            tokenIn,
            amountIn,
            tokenOut,
            amountOutMin,
            desc,
            "",                    // permitData (empty for simple swaps)
            "",                    // oneInchData (you pass real calldata from your backend 1inch /swap API)
            address(0)             // executor = 0 for direct router
        );

        // Adapter already sent output back to payflowExecutor → forward to final recipient
        IERC20(tokenOut).safeTransfer(to, amountOut);
    }
}