// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract MockRouter {
    uint256 public nextAmountOut; // settable
    bool public fotMode;          // if true, reduce received by 1%

    event Swapped(address tokenIn, address tokenOut, uint256 amtIn, uint256 amtOut);

    function setNextAmountOut(uint256 v) external { nextAmountOut = v; }
    function setFOT(bool v) external { fotMode = v; }

    // Implement all signatures to match the fanout calls
    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        uint256 amountIn,
        uint256 minOut,
        address[] calldata path,
        address to,
        uint256 deadline,
        uint8 autoYieldPercent
    ) external {
        require(path.length >= 2 && path.length <= 5, "path");
        address tokenIn = path[0];
        address tokenOut = path[path.length - 1];

        IERC20(tokenIn).transferFrom(msg.sender, address(this), amountIn);

        uint256 out = nextAmountOut;
        if (fotMode && out > 0) out = (out * 9900) / 10000;

        require(out >= minOut, "minOut");
        IERC20(tokenOut).transfer(to, out);

        emit Swapped(tokenIn, tokenOut, amountIn, out);
    }

    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline,
        uint8 autoYieldPercent
    ) external returns (uint[] memory amounts) {
        require(path.length >= 2 && path.length <= 5, "path");
        address tokenIn = path[0];
        address tokenOut = path[path.length - 1];

        IERC20(tokenIn).transferFrom(msg.sender, address(this), amountIn);

        uint256 out = nextAmountOut;

        require(out >= amountOutMin, "MockRouter: slippage");
        IERC20(tokenOut).transfer(to, out);

        amounts = new uint[](path.length);
        amounts[path.length - 1] = out;
    }

    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external returns (uint[] memory amounts) {
        require(path.length >= 2 && path.length <= 5, "path");
        address tokenIn = path[0];
        address tokenOut = path[path.length - 1];

        IERC20(tokenIn).transferFrom(msg.sender, address(this), amountIn);

        uint256 out = nextAmountOut;

        require(out >= amountOutMin, "MockRouter: slippage");
        IERC20(tokenOut).transfer(to, out);

        amounts = new uint[](path.length);
        amounts[path.length - 1] = out;
    }
}