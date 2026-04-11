// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

contract LinearTokenVesting is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    IERC20 public token;
    address public immutable beneficiary;

    uint64 public immutable startTimestamp;
    uint64 public immutable cliffTimestamp;
    uint64 public immutable endTimestamp;

    uint256 public released;
    bool public tokenInitialized;

    event TokenInitialized(address indexed token);
    event TokensReleased(address indexed beneficiary, uint256 amount);

    constructor(
        address initialOwner,
        address beneficiaryAddress,
        uint64 startTs,
        uint64 cliffTs,
        uint64 endTs
    ) Ownable(initialOwner) {
        require(initialOwner != address(0), "owner=0");
        require(beneficiaryAddress != address(0), "beneficiary=0");
        require(startTs > 0, "start=0");
        require(cliffTs >= startTs, "cliff<start");
        require(endTs > cliffTs, "end<=cliff");

        beneficiary = beneficiaryAddress;
        startTimestamp = startTs;
        cliffTimestamp = cliffTs;
        endTimestamp = endTs;
    }

    function initializeToken(address tokenAddress) external onlyOwner {
        require(!tokenInitialized, "token already initialized");
        require(tokenAddress != address(0), "token=0");

        token = IERC20(tokenAddress);
        tokenInitialized = true;

        emit TokenInitialized(tokenAddress);
    }

    function releasable() public view returns (uint256) {
        if (!tokenInitialized) return 0;
        return vestedAmount(uint64(block.timestamp)) - released;
    }

    function vestedAmount(uint64 timestamp) public view returns (uint256) {
        if (!tokenInitialized) return 0;

        uint256 totalAllocation = token.balanceOf(address(this)) + released;

        if (timestamp < cliffTimestamp) {
            return 0;
        }

        if (timestamp >= endTimestamp) {
            return totalAllocation;
        }

        uint256 elapsed = uint256(timestamp - startTimestamp);
        uint256 duration = uint256(endTimestamp - startTimestamp);

        return (totalAllocation * elapsed) / duration;
    }

    function release() external nonReentrant {
        require(tokenInitialized, "token not initialized");

        uint256 amount = releasable();
        require(amount > 0, "nothing releasable");

        released += amount;
        token.safeTransfer(beneficiary, amount);

        emit TokensReleased(beneficiary, amount);
    }

    function recoverWrongToken(address wrongToken, address to, uint256 amount) external onlyOwner nonReentrant {
        require(to != address(0), "to=0");
        require(!tokenInitialized || wrongToken != address(token), "cannot recover vested token");

        IERC20(wrongToken).safeTransfer(to, amount);
    }
}