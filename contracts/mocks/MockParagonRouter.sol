// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.27;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract MockParagonRouter {
    using SafeERC20 for IERC20;

    error ForcedRevert();

    enum Mode {
        GOOD,
        UNDER_DELIVER,
        WRONG_RECEIVER,
        REVERT_ALWAYS
    }

    Mode public mode;

    event SwapCalled(
        address indexed tokenIn,
        address indexed tokenOut,
        uint256 amountIn,
        uint256 amountOutMin,
        address to,
        uint256 deadline,
        bool feeOnTransferPath
    );

    function setMode(Mode m) external {
        mode = m;
    }

    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline,
        uint8 autoYieldPercent
    ) external returns (uint256 amountOut) {
        autoYieldPercent;
        return _swap(amountIn, amountOutMin, path, to, deadline, true);
    }

    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline,
        uint8 autoYieldPercent
    ) external returns (uint256[] memory amounts) {
        autoYieldPercent;
        uint256 out = _swap(amountIn, amountOutMin, path, to, deadline, false);
        amounts = new uint256[](path.length);
        amounts[0] = amountIn;
        amounts[path.length - 1] = out;
    }

    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts) {
        uint256 out = _swap(amountIn, amountOutMin, path, to, deadline, false);
        amounts = new uint256[](path.length);
        amounts[0] = amountIn;
        amounts[path.length - 1] = out;
    }

    function _swap(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline,
        bool feeOnTransferPath
    ) internal returns (uint256 amountOut) {
        if (mode == Mode.REVERT_ALWAYS) revert ForcedRevert();
        require(path.length >= 2, "MockParagonRouter: bad path");
        require(block.timestamp <= deadline, "MockParagonRouter: expired");

        address tokenIn = path[0];
        address tokenOut = path[path.length - 1];

        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);

        amountOut = amountIn;
        if (mode == Mode.UNDER_DELIVER) {
            amountOut = amountIn / 2;
        }

        require(amountOut >= amountOutMin, "MockParagonRouter: slippage");

        address recipient = to;
        if (mode == Mode.WRONG_RECEIVER) {
            recipient = address(0xdead);
        }

        IERC20(tokenOut).safeTransfer(recipient, amountOut);

        emit SwapCalled(tokenIn, tokenOut, amountIn, amountOutMin, recipient, deadline, feeOnTransferPath);
    }
}
