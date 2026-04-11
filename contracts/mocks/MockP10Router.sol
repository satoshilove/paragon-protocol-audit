// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IP10Router} from "../p10/interfaces/IP10Core.sol";

contract MockP10Router is IP10Router {
    using SafeERC20 for IERC20;

    uint256 public nextAmountOut;

    function setNextAmountOut(uint256 amountOut) external {
        nextAmountOut = amountOut;
    }

    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to
    ) external override returns (uint256 amountOut) {
        require(path.length == 2, "path");

        IERC20(path[0]).safeTransferFrom(msg.sender, address(this), amountIn);

        amountOut = nextAmountOut;
        require(amountOut >= amountOutMin, "slippage");
        IERC20(path[1]).safeTransfer(to, amountOut);
    }
}
