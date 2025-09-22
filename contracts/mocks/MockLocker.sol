// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract MockLocker {
    event Locked(address token, uint256 amount, address user);

    function depositFor(address token, uint256 amount, address user) external {
        IERC20(token).transferFrom(msg.sender, address(this), amount);
        emit Locked(token, amount, user);
    }
}
