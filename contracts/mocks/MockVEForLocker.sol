// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

contract MockVEForLocker {
    event LockFor(address indexed to, uint256 amount, uint256 unlockTime, uint256 tokenId);
    uint256 public nextId = 1;

    struct Lock { address to; uint256 amount; uint256 unlock; }
    mapping(uint256 => Lock) public locks;

    // Solidly order
    function create_lock_for(uint256 amount, uint256 unlock_time, address to) external returns (uint256 tokenId) {
        tokenId = nextId++;
        locks[tokenId] = Lock(to, amount, unlock_time);
        emit LockFor(to, amount, unlock_time, tokenId);
    }

    // Preferred order
    function create_lock_for(address to, uint256 amount, uint256 unlock_time) external returns (uint256 tokenId) {
        tokenId = nextId++;
        locks[tokenId] = Lock(to, amount, unlock_time);
        emit LockFor(to, amount, unlock_time, tokenId);
    }
}
