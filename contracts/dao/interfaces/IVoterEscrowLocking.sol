// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

interface IVoterEscrowLocking {
    function create_lock_for(
        address to,
        uint256 amount,
        uint256 unlockTime
    ) external returns (uint256 tokenId);

    function create_lock_for(
        uint256 amount,
        uint256 unlockTime,
        address to
    ) external returns (uint256 tokenId);
}