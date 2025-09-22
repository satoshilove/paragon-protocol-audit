// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

interface IERC20 { function transfer(address to, uint amount) external returns (bool); }

contract MockTreasurySplitter {
    event Credited(address token, uint256 amount);

    function credit(address token, uint256 amount) external {
        // caller must have transferred tokens to this contract already
        emit Credited(token, amount);
    }
}
