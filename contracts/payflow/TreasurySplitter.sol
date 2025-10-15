// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.25;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/security/Pausable.sol";

/**
 * Set `daoVault = address(this)` in PayflowExecutorV2 so protocolCut lands here.
 * Then call `distribute(token)` periodically (or via a keeper).
 * Default split: 60% lockers, 35% DAO treasury, 5% backstop.
 *
 * Governance hardening: Pausable + pause guardian (pause-only).
 */
contract TreasurySplitter is Ownable, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;

    address public sink60; // veXPGN lockers (or revenue distributor)
    address public sink35; // DAO treasury
    address public sink05; // Backstop (or same DAO if unused)

    event SinksUpdated(address sink60, address sink35, address sink05);
    event Distributed(address indexed token, uint256 amount, uint256 p60, uint256 p35, uint256 p05);
    event Swept(address indexed token, address indexed to, uint256 amount);
    event NativeSwept(address indexed to, uint256 amount);
    event PausedByGuardian(address indexed account);
    event UnpausedByOwner(address indexed account);

    // --- Pause guardian (pause-only) ---
    event GuardianSet(address indexed guardian);
    address public guardian;

    modifier onlyOwnerOrGuardian() {
        require(msg.sender == owner() || msg.sender == guardian, "not owner/guardian");
        _;
    }

    // ✅ pass initial owner to Ownable (OZ v5)
    constructor(address initialOwner, address _sink60, address _sink35, address _sink05) Ownable(initialOwner) {
        require(_sink60 != address(0) && _sink35 != address(0) && _sink05 != address(0), "sink=0");
        sink60 = _sink60; sink35 = _sink35; sink05 = _sink05;
        emit SinksUpdated(_sink60, _sink35, _sink05);
    }

    // --- pause controls ---
    function setGuardian(address g) external onlyOwner {
        guardian = g;
        emit GuardianSet(g);
    }
    function pause() external onlyOwnerOrGuardian { _pause(); emit PausedByGuardian(msg.sender); }
    function unpause() external onlyOwner { _unpause(); emit UnpausedByOwner(msg.sender); }

    function setSinks(address _sink60, address _sink35, address _sink05) external onlyOwner whenNotPaused {
        require(_sink60 != address(0) && _sink35 != address(0) && _sink05 != address(0), "sink=0");
        sink60 = _sink60; sink35 = _sink35; sink05 = _sink05;
        emit SinksUpdated(_sink60, _sink35, _sink05);
    }

    function distribute(address token) external onlyOwner nonReentrant whenNotPaused {
        require(token != address(0), "token=0");
        uint256 bal = IERC20(token).balanceOf(address(this));
        if (bal == 0) { emit Distributed(token, 0, 0, 0, 0); return; }

        uint256 p60 = (bal * 6000) / 10_000;
        uint256 p35 = (bal * 3500) / 10_000;
        uint256 p05 = bal - p60 - p35;

        IERC20(token).safeTransfer(sink60, p60);
        IERC20(token).safeTransfer(sink35, p35);
        IERC20(token).safeTransfer(sink05, p05);

        emit Distributed(token, bal, p60, p35, p05);
    }

    // Optional rescue
    function sweep(address token, address to) external onlyOwner nonReentrant whenNotPaused {
        require(token != address(0), "token=0");
        require(to != address(0), "to=0");
        uint256 bal = IERC20(token).balanceOf(address(this));
        if (bal > 0) {
            IERC20(token).safeTransfer(to, bal);
        }
        emit Swept(token, to, bal);
    }

    receive() external payable {}

    function sweepNative(address to) external onlyOwner nonReentrant whenNotPaused {
        require(to != address(0), "to=0");
        uint256 bal = address(this).balance;
        if (bal > 0) {
            (bool ok, ) = to.call{value: bal}("");
            require(ok, "ETH transfer failed");
        }
        emit NativeSwept(to, bal);
    }
}
