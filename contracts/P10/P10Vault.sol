// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {IP10IndexManager} from "./interfaces/IP10IndexManager.sol";

contract P10Vault is Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    address public indexManager;
    address public executionManager;

    event IndexManagerUpdated(address indexed oldManager, address indexed newManager);
    event ExecutionManagerUpdated(address indexed oldManager, address indexed newManager);
    event Deposited(address indexed token, uint256 amount, address indexed from);
    event Withdrawn(address indexed token, uint256 amount, address indexed to);

    constructor(address initialOwner, address _indexManager) Ownable(initialOwner) {
        require(_indexManager != address(0), "P10Vault: zero indexManager");
        indexManager = _indexManager;
    }

    modifier onlyIndexManager() {
        require(msg.sender == indexManager, "P10Vault: not indexManager");
        _;
    }

    modifier onlyExecutionManager() {
        require(msg.sender == executionManager, "P10Vault: not executionManager");
        _;
    }

    modifier onlyIndexOrExecution() {
        require(
            msg.sender == indexManager || msg.sender == executionManager,
            "P10Vault: not authorized"
        );
        _;
    }

    function setIndexManager(address _indexManager) external onlyOwner {
        require(_indexManager != address(0), "P10Vault: zero indexManager");
        emit IndexManagerUpdated(indexManager, _indexManager);
        indexManager = _indexManager;
    }

    function setExecutionManager(address _executionManager) external onlyOwner {
        require(_executionManager != address(0), "P10Vault: zero executionManager");
        emit ExecutionManagerUpdated(executionManager, _executionManager);
        executionManager = _executionManager;
    }

    /// @notice Direct basket deposit for basket-exact mint path.
    /// @dev Explicitly rejects fee-on-transfer / unsupported transfer behavior.
    function directDepositFromUser(
        address token,
        address from,
        uint256 amount
    ) external onlyIndexManager nonReentrant {
        require(token != address(0), "P10Vault: zero token");
        require(from != address(0), "P10Vault: zero from");
        require(amount > 0, "P10Vault: zero amount");

        uint256 beforeBal = IERC20(token).balanceOf(address(this));
        IERC20(token).safeTransferFrom(from, address(this), amount);
        uint256 afterBal = IERC20(token).balanceOf(address(this));
        uint256 received = afterBal - beforeBal;

        require(received == amount, "P10Vault: unsupported transfer token");

        emit Deposited(token, amount, from);
    }

    /// @notice Direct pro-rata redeem transfer to end recipient.
    function directWithdrawToUser(
        address token,
        address to,
        uint256 amount
    ) external onlyIndexManager nonReentrant {
        require(token != address(0), "P10Vault: zero token");
        require(to != address(0), "P10Vault: zero to");
        require(amount > 0, "P10Vault: zero amount");

        IERC20(token).safeTransfer(to, amount);
        emit Withdrawn(token, amount, to);
    }

    /// @notice Move basket assets from vault to execution manager for sell flow.
    function withdrawToExecutionManager(
        address token,
        uint256 amount
    ) external onlyIndexManager nonReentrant {
        require(token != address(0), "P10Vault: zero token");
        require(executionManager != address(0), "P10Vault: exec not set");
        require(amount > 0, "P10Vault: zero amount");

        IERC20(token).safeTransfer(executionManager, amount);
        emit Withdrawn(token, amount, executionManager);
    }

    /// @notice Receive assets from execution layer after swaps.
    /// @dev Tokens must already have been transferred to this contract.
    function recordExecutionDeposit(
        address token,
        uint256 amount,
        address from
    ) external onlyExecutionManager {
        require(token != address(0), "P10Vault: zero token");
        require(from != address(0), "P10Vault: zero from");
        require(amount > 0, "P10Vault: zero amount");

        emit Deposited(token, amount, from);
    }

    /// @notice Rescue only non-active-basket assets.
    /// @dev This prevents owner from pulling live basket constituents out of the vault.
    function rescueToken(
        address token,
        address to,
        uint256 amount
    ) external onlyOwner nonReentrant {
        require(token != address(0), "P10Vault: zero token");
        require(to != address(0), "P10Vault: zero to");
        require(amount > 0, "P10Vault: zero amount");
        require(indexManager != address(0), "P10Vault: indexManager not set");

        bool isActiveBasketAsset = false;

        try IP10IndexManager(indexManager).getActiveAssets() returns (IP10IndexManager.Asset[] memory assets) {
            for (uint256 i = 0; i < assets.length; i++) {
                if (assets[i].token == token) {
                    isActiveBasketAsset = true;
                    break;
                }
            }
        } catch {
            revert("P10Vault: snapshot read failed");
        }

        require(!isActiveBasketAsset, "P10Vault: active basket asset");

        IERC20(token).safeTransfer(to, amount);
        emit Withdrawn(token, amount, to);
    }
}
