// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";

/**
 * @title P10Token
 * @notice ERC20 token representing the Paragon P10 index.
 *
 * @dev
 * - Only the designated indexManager can mint/burn.
 * - No custom transfer logic (simple & audit-friendly).
 * - Owner is 2-step ownable for safe transfer to timelock / multisig.
 *
 * Invariants:
 * - indexManager != address(0) after initial setup.
 * - Only indexManager can call mint() / burn().
 */
contract P10Token is ERC20, Ownable2Step {
    /// @notice Index manager with exclusive mint/burn rights.
    address public indexManager;

    event IndexManagerUpdated(address indexed oldManager, address indexed newManager);

    /**
     * @notice Constructor.
     * @param initialOwner Initial owner (recommended: timelock or multisig address).
     */
    constructor(address initialOwner)
        ERC20("Paragon P10 Index", "P10")
        Ownable(initialOwner)          // ← This fixes the base constructor error
    {
        // No need for _transferOwnership() — already handled by Ownable(initialOwner)
    }

    modifier onlyIndexManager() {
        require(msg.sender == indexManager, "P10: not index manager");
        _;
    }

    /**
     * @notice Set the index manager contract (P10IndexManager).
     * @dev Restricted to current owner (governance).
     * @param _manager New manager address (non-zero).
     */
    function setIndexManager(address _manager) external onlyOwner {
        require(_manager != address(0), "P10: zero manager");
        emit IndexManagerUpdated(indexManager, _manager);
        indexManager = _manager;
    }

    /**
     * @notice Mint P10 tokens to `to`. Exclusive to indexManager.
     * @param to Recipient address.
     * @param amount Amount of tokens to mint.
     */
    function mint(address to, uint256 amount) external onlyIndexManager {
        _mint(to, amount);
    }

    /**
     * @notice Burn `amount` of P10 tokens from `from`. Exclusive to indexManager.
     * @param from Address to burn from (must have sufficient balance).
     * @param amount Amount of tokens to burn.
     */
    function burn(address from, uint256 amount) external onlyIndexManager {
        _burn(from, amount);
    }
}