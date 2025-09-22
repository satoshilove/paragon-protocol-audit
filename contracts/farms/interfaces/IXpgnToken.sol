// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IXpgnToken {
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function approve(address spender, uint256 amount) external returns (bool);
    function mint(address to, uint256 amount, bytes32 role) external;
}