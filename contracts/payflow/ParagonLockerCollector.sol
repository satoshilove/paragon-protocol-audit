// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.25;

/**
 * Paragon Locker Collector — Hardened for PAC-15
 *
 * Remediations:
 *  - harvest()/harvestMany() are keeper-gated (only trusted executors may trigger swaps)
 *  - Optional pluggable price guard (IPriceGuard) enforces a market-consistent minimum
 *  - Optional strictDirectPathOnly blocks multi-hop attacker paths
 *  - Optional maxSwapPerTx reduces blast radius via chunking
 *
 * Compatibility notes:
 *  - Constructor mirrors previous signature (Ownable(initialOwner)) to remain compatible with your codebase
 *  - Router and ERC4626 vault interfaces unchanged
 *  - Events preserved; new events & setters added for governance visibility
 */

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/security/Pausable.sol";

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

/**
 * Optional pluggable price guard interface.
 * Example implementation could use Chainlink USD feeds or a TWAP-based quoting contract.
 */
interface IPriceGuard {
    /// @notice Quote how many XPGN would be expected for `amountIn` of `tokenIn`
    /// @dev returns amount of XPGN (in XPGN token decimals)
    function quoteXPGNOut(address tokenIn, uint256 amountIn) external view returns (uint256);
}

interface IERC4626Like {
    function asset() external view returns (address);                              // XPGN
    function deposit(uint256 assets, address receiver) external returns (uint256); // mints stXPGN shares
}

contract ParagonLockerCollector is Ownable, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;

    IParagonRouterV2Like public router;
    IERC4626Like         public stxpgnVault;

    address public immutable XPGN; // vault asset
    address public receiver;       // where stXPGN shares go (e.g., DAO or distributor)

    uint8  public constant DEFAULT_AUTO_PREF = 0;
    uint8  public constant MAX_PATH_LEN = 5;
    uint32 public constant DEFAULT_DEADLINE_SECS = 600; // 10 minutes

    // --- Keeper gating ---
    mapping(address => bool) public keeper;
    event KeeperSet(address indexed account, bool allowed);

    // --- Optional defense-in-depth ---
    IPriceGuard public priceGuard;                 // optional, address(0) = disabled
    uint16      public maxSlippageBips = 1000;     // default 10% (in bips, 1 bps = 0.01%)
    uint256     public maxSwapPerTx;               // 0 => no cap
    bool        public strictDirectPathOnly = false;

    mapping(address => bool) public allowedToken; // tokens accepted from the executor

    event Harvested(address indexed tokenIn, uint256 amountIn, uint256 xpgnOut, uint256 stxpgnShares);
    event AllowedTokenSet(address indexed token, bool allowed);
    event ReceiverSet(address indexed receiver);
    event RouterSet(address indexed router);
    event VaultSet(address indexed vault);
    event Swept(address indexed token, address indexed to, uint256 amount);
    event NativeSwept(address indexed to, uint256 amount);

    event PriceGuardSet(address indexed guard);
    event MaxSlippageSet(uint16 bips);
    event MaxSwapPerTxSet(uint256 amount);
    event StrictDirectPathOnlySet(bool enabled);

    error PathInvalid();
    error PathTooLong();
    error TokenNotAllowed();
    error NothingToHarvest();
    error NotKeeper();

    // --- Pause guardian (pause-only) ---
    event GuardianSet(address indexed guardian);
    address public guardian;

    modifier onlyOwnerOrGuardian() {
        require(msg.sender == owner() || msg.sender == guardian, "not owner/guardian");
        _;
    }

    modifier onlyKeeper() {
        if (!keeper[msg.sender]) revert NotKeeper();
        _;
    }

    /// @notice Constructor kept compatible with existing codebase (Ownable(initialOwner) used previously)
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
    function setGuardian(address g) external onlyOwner {
        guardian = g;
        emit GuardianSet(g);
    }

    function pause(string calldata /*reason*/) external onlyOwnerOrGuardian {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

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

    // --- Keeper / guards config ---
    function setKeeper(address account, bool allowed) external onlyOwner {
        keeper[account] = allowed;
        emit KeeperSet(account, allowed);
    }

    function setPriceGuard(address guard) external onlyOwner {
        priceGuard = IPriceGuard(guard);
        emit PriceGuardSet(guard);
    }

    function setMaxSlippageBips(uint16 bips) external onlyOwner {
        require(bips <= 5000, "too high"); // cap to 50%
        maxSlippageBips = bips;
        emit MaxSlippageSet(bips);
    }

    function setMaxSwapPerTx(uint256 amount) external onlyOwner {
        maxSwapPerTx = amount;
        emit MaxSwapPerTxSet(amount);
    }

    function setStrictDirectPathOnly(bool enabled) external onlyOwner {
        strictDirectPathOnly = enabled;
        emit StrictDirectPathOnlySet(enabled);
    }

    // -------- External entrypoints (nonReentrant, now keeper-gated) --------
    /// @notice Only keeper addresses (set via setKeeper) may call harvest
    function harvest(
        address tokenIn,
        uint256 minXPGNOut,
        address[] calldata path
    ) external nonReentrant whenNotPaused onlyKeeper {
        _harvest(tokenIn, minXPGNOut, path);
    }

    /// @notice Batch harvesting — keeper-only
    function harvestMany(
        address[] calldata tokens,
        uint256[] calldata minOuts,
        address[][] calldata paths
    ) external nonReentrant whenNotPaused onlyKeeper {
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

        uint256 bal = IERC20(tokenIn).balanceOf(address(this));
        if (bal == 0) revert NothingToHarvest();

        uint256 amountIn = bal;
        if (maxSwapPerTx != 0 && amountIn > maxSwapPerTx) {
            amountIn = maxSwapPerTx;
        }

        if (tokenIn == XPGN) {
            // No swap needed — deposit directly
            uint256 shares = _depositToVault(amountIn);
            emit Harvested(tokenIn, amountIn, amountIn, shares);
            return;
        }

        // Path validation
        if (path.length < 2) revert PathInvalid();
        if (path.length > MAX_PATH_LEN) revert PathTooLong();
        if (path[0] != tokenIn || path[path.length - 1] != XPGN) revert PathInvalid();
        if (strictDirectPathOnly) {
            if (path.length != 2 || path[1] != XPGN) revert PathInvalid();
        }

        _approveMax(IERC20(tokenIn), address(router), amountIn);

        uint256 xBefore = IERC20(XPGN).balanceOf(address(this));
        router.swapExactTokensForTokensSupportingFeeOnTransferTokens(
            amountIn,
            minXPGNOut, // still honored as a caller-provided guard (keeper supplies this)
            path,
            address(this),
            block.timestamp + DEFAULT_DEADLINE_SECS,
            DEFAULT_AUTO_PREF
        );
        uint256 xAfter = IERC20(XPGN).balanceOf(address(this));
        uint256 xGot   = xAfter - xBefore;

        // --- Oracle sanity check (optional) ---
        if (address(priceGuard) != address(0)) {
            uint256 fair = priceGuard.quoteXPGNOut(tokenIn, amountIn);
            // require xGot >= fair * (1 - maxSlippageBips)
            uint256 minFair = (fair * (10_000 - maxSlippageBips)) / 10_000;
            require(xGot >= minFair, "priceGuard: too little out");
        }

        // Keep original minOut check (extra guard)
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
            SafeERC20.forceApprove(t, spender, 0);
            SafeERC20.forceApprove(t, spender, type(uint256).max);
        }
    }

    // -------- Rescues --------
    function sweep(address token, address to) external onlyOwner {
        require(to != address(0), "to=0");
        uint256 bal = IERC20(token).balanceOf(address(this));
        if (bal > 0) {
            IERC20(token).safeTransfer(to, bal);
        }
        emit Swept(token, to, bal);
    }

    function withdrawNative(address to) external onlyOwner {
        require(to != address(0), "to=0");
        uint256 bal = address(this).balance;
        if (bal > 0) {
            (bool ok, ) = to.call{value: bal}("");
            require(ok, "ETH transfer failed");
        }
        emit NativeSwept(to, bal);
    }

    receive() external payable {}
}
