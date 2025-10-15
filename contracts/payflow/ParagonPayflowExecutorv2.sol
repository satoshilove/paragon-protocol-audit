// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.25;

/*
 * Paragon Flow DEX — Core contracts
 * ParagonPayflowExecutorV2 — surplus split (trader cashback + LP flow rebates + locker cut + optional protocol cut + relayer fee)
 */

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol"; // OZ v5 path (utils)
import "@openzeppelin/contracts/security/Pausable.sol";

// Use shared interfaces for readability
import { IUsdValuer }     from "../interfaces/IUsdValuer.sol";
import { ILPFlowRebates } from "../interfaces/ILPFlowRebates.sol";

/************************** Router Interface **************************/
interface IParagonRouterV2Like {
    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        uint amountIn,
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline,
        uint8 autoYieldPercent
    ) external;

    function swapExactTokensForTokens(
        uint amountIn,
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline,
        uint8 autoYieldPercent
    ) external returns (uint[] memory amounts);

    function swapExactTokensForTokens(
        uint amountIn,
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external returns (uint[] memory amounts);
}

/************************** BestExec Interface **************************/
interface IBestExec {
    struct SwapIntent {
        address user;
        address tokenIn;
        address tokenOut;
        uint256 amountIn;
        uint256 minAmountOut;
        uint256 deadline;
        address recipient;
        uint256 nonce;
    }
    function consume(SwapIntent memory it, bytes calldata sig) external;
    function hashIntent(SwapIntent memory it) external view returns (bytes32);
}

/************************** Optional Hooks **************************/
interface IReputationOperator {
    function onPayflowExecuted(
        address user,
        uint256 usdVol1e18,
        uint256 usdSaved1e18,
        bytes32 ref
    ) external;
}

/************************** EXECUTOR V2 **************************/
contract ParagonPayflowExecutorV2 is Ownable, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;

    IParagonRouterV2Like public router;
    IBestExec public bestExec;
    IReputationOperator public repOp; // optional
    IUsdValuer public valuer;         // optional

    address public daoVault;          // protocol revenue (from surplus only)
    address public lockerVault;       // recipient of locker-share (e.g., collector -> stXPGN)
    ILPFlowRebates public lpRebates;  // sink for LP flow rewards

    // Only from SURPLUS
    uint16 public protocolFeeBips; // e.g., 50 => 0.50% of surplus (launch at 0)

    // Split of distributable surplus (must sum <= 10_000)
    uint16 public traderBips = 6000; // 60%
    uint16 public lpBips     = 3000; // 30%
    // locker gets remainder (10%)

    // Optional relayer fee (for gasless) — capped tiny; taken from surplus first
    uint16 public relayerFeeBips;
    uint16 public constant MAX_RELAYER_FEE_BPS = 10; // 10 bps = 0.10%

    // Max path length guard
    uint8 public constant MAX_PATH_LEN = 5;

    // Router UX param
    uint8 public constant DEFAULT_AUTO_PREF = 0;

    // Whitelist for tokens (regulates non-standard/deflationary tokens)
    mapping(address => bool) public supportedToken;

    // ───────────────────────────── Errors ─────────────────────────────
    error RouterSwapFailed();
    error BadSplit();
    error PathMismatch();
    error PathTooLong();
    error InvalidHopShares();
    error PermitFailed();
    error InvalidRecipient();
    error InvalidSwap();
    error VenuePaused();
    error UnsupportedToken();

    // ───────────────────────────── Venue toggles ──────────────────────
    mapping(address => bool) public venueEnabled;
    event VenueToggled(address indexed venue, bool enabled);

    /**
     * @notice Toggle a third-party venue (e.g., router, lpRebates) on/off.
     * @dev Use for quick mitigation of external issues; defaults to enabled.
     */
    function setVenueEnabled(address venue, bool enabled) external onlyOwner {
        require(venue != address(0), "venue=0");
        venueEnabled[venue] = enabled;
        emit VenueToggled(venue, enabled);
    }

    // ───────────────────────────── Relayer allowlist ──────────────────
    mapping(address => bool) public isRelayer;
    event RelayerSet(address indexed relayer, bool allowed);

    /**
     * @notice Add/remove relayer to allowlist for fee eligibility.
     */
    function setRelayer(address relayer, bool allowed) external onlyOwner {
        require(relayer != address(0), "relayer=0");
        isRelayer[relayer] = allowed;
        emit RelayerSet(relayer, allowed);
    }

    // Supported tokens management
    event SupportedTokenSet(address indexed token, bool supported);

    function setSupportedToken(address token, bool supported) external onlyOwner {
        require(token != address(0), "token=0");
        supportedToken[token] = supported;
        emit SupportedTokenSet(token, supported);
    }

    // ─────── Guardian (pause-only) ───────
    event GuardianSet(address indexed guardian);
    address public guardian;

    modifier onlyOwnerOrGuardian() {
        require(msg.sender == owner() || msg.sender == guardian, "not owner/guardian");
        _;
    }

    /**
     * @notice Set the pause guardian (can call pause only). Timelocked via onlyOwner.
     */
    function setGuardian(address g) external onlyOwner {
        guardian = g;
        emit GuardianSet(g);
    }

    // ───────────────────────────── Events ─────────────────────────────
    struct PermitData { uint256 value; uint256 deadline; uint8 v; bytes32 r; bytes32 s; }

    event PayflowExecuted(
        address indexed user,
        address indexed tokenIn,
        address indexed tokenOut,
        uint256 amountIn,
        uint256 minOut,
        uint256 amountOut,
        uint256 surplus,
        uint256 traderGet,
        uint256 lpShare,
        uint256 lockerShare,
        uint256 protocolCut,
        address recipient
    );
    event LPRebateAttributed(address indexed tokenIn, address indexed tokenOut, address indexed rewardToken, uint256 amount);
    event SplitUpdated(uint16 traderBips, uint16 lpBips, uint16 lockerBips);
    event RelayerFeeUpdated(uint16 bps);
    event RelayerPaid(address indexed relayer, uint256 amount);
    event ParamsUpdated(address router, address bestExec, address daoVault, address lpRebates, address lockerVault, uint16 protocolFeeBips);
    event PausedByOwner(address indexed owner, string reason);
    event UnpausedByOwner(address indexed owner);
    event ReputationOperatorSet(address indexed op);
    event UsdValuerSet(address indexed valuer);
    event Swept(address indexed token, address indexed to, uint256 amount);
    event NativeSwept(address indexed to, uint256 amount);

    constructor(
        address initialOwner,
        address _router,
        address _bestExec,
        address _daoVault,
        address _lpRebates,
        address _lockerVault
    ) Ownable(initialOwner) {
        if (_router == address(0) || _bestExec == address(0) || _daoVault == address(0)) revert BadSplit();
        router      = IParagonRouterV2Like(_router);
        bestExec    = IBestExec(_bestExec);
        daoVault    = _daoVault;
        lpRebates   = ILPFlowRebates(_lpRebates);
        lockerVault = _lockerVault;

        protocolFeeBips = 0;
        relayerFeeBips  = 0;

        // Default current venues to enabled (non-breaking default)
        venueEnabled[_router] = true;
        emit VenueToggled(_router, true);
        venueEnabled[address(_bestExec)] = true;
        emit VenueToggled(address(_bestExec), true);
        if (_lpRebates != address(0)) {
            venueEnabled[_lpRebates] = true;
            emit VenueToggled(_lpRebates, true);
        }
        if (_lockerVault != address(0)) {
            venueEnabled[_lockerVault] = true;
            emit VenueToggled(_lockerVault, true);
        }

        _checkSplit();
    }

    // ---- admin ----
    function pause(string calldata reason) external onlyOwnerOrGuardian {
        _pause();
        emit PausedByOwner(msg.sender, reason);
    }

    function unpause() external onlyOwner {
        _unpause();
        emit UnpausedByOwner(msg.sender);
    }

    /**
     * @notice Update core params, including third-party venues.
     */
    function setParams(
        address _router,
        address _bestExec,
        address _daoVault,
        address _lpRebates,
        address _lockerVault,
        uint16 _protocolFeeBips
    ) external onlyOwner {
        if (_router == address(0) || _bestExec == address(0) || _daoVault == address(0)) revert BadSplit();
        router      = IParagonRouterV2Like(_router);
        bestExec    = IBestExec(_bestExec);
        daoVault    = _daoVault;
        lpRebates   = ILPFlowRebates(_lpRebates);
        lockerVault = _lockerVault;

        // Cap protocol cut at 10% of SURPLUS
        if (_protocolFeeBips > 1000) revert BadSplit();
        protocolFeeBips = _protocolFeeBips;

        // Opt-in default enable for new venues (keeps behavior seamless)
        venueEnabled[_router] = true;
        emit VenueToggled(_router, true);
        venueEnabled[address(_bestExec)] = true;
        emit VenueToggled(address(_bestExec), true);
        if (_lpRebates != address(0)) {
            venueEnabled[_lpRebates] = true;
            emit VenueToggled(_lpRebates, true);
        }
        if (_lockerVault != address(0)) {
            venueEnabled[_lockerVault] = true;
            emit VenueToggled(_lockerVault, true);
        }

        emit ParamsUpdated(_router, _bestExec, _daoVault, _lpRebates, _lockerVault, _protocolFeeBips);
    }

    /**
     * @notice Update surplus split (trader + LP; locker = remainder).
     */
    function setSplitBips(uint16 _trader, uint16 _lp) external onlyOwner {
        traderBips = _trader;
        lpBips     = _lp;
        _checkSplit();
        uint16 locker = 10000 - _trader - _lp;
        emit SplitUpdated(_trader, _lp, locker);
    }

    /**
     * @notice Update relayer fee bips (capped at 10 bps).
     */
    function setRelayerFeeBips(uint16 bps) external onlyOwner {
        if (bps > MAX_RELAYER_FEE_BPS) revert BadSplit();
        relayerFeeBips = bps;
        emit RelayerFeeUpdated(bps);
    }

    function _checkSplit() internal view {
        if (uint256(traderBips) + lpBips > 10_000) revert BadSplit();
    }

    /**
     * @notice Set optional reputation operator.
     */
    function setReputationOperator(address _repOp) external onlyOwner {
        repOp = IReputationOperator(_repOp);
        if (_repOp != address(0)) venueEnabled[_repOp] = true;
        emit ReputationOperatorSet(_repOp);
    }

    /**
     * @notice Set optional USD valuer.
     */
    function setUsdValuer(address _valuer) external onlyOwner {
        valuer = IUsdValuer(_valuer);
        if (_valuer != address(0)) venueEnabled[_valuer] = true;
        emit UsdValuerSet(_valuer);
    }

    // ----------------- EXECUTE (simple 2-hop path) -----------------
    function execute(
        IBestExec.SwapIntent calldata it,
        bytes calldata sig,
        PermitData calldata permit
    ) external nonReentrant whenNotPaused {
        // Enforce whitelist for tokens
        if (!supportedToken[it.tokenIn] || !supportedToken[it.tokenOut]) revert UnsupportedToken();

        // Venue guards for third-parties
        if (!venueEnabled[address(bestExec)]) revert VenuePaused();
        if (!venueEnabled[address(router)])   revert VenuePaused();

        // Quick expiry check
        if (block.timestamp > it.deadline) revert InvalidSwap();

        bestExec.consume(it, sig);
        if (it.tokenIn == it.tokenOut) revert InvalidSwap();
        if (it.recipient == address(0)) revert InvalidRecipient();
        if (it.amountIn == 0 || it.minAmountOut == 0) revert InvalidSwap();

        if (permit.deadline != 0) {
            try IERC20Permit(it.tokenIn).permit(
                it.user, address(this), permit.value, permit.deadline, permit.v, permit.r, permit.s
            ) {} catch { revert PermitFailed(); }
        }

        // Pull tokenIn and compute actual received (fee-on-transfer safe)
        uint256 inBefore = IERC20(it.tokenIn).balanceOf(address(this));
        IERC20(it.tokenIn).safeTransferFrom(it.user, address(this), it.amountIn);
        uint256 inReceived = IERC20(it.tokenIn).balanceOf(address(this)) - inBefore;
        if (inReceived == 0) revert InvalidSwap();

        _safeApprove(IERC20(it.tokenIn), address(router), inReceived);

        // 2-hop route (tokenIn -> tokenOut)
        address;
        route[0] = it.tokenIn;
        route[1] = it.tokenOut;

        uint256 balBefore = IERC20(it.tokenOut).balanceOf(address(this));
        _routerSwapExactIn(inReceived, it.minAmountOut, route, it.deadline);
        _safeApprove(IERC20(it.tokenIn), address(router), 0);

        uint256 received = IERC20(it.tokenOut).balanceOf(address(this)) - balBefore;
        if (received < it.minAmountOut) revert RouterSwapFailed();

        _splitAndSettle(it, route, received, new uint16);
    }

    // ----------------- EXECUTE WITH PATH (+ optional per-hop attribution) -----------------
    function executeWithPath(
        IBestExec.SwapIntent calldata it,
        bytes calldata sig,
        address[] calldata path,
        uint16[] calldata hopShareBips, // length 0 or path.length-1; sum=10000 if provided
        PermitData calldata permit
    ) external nonReentrant whenNotPaused {
        // Enforce whitelist for tokens
        if (!supportedToken[it.tokenIn] || !supportedToken[it.tokenOut]) revert UnsupportedToken();

        // Venue guards for third-parties
        if (!venueEnabled[address(bestExec)]) revert VenuePaused();
        if (!venueEnabled[address(router)])   revert VenuePaused();

        if (path.length < 2 || path[0] != it.tokenIn || path[path.length - 1] != it.tokenOut) revert PathMismatch();
        if (it.tokenIn == it.tokenOut) revert InvalidSwap();
        if (path.length > MAX_PATH_LEN) revert PathTooLong();
        if (it.amountIn == 0 || it.minAmountOut == 0) revert InvalidSwap();
        if (block.timestamp > it.deadline) revert InvalidSwap();

        bestExec.consume(it, sig);
        if (it.recipient == address(0)) revert InvalidRecipient();

        if (permit.deadline != 0) {
            try IERC20Permit(it.tokenIn).permit(
                it.user, address(this), permit.value, permit.deadline, permit.v, permit.r, permit.s
            ) {} catch { revert PermitFailed(); }
        }

        // Pull tokenIn and compute actual received (fee-on-transfer safe)
        uint256 inBefore = IERC20(it.tokenIn).balanceOf(address(this));
        IERC20(it.tokenIn).safeTransferFrom(it.user, address(this), it.amountIn);
        uint256 inReceived = IERC20(it.tokenIn).balanceOf(address(this)) - inBefore;
        if (inReceived == 0) revert InvalidSwap();

        _safeApprove(IERC20(it.tokenIn), address(router), inReceived);

        uint256 balBefore = IERC20(it.tokenOut).balanceOf(address(this));
        _routerSwapExactIn(inReceived, it.minAmountOut, path, it.deadline);
        _safeApprove(IERC20(it.tokenIn), address(router), 0);

        uint256 received = IERC20(it.tokenOut).balanceOf(address(this)) - balBefore;
        if (received < it.minAmountOut) revert RouterSwapFailed();

        _splitAndSettle(it, path, received, hopShareBips);
    }

    // --- internal: split + settle ---
    function _splitAndSettle(
        IBestExec.SwapIntent calldata it,
        address[] memory path,
        uint256 received,
        uint16[] memory hopShareBips
    ) internal {
        uint256 surplus = received > it.minAmountOut ? (received - it.minAmountOut) : 0;

        // protocolCut is from SURPLUS only
        uint256 protocolCut = (surplus * protocolFeeBips) / 10_000;
        uint256 dist        = surplus - protocolCut;

        uint256 traderShare = (dist * traderBips) / 10_000;
        uint256 lpShare     = (dist * lpBips) / 10_000;
        uint256 lockerShare = dist - traderShare - lpShare;

        // --- Relayer fee (surplus-first, never pushes trader below minOut) ---
        uint256 relayerFee;
        bool payRelayer = (relayerFeeBips > 0)
            && (surplus > 0)
            && (msg.sender != it.user)
            && (isRelayer[msg.sender]);

        if (payRelayer) {
            uint256 requested = (surplus * relayerFeeBips) / 10_000;
            uint256 need = requested;
            uint256 take;

            // 1) from protocolCut
            take = protocolCut < need ? protocolCut : need; protocolCut -= take; need -= take; relayerFee += take;
            // 2) from lpShare
            if (need > 0) { take = lpShare < need ? lpShare : need; lpShare -= take; need -= take; relayerFee += take; }
            // 3) from lockerShare
            if (need > 0) { take = lockerShare < need ? lockerShare : need; lockerShare -= take; need -= take; relayerFee += take; }
            // 4) from trader bonus only (not minOut)
            if (need > 0) {
                uint256 traderGetHeadroom = traderShare;
                take = need > traderGetHeadroom ? traderGetHeadroom : need;
                traderShare -= take;
                need -= take; relayerFee += take;
            }
        }

        // -- Transfers --
        // 0) Pay relayer if any
        if (relayerFee > 0) {
            IERC20(it.tokenOut).safeTransfer(msg.sender, relayerFee);
            emit RelayerPaid(msg.sender, relayerFee);
        }

        // 1) protocol revenue (if any) to DAO vault
        if (protocolCut > 0 && daoVault != address(0)) {
            IERC20(it.tokenOut).safeTransfer(daoVault, protocolCut);
        }

        // 2) trader gets minOut + bonus
        uint256 traderGet = it.minAmountOut + traderShare;
        IERC20(it.tokenOut).safeTransfer(it.recipient, traderGet);

        // 3) LP flow share
        if (lpShare > 0) {
            if (address(lpRebates) != address(0) && venueEnabled[address(lpRebates)]) {
                _safeApprove(IERC20(it.tokenOut), address(lpRebates), lpShare);

                if (hopShareBips.length > 0) {
                    if (hopShareBips.length != path.length - 1) revert InvalidHopShares();
                    uint256 total;
                    for (uint i; i < hopShareBips.length; i++) total += hopShareBips[i];
                    if (total != 10_000) revert BadSplit();

                    for (uint i; i < hopShareBips.length; i++) {
                        uint256 hopAmt = (lpShare * hopShareBips[i]) / 10_000;
                        if (hopAmt > 0) {
                            lpRebates.notify(path[i], path[i+1], it.tokenOut, hopAmt);
                            emit LPRebateAttributed(path[i], path[i+1], it.tokenOut, hopAmt);
                        }
                    }
                } else {
                    // attribute to final hop if not specified
                    lpRebates.notify(path[path.length-2], path[path.length-1], it.tokenOut, lpShare);
                    emit LPRebateAttributed(path[path.length-2], path[path.length-1], it.tokenOut, lpShare);
                }

                // Clear approval after use (defense-in-depth)
                SafeERC20.forceApprove(IERC20(it.tokenOut), address(lpRebates), 0);
            } else if (daoVault != address(0)) {
                // fallback: send to treasury if LP rebates venue is not set or paused
                IERC20(it.tokenOut).safeTransfer(daoVault, lpShare);
            }
        }

        // 4) locker share
        if (lockerShare > 0 && lockerVault != address(0)) {
            IERC20(it.tokenOut).safeTransfer(lockerVault, lockerShare);
        }

        // 5) analytics / reputation
        _awardReputation(it, surplus);

        emit PayflowExecuted(
            it.user, it.tokenIn, it.tokenOut, it.amountIn, it.minAmountOut, received,
            surplus, traderGet, lpShare, lockerShare, protocolCut, it.recipient
        );
    }

    // --- router call fanout ---
    function _routerSwapExactIn(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] memory path,
        uint256 deadline
    ) internal {
        // Router venue must be enabled
        if (!venueEnabled[address(router)]) revert VenuePaused();

        address r = address(router);
        (bool ok, ) = r.call(abi.encodeWithSelector(
            bytes4(keccak256("swapExactTokensForTokensSupportingFeeOnTransferTokens(uint256,uint256,address[],address,uint256,uint8)")),
            amountIn, amountOutMin, path, address(this), deadline, DEFAULT_AUTO_PREF
        ));
        if (ok) return;

        (ok, ) = r.call(abi.encodeWithSelector(
            bytes4(keccak256("swapExactTokensForTokens(uint256,uint256,address[],address,uint256,uint8)")),
            amountIn, amountOutMin, path, address(this), deadline, DEFAULT_AUTO_PREF
        ));
        if (ok) return;

        (ok, ) = r.call(abi.encodeWithSelector(
            bytes4(keccak256("swapExactTokensForTokens(uint256,uint256,address[],address,uint256)")),
            amountIn, amountOutMin, path, address(this), deadline
        ));
        if (ok) return;

        revert RouterSwapFailed();
    }

    /**
     * @dev Award reputation if operator enabled (tries valuer/bestExec safely).
     */
    function _awardReputation(IBestExec.SwapIntent calldata it, uint256 surplus) internal {
        if (address(repOp) == address(0) || !venueEnabled[address(repOp)]) return;
        uint256 usdVol = 0;
        uint256 usdSaved = 0;

        // Try to value in USD if a valuer is configured and enabled
        if (address(valuer) != address(0) && venueEnabled[address(valuer)]) {
            try valuer.usdValue(it.tokenIn, it.amountIn) returns (uint256 v) { usdVol = v; } catch {}
            if (surplus > 0) {
                try valuer.usdValue(it.tokenOut, surplus) returns (uint256 s) { usdSaved = s; } catch {}
            }
        }

        bytes32 intentId;
        // Safe hash even if bestExec disabled
        if (venueEnabled[address(bestExec)]) {
            try bestExec.hashIntent(it) returns (bytes32 h) { intentId = h; } catch {}
        }

        try repOp.onPayflowExecuted(it.user, usdVol, usdSaved, intentId) {} catch {}
    }

    // ---- helpers ----
    function _safeApprove(IERC20 t, address spender, uint256 needed) internal {
        // set exact allowance; forceApprove handles non-standard tokens by zeroing first if required
        SafeERC20.forceApprove(t, spender, needed);
    }

    // ---- rescues ----
    function sweep(address token, address to) external onlyOwner {
        if (to == address(0)) revert BadSplit();
        uint256 bal = IERC20(token).balanceOf(address(this));
        if (bal > 0) {
            IERC20(token).safeTransfer(to, bal);
        }
        emit Swept(token, to, bal); // Always emit (bal may be 0)
    }

    receive() external payable {}

    function sweepNative(address to) external onlyOwner {
        if (to == address(0)) revert BadSplit();
        uint256 bal = address(this).balance;
        if (bal > 0) {
            (bool ok, ) = to.call{value: bal}("");
            if (!ok) revert RouterSwapFailed();
        }
        emit NativeSwept(to, bal); // Always emit (bal may be 0)
    }
}
