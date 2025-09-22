// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.25;

/**
 * Paragon Locker Collector
 * - Receives arbitrary tokens as the "locker share" from the Executor
 * - Swaps them to XPGN using Paragon Router
 * - Deposits XPGN into the stXPGN (ERC-4626 style) vault
 * - Sends the resulting stXPGN shares to a designated receiver (DAO / distributor)
 *
 * Permissions:
 * - Anyone can call harvest()/harvestMany() (permissionless); slippage guarded by caller-provided minOut.
 * - Owner configures allowed tokens, receiver, and router/vault params.
 */

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

interface IParagonRouterV2Like {
    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        uint amountIn,
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline,
        uint8 autoYieldPercent
    ) external;
}

interface IERC4626Like {
    function asset() external view returns (address);                              // XPGN
    function deposit(uint256 assets, address receiver) external returns (uint256); // mints stXPGN shares
}

contract ParagonLockerCollector is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    IParagonRouterV2Like public router;
    IERC4626Like         public stxpgnVault;

    address public immutable XPGN; // vault asset
    address public receiver;       // where stXPGN shares go (e.g., DAO or distributor)

    uint8  public constant DEFAULT_AUTO_PREF = 0;
    uint8  public constant MAX_PATH_LEN = 5;
    uint32 public constant DEFAULT_DEADLINE_SECS = 600; // 10 minutes

    mapping(address => bool) public allowedToken; // tokens accepted from the executor

    event Harvested(address indexed tokenIn, uint256 amountIn, uint256 xpgnOut, uint256 stxpgnShares);
    event AllowedTokenSet(address indexed token, bool allowed);
    event ReceiverSet(address indexed receiver);
    event RouterSet(address indexed router);
    event VaultSet(address indexed vault);

    error PathInvalid();
    error PathTooLong();
    error TokenNotAllowed();
    error NothingToHarvest();

    constructor(address _router, address _stxpgnVault, address _receiver, address initialOwner) Ownable(initialOwner) {
        require(_router != address(0) && _stxpgnVault != address(0) && _receiver != address(0), "zero");
        router      = IParagonRouterV2Like(_router);
        stxpgnVault = IERC4626Like(_stxpgnVault);
        receiver    = _receiver;
        XPGN        = stxpgnVault.asset();
        emit RouterSet(_router);
        emit VaultSet(_stxpgnVault);
        emit ReceiverSet(_receiver);
    }

    // -------- Admin --------
    function setReceiver(address _receiver) external onlyOwner {
        require(_receiver != address(0), "zero");
        receiver = _receiver;
        emit ReceiverSet(_receiver);
    }

    function setRouter(address _router) external onlyOwner {
        require(_router != address(0), "zero");
        router = IParagonRouterV2Like(_router);
        emit RouterSet(_router);
    }

    function setVault(address _vault) external onlyOwner {
        require(_vault != address(0), "zero");
        stxpgnVault = IERC4626Like(_vault);
        require(stxpgnVault.asset() == XPGN, "asset changed");
        emit VaultSet(_vault);
    }

    function setAllowedToken(address token, bool allowed) external onlyOwner {
        allowedToken[token] = allowed;
        emit AllowedTokenSet(token, allowed);
    }

    // Optional convenience for batch allow
    function setAllowedTokens(address[] calldata tokens, bool allowed) external onlyOwner {
        for (uint i; i < tokens.length; i++) {
            allowedToken[tokens[i]] = allowed;
            emit AllowedTokenSet(tokens[i], allowed);
        }
    }

    // -------- External entrypoints (nonReentrant) --------
    function harvest(
        address tokenIn,
        uint256 minXPGNOut,
        address[] calldata path
    ) external nonReentrant {
        _harvest(tokenIn, minXPGNOut, path);
    }

    // Batch: processes multiple tokens in a single tx without reentering
    function harvestMany(
        address[] calldata tokens,
        uint256[] calldata minOuts,
        address[][] calldata paths
    ) external nonReentrant {
        uint256 n = tokens.length;
        require(minOuts.length == n && paths.length == n, "len");
        for (uint i; i < n; i++) {
            _harvest(tokens[i], minOuts[i], paths[i]);
        }
    }

    // -------- Internal core --------
    function _harvest(
        address tokenIn,
        uint256 minXPGNOut,
        address[] calldata path
    ) internal {
        if (!allowedToken[tokenIn]) revert TokenNotAllowed();

        uint256 amountIn = IERC20(tokenIn).balanceOf(address(this));
        if (amountIn == 0) revert NothingToHarvest();

        if (tokenIn == XPGN) {
            // No swap; deposit directly
            uint256 shares = _depositToVault(amountIn);
            emit Harvested(tokenIn, amountIn, amountIn, shares);
            return;
        }

        // For swaps, require a valid path tokenIn -> ... -> XPGN
        if (path.length < 2 || path.length > MAX_PATH_LEN) revert PathTooLong();
        if (path[0] != tokenIn || path[path.length - 1] != XPGN) revert PathInvalid();

        _approveMax(IERC20(tokenIn), address(router), amountIn);

        uint256 xBefore = IERC20(XPGN).balanceOf(address(this));
        router.swapExactTokensForTokensSupportingFeeOnTransferTokens(
            amountIn,
            minXPGNOut,
            path,
            address(this),
            block.timestamp + DEFAULT_DEADLINE_SECS,
            DEFAULT_AUTO_PREF
        );
        uint256 xAfter = IERC20(XPGN).balanceOf(address(this));
        uint256 xGot   = xAfter - xBefore;
        require(xGot >= minXPGNOut, "minOut");

        uint256 sharesMinted = _depositToVault(xGot);
        emit Harvested(tokenIn, amountIn, xGot, sharesMinted);
    }

    function _depositToVault(uint256 xpgnAmount) internal returns (uint256 shares) {
        _approveMax(IERC20(XPGN), address(stxpgnVault), xpgnAmount);
        shares = stxpgnVault.deposit(xpgnAmount, receiver);
    }

    function _approveMax(IERC20 t, address spender, uint256 needed) internal {
        uint256 cur = t.allowance(address(this), spender);
        if (cur < needed) {
            // Use library-style call to avoid interface method resolution issues
            SafeERC20.forceApprove(t, spender, 0);
            SafeERC20.forceApprove(t, spender, type(uint256).max);
        }
    }

    // -------- Rescues --------
    function sweep(address token, address to) external onlyOwner {
        require(to != address(0), "to=0");
        uint256 bal = IERC20(token).balanceOf(address(this));
        if (bal > 0) IERC20(token).safeTransfer(to, bal);
    }

    receive() external payable {}
}