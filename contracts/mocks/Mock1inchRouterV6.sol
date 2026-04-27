// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.27;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract Mock1inchRouterV6 {
    using SafeERC20 for IERC20;

    struct SwapDescription {
        IERC20 srcToken;
        IERC20 dstToken;
        address payable srcReceiver;
        address payable dstReceiver;
        uint256 amount;
        uint256 minReturnAmount;
        uint256 flags;
    }

    function swap(
        address executor,
        SwapDescription calldata desc,
        bytes calldata permit,
        bytes calldata data
    ) external payable returns (uint256 returnAmount, uint256 spentAmount) {
        executor;
        permit;
        require(msg.value == 0, "Mock1inch: no native");
        require(desc.srcReceiver != address(0), "Mock1inch: bad srcReceiver");
        require(desc.dstReceiver != address(0), "Mock1inch: bad dstReceiver");

        returnAmount = abi.decode(data, (uint256));
        spentAmount = desc.amount;

        desc.srcToken.safeTransferFrom(msg.sender, address(this), desc.amount);
        desc.dstToken.safeTransfer(desc.dstReceiver, returnAmount);
    }
}
