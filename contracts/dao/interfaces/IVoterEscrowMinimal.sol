// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

interface IVoterEscrowMinimal {
    function balanceOf(address user) external view returns (uint256);
    function balanceOfAtTime(address user, uint256 ts) external view returns (uint256);
    function totalSupplyAtTime(uint256 ts) external view returns (uint256);
}