// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract MockFeeSink {
    event Received(address token, uint256 amount);

    function pull(address token, uint256 amount) external {
        IERC20(token).transferFrom(msg.sender, address(this), amount);
        emit Received(token, amount);
    }
}
