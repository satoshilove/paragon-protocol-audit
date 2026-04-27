// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.25;
/*
 * Paragon Flow DEX — Core contracts
 * ParagonPayflowExecutorV2 — surplus split
 * (trader cashback + LP flow rebates + locker cut + optional protocol cut + relayer fee)
 *
 * Updated for external aggregator venue support via Paragon1inchAdapter.
 * Flow:
 * user -> Payflow -> Adapter -> 1inch Router -> Adapter -> Payflow -> _splitAndSettle
 *
 * Fixes applied (from the broken update):
 * - Fixed broken `address; route[...]` declarations in execute() and executeVia1inch()
 * - Fixed `_splitAndSettle` calls using `new uint16` → `new uint16[](0)`
 * - Ensured all original audited logic, security (reentrancy, pausable, venue toggles, split math, relayer fee deduction order, permit handling, reputation hooks, etc.) and events are 100% preserved
 * - Kept 1inch aggregator path clean and non-breaking
 */

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

import { IUsdValuer } from "../payflow/interfaces/IUsdValuer.sol";
import { ILPFlowRebates } from "../payflow/interfaces/ILPFlowRebates.sol";

/************************** Router Interface **************************/
interface IParagonRouterV2Like {
    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline,
        uint8 autoYieldPercent
    ) external;

    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline,
        uint8 autoYieldPercent
    ) external returns (uint256[] memory amounts);

    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts);
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

/************************** 1inch Types **************************/
interface I1inchRouterV6 {
    struct SwapDescription {
        IERC20 srcToken;
        IERC20 dstToken;
        address payable srcReceiver;
        address payable dstReceiver;
        uint256 amount;
        uint256 minReturnAmount;
        uint256 flags;
    }
}

/************************** Adapter Interface **************************/
interface IParagon1inchAdapter {
    function execute(
        address tokenIn,
        uint256 amountIn,
        address tokenOut,
        uint256 minAmountOut,
        I1inchRouterV6.SwapDescription calldata desc,
        bytes calldata permitData,
        bytes calldata oneInchData,
        address executor
    ) external returns (uint256 actualOut);
}

/************************** EXECUTOR V2 **************************/
contract ParagonPayflowExecutorV2 is Ownable, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;

    IParagonRouterV2Like public router;
    IBestExec public bestExec;
    IReputationOperator public repOp; // optional
    IUsdValuer public valuer; // optional
    address public daoVault; // protocol revenue (from surplus only)
    address public lockerVault; // recipient of locker-share (e.g., collector -> stXPGN)
    ILPFlowRebates public lpRebates; // sink for LP flow rewards

    // External aggregator venue
    address public oneInchAdapter;

    uint16 public protocolFeeBips; // e.g. 50 => 0.50% of surplus (launch at 0)

    uint16 public traderBips = 6000; // 60%
    uint16 public lpBips = 3000; // 30%

    uint16 public relayerFeeBips;
    uint16 public aggregatorFeeBips;
    uint16 public constant MAX_RELAYER_FEE_BPS = 10; // 10 bps = 0.10%
    uint16 public constant MAX_AGGREGATOR_FEE_BPS = 100; // 100 bps = 1.00%

    uint8 public constant MAX_PATH_LEN = 5;
    uint8 public constant DEFAULT_AUTO_PREF = 0;

    mapping(address => bool) public supportedToken;

    // Errors
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
    error AdapterNotSet();

    // Venue toggles
    mapping(address => bool) public venueEnabled;
    event VenueToggled(address indexed venue, bool enabled);

    function setVenueEnabled(address venue, bool enabled) external onlyOwner {
        require(venue != address(0), "venue=0");
        venueEnabled[venue] = enabled;
        emit VenueToggled(venue, enabled);
    }

    // Relayer allowlist
    mapping(address => bool) public isRelayer;
    event RelayerSet(address indexed relayer, bool allowed);

    function setRelayer(address relayer, bool allowed) external onlyOwner {
        require(relayer != address(0), "relayer=0");
        isRelayer[relayer] = allowed;
        emit RelayerSet(relayer, allowed);
    }

    // Supported tokens
    event SupportedTokenSet(address indexed token, bool supported);

    function setSupportedToken(address token, bool supported) external onlyOwner {
        require(token != address(0), "token=0");
        supportedToken[token] = supported;
        emit SupportedTokenSet(token, supported);
    }

    // Guardian
    event GuardianSet(address indexed guardian);
    address public guardian;

    modifier onlyOwnerOrGuardian() {
        require(msg.sender == owner() || msg.sender == guardian, "not owner/guardian");
        _;
    }

    function setGuardian(address g) external onlyOwner {
        guardian = g;
        emit GuardianSet(g);
    }

    // Events
    struct PermitData {
        uint256 value;
        uint256 deadline;
        uint8 v;
        bytes32 r;
        bytes32 s;
    }

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

    event LPRebateAttributed(
        address indexed tokenIn,
        address indexed tokenOut,
        address indexed rewardToken,
        uint256 amount
    );

    event SplitUpdated(uint16 traderBips, uint16 lpBips, uint16 lockerBips);
    event RelayerFeeUpdated(uint16 bps);
    event AggregatorFeeUpdated(uint16 bps);
    event AggregatorFeeTaken(address indexed tokenOut, uint256 amount);
    event RelayerPaid(address indexed relayer, uint256 amount);
    event ParamsUpdated(
        address router,
        address bestExec,
        address daoVault,
        address lpRebates,
        address lockerVault,
        uint16 protocolFeeBips
    );
    event PausedByOwner(address indexed owner, string reason);
    event UnpausedByOwner(address indexed owner);
    event ReputationOperatorSet(address indexed op);
    event UsdValuerSet(address indexed valuer);
    event Swept(address indexed token, address indexed to, uint256 amount);
    event NativeSwept(address indexed to, uint256 amount);
    event OneInchAdapterSet(address indexed adapter);

    constructor(
        address initialOwner,
        address _router,
        address _bestExec,
        address _daoVault,
        address _lpRebates,
        address _lockerVault
    ) Ownable(initialOwner) {
        if (_router == address(0) || _bestExec == address(0) || _daoVault == address(0)) revert BadSplit();

        router = IParagonRouterV2Like(_router);
        bestExec = IBestExec(_bestExec);
        daoVault = _daoVault;
        lpRebates = ILPFlowRebates(_lpRebates);
        lockerVault = _lockerVault;
        protocolFeeBips = 0;
        relayerFeeBips = 0;
        aggregatorFeeBips = 0;

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

    function pause(string calldata reason) external onlyOwnerOrGuardian {
        _pause();
        emit PausedByOwner(msg.sender, reason);
    }

    function unpause() external onlyOwner {
        _unpause();
        emit UnpausedByOwner(msg.sender);
    }

    function setParams(
        address _router,
        address _bestExec,
        address _daoVault,
        address _lpRebates,
        address _lockerVault,
        uint16 _protocolFeeBips
    ) external onlyOwner {
        if (_router == address(0) || _bestExec == address(0) || _daoVault == address(0)) revert BadSplit();
        if (_protocolFeeBips > 1000) revert BadSplit();

        router = IParagonRouterV2Like(_router);
        bestExec = IBestExec(_bestExec);
        daoVault = _daoVault;
        lpRebates = ILPFlowRebates(_lpRebates);
        lockerVault = _lockerVault;
        protocolFeeBips = _protocolFeeBips;

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

    function setSplitBips(uint16 _trader, uint16 _lp) external onlyOwner {
        traderBips = _trader;
        lpBips = _lp;
        _checkSplit();

        uint16 locker = uint16(10000 - _trader - _lp);
        emit SplitUpdated(_trader, _lp, locker);
    }

    function setRelayerFeeBips(uint16 bps) external onlyOwner {
        if (bps > MAX_RELAYER_FEE_BPS) revert BadSplit();
        relayerFeeBips = bps;
        emit RelayerFeeUpdated(bps);
    }

    function setAggregatorFeeBips(uint16 bps) external onlyOwner {
        if (bps > MAX_AGGREGATOR_FEE_BPS) revert BadSplit();
        aggregatorFeeBips = bps;
        emit AggregatorFeeUpdated(bps);
    }

    function _checkSplit() internal view {
        if (uint256(traderBips) + uint256(lpBips) > 10_000) revert BadSplit();
    }

    function setReputationOperator(address _repOp) external onlyOwner {
        repOp = IReputationOperator(_repOp);
        if (_repOp != address(0)) {
            venueEnabled[_repOp] = true;
            emit VenueToggled(_repOp, true);
        }
        emit ReputationOperatorSet(_repOp);
    }

    function setUsdValuer(address _valuer) external onlyOwner {
        valuer = IUsdValuer(_valuer);
        if (_valuer != address(0)) {
            venueEnabled[_valuer] = true;
            emit VenueToggled(_valuer, true);
        }
        emit UsdValuerSet(_valuer);
    }

    function setOneInchAdapter(address _adapter) external onlyOwner {
        require(_adapter != address(0), "adapter=0");
        oneInchAdapter = _adapter;
        venueEnabled[_adapter] = true;
        emit VenueToggled(_adapter, true);
        emit OneInchAdapterSet(_adapter);
    }

    // ----------------- EXECUTE (simple 2-hop path) -----------------
    function execute(
        IBestExec.SwapIntent calldata it,
        bytes calldata sig,
        PermitData calldata permit
    ) external nonReentrant whenNotPaused {
        if (!supportedToken[it.tokenIn] || !supportedToken[it.tokenOut]) revert UnsupportedToken();
        if (!venueEnabled[address(bestExec)]) revert VenuePaused();
        if (!venueEnabled[address(router)]) revert VenuePaused();
        if (block.timestamp > it.deadline) revert InvalidSwap();

        bestExec.consume(it, sig);

        if (it.tokenIn == it.tokenOut) revert InvalidSwap();
        if (it.recipient == address(0)) revert InvalidRecipient();
        if (it.amountIn == 0 || it.minAmountOut == 0) revert InvalidSwap();

        if (permit.deadline != 0) {
            try IERC20Permit(it.tokenIn).permit(
                it.user,
                address(this),
                permit.value,
                permit.deadline,
                permit.v,
                permit.r,
                permit.s
            ) {} catch {
                revert PermitFailed();
            }
        }

        uint256 inBefore = IERC20(it.tokenIn).balanceOf(address(this));
        IERC20(it.tokenIn).safeTransferFrom(it.user, address(this), it.amountIn);
        uint256 inReceived = IERC20(it.tokenIn).balanceOf(address(this)) - inBefore;
        if (inReceived == 0) revert InvalidSwap();

        _safeApprove(IERC20(it.tokenIn), address(router), inReceived);

        address[] memory route = new address[](2);
        route[0] = it.tokenIn;
        route[1] = it.tokenOut;

        uint256 balBefore = IERC20(it.tokenOut).balanceOf(address(this));
        _routerSwapExactIn(inReceived, it.minAmountOut, route, it.deadline);
        _safeApprove(IERC20(it.tokenIn), address(router), 0);

        uint256 received = IERC20(it.tokenOut).balanceOf(address(this)) - balBefore;
        if (received < it.minAmountOut) revert RouterSwapFailed();

        _splitAndSettle(it, route, received, new uint16[](0));
    }

    // ----------------- EXECUTE WITH PATH (+ optional per-hop attribution) -----------------
    function executeWithPath(
        IBestExec.SwapIntent calldata it,
        bytes calldata sig,
        address[] calldata path,
        uint16[] calldata hopShareBips,
        PermitData calldata permit
    ) external nonReentrant whenNotPaused {
        if (!venueEnabled[address(bestExec)]) revert VenuePaused();
        if (!venueEnabled[address(router)]) revert VenuePaused();

        if (path.length < 2 || path[0] != it.tokenIn || path[path.length - 1] != it.tokenOut) revert PathMismatch();
        if (path.length > MAX_PATH_LEN) revert PathTooLong();

        for (uint256 i = 0; i < path.length; i++) {
            if (!supportedToken[path[i]]) revert UnsupportedToken();
        }

        if (it.tokenIn == it.tokenOut) revert InvalidSwap();
        if (it.recipient == address(0)) revert InvalidRecipient();
        if (it.amountIn == 0 || it.minAmountOut == 0) revert InvalidSwap();
        if (block.timestamp > it.deadline) revert InvalidSwap();

        bestExec.consume(it, sig);

        if (permit.deadline != 0) {
            try IERC20Permit(it.tokenIn).permit(
                it.user,
                address(this),
                permit.value,
                permit.deadline,
                permit.v,
                permit.r,
                permit.s
            ) {} catch {
                revert PermitFailed();
            }
        }

        uint256 inBefore = IERC20(it.tokenIn).balanceOf(address(this));
        IERC20(it.tokenIn).safeTransferFrom(it.user, address(this), it.amountIn);
        uint256 inReceived = IERC20(it.tokenIn).balanceOf(address(this)) - inBefore;
        if (inReceived == 0) revert InvalidSwap();

        _safeApprove(IERC20(it.tokenIn), address(router), inReceived);

        uint256 balBefore = IERC20(it.tokenOut).balanceOf(address(this));
        _routerSwapExactIn(inReceived, it.minAmountOut, _toMemory(path), it.deadline);
        _safeApprove(IERC20(it.tokenIn), address(router), 0);

        uint256 received = IERC20(it.tokenOut).balanceOf(address(this)) - balBefore;
        if (received < it.minAmountOut) revert RouterSwapFailed();

        _splitAndSettle(it, _toMemory(path), received, _toMemory(hopShareBips));
    }

    // ----------------- EXECUTE VIA 1INCH ADAPTER -----------------
    function executeVia1inch(
        IBestExec.SwapIntent calldata it,
        bytes calldata sig,
        I1inchRouterV6.SwapDescription calldata desc,
        bytes calldata permitData,
        bytes calldata oneInchData,
        address executor,
        PermitData calldata userPermit
    ) external nonReentrant whenNotPaused {
        if (oneInchAdapter == address(0)) revert AdapterNotSet();
        if (!venueEnabled[address(bestExec)]) revert VenuePaused();
        if (!venueEnabled[oneInchAdapter]) revert VenuePaused();
        if (!supportedToken[it.tokenIn] || !supportedToken[it.tokenOut]) revert UnsupportedToken();

        if (block.timestamp > it.deadline) revert InvalidSwap();
        if (it.tokenIn == it.tokenOut) revert InvalidSwap();
        if (it.recipient == address(0)) revert InvalidRecipient();
        if (it.amountIn == 0 || it.minAmountOut == 0) revert InvalidSwap();

        bestExec.consume(it, sig);

        if (userPermit.deadline != 0) {
            try IERC20Permit(it.tokenIn).permit(
                it.user,
                address(this),
                userPermit.value,
                userPermit.deadline,
                userPermit.v,
                userPermit.r,
                userPermit.s
            ) {} catch {
                revert PermitFailed();
            }
        }

        uint256 inBefore = IERC20(it.tokenIn).balanceOf(address(this));
        IERC20(it.tokenIn).safeTransferFrom(it.user, address(this), it.amountIn);
        uint256 inReceived = IERC20(it.tokenIn).balanceOf(address(this)) - inBefore;
        if (inReceived == 0) revert InvalidSwap();

        // strict v1 adapter expects exact handoff == actual received
        IERC20(it.tokenIn).safeTransfer(oneInchAdapter, inReceived);

        uint256 received = IParagon1inchAdapter(oneInchAdapter).execute(
            it.tokenIn,
            inReceived,
            it.tokenOut,
            it.minAmountOut,
            desc,
            permitData,
            oneInchData,
            executor
        );

        uint256 aggregatorFee = aggregatorFeeBips > 0 ? (received * aggregatorFeeBips) / 10_000 : 0;
        uint256 settleAmount = received - aggregatorFee;

        if (settleAmount < it.minAmountOut) revert RouterSwapFailed();

        if (aggregatorFee > 0 && daoVault != address(0)) {
            IERC20(it.tokenOut).safeTransfer(daoVault, aggregatorFee);
            emit AggregatorFeeTaken(it.tokenOut, aggregatorFee);
        }

        address[] memory route = new address[](2);
        route[0] = it.tokenIn;
        route[1] = it.tokenOut;

        _splitAndSettle(it, route, settleAmount, new uint16[](0));
    }

    // --- internal: split + settle ---
    function _splitAndSettle(
        IBestExec.SwapIntent calldata it,
        address[] memory path,
        uint256 received,
        uint16[] memory hopShareBips
    ) internal {
        uint256 surplus = received > it.minAmountOut ? (received - it.minAmountOut) : 0;
        uint256 protocolCut = (surplus * protocolFeeBips) / 10_000;
        uint256 dist = surplus - protocolCut;
        uint256 traderShare = (dist * traderBips) / 10_000;
        uint256 lpShare = (dist * lpBips) / 10_000;
        uint256 lockerShare = dist - traderShare - lpShare;

        uint256 relayerFee;
        bool payRelayer =
            (relayerFeeBips > 0) &&
            (surplus > 0) &&
            (msg.sender != it.user) &&
            (isRelayer[msg.sender]);

        if (payRelayer) {
            uint256 requested = (surplus * relayerFeeBips) / 10_000;
            uint256 need = requested;
            uint256 take;

            take = protocolCut < need ? protocolCut : need;
            protocolCut -= take;
            need -= take;
            relayerFee += take;

            if (need > 0) {
                take = lpShare < need ? lpShare : need;
                lpShare -= take;
                need -= take;
                relayerFee += take;
            }

            if (need > 0) {
                take = lockerShare < need ? lockerShare : need;
                lockerShare -= take;
                need -= take;
                relayerFee += take;
            }

            if (need > 0) {
                uint256 traderGetHeadroom = traderShare;
                take = need > traderGetHeadroom ? traderGetHeadroom : need;
                traderShare -= take;
                need -= take;
                relayerFee += take;
            }
        }

        if (relayerFee > 0) {
            IERC20(it.tokenOut).safeTransfer(msg.sender, relayerFee);
            emit RelayerPaid(msg.sender, relayerFee);
        }

        if (protocolCut > 0 && daoVault != address(0)) {
            IERC20(it.tokenOut).safeTransfer(daoVault, protocolCut);
        }

        uint256 traderGet = it.minAmountOut + traderShare;
        IERC20(it.tokenOut).safeTransfer(it.recipient, traderGet);

        if (lpShare > 0) {
            if (address(lpRebates) != address(0) && venueEnabled[address(lpRebates)]) {
                _safeApprove(IERC20(it.tokenOut), address(lpRebates), lpShare);

                if (hopShareBips.length > 0) {
                    if (hopShareBips.length != path.length - 1) revert InvalidHopShares();

                    uint256 total;
                    for (uint256 i = 0; i < hopShareBips.length; i++) {
                        total += hopShareBips[i];
                    }
                    if (total != 10_000) revert BadSplit();

                    for (uint256 i = 0; i < hopShareBips.length; i++) {
                        uint256 hopAmt = (lpShare * hopShareBips[i]) / 10_000;
                        if (hopAmt > 0) {
                            lpRebates.notify(path[i], path[i + 1], it.tokenOut, hopAmt);
                            emit LPRebateAttributed(path[i], path[i + 1], it.tokenOut, hopAmt);
                        }
                    }
                } else {
                    lpRebates.notify(path[path.length - 2], path[path.length - 1], it.tokenOut, lpShare);
                    emit LPRebateAttributed(path[path.length - 2], path[path.length - 1], it.tokenOut, lpShare);
                }

                SafeERC20.forceApprove(IERC20(it.tokenOut), address(lpRebates), 0);
            } else if (daoVault != address(0)) {
                IERC20(it.tokenOut).safeTransfer(daoVault, lpShare);
            }
        }

        if (lockerShare > 0 && lockerVault != address(0)) {
            IERC20(it.tokenOut).safeTransfer(lockerVault, lockerShare);
        }

        _awardReputation(it, surplus);

        emit PayflowExecuted(
            it.user,
            it.tokenIn,
            it.tokenOut,
            it.amountIn,
            it.minAmountOut,
            received,
            surplus,
            traderGet,
            lpShare,
            lockerShare,
            protocolCut,
            it.recipient
        );
    }

    function _routerSwapExactIn(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] memory path,
        uint256 deadline
    ) internal {
        if (!venueEnabled[address(router)]) revert VenuePaused();

        address r = address(router);
        (bool ok,) = r.call(
            abi.encodeWithSelector(
                bytes4(
                    keccak256(
                        "swapExactTokensForTokensSupportingFeeOnTransferTokens(uint256,uint256,address[],address,uint256,uint8)"
                    )
                ),
                amountIn,
                amountOutMin,
                path,
                address(this),
                deadline,
                DEFAULT_AUTO_PREF
            )
        );
        if (ok) return;

        (ok,) = r.call(
            abi.encodeWithSelector(
                bytes4(
                    keccak256(
                        "swapExactTokensForTokens(uint256,uint256,address[],address,uint256,uint8)"
                    )
                ),
                amountIn,
                amountOutMin,
                path,
                address(this),
                deadline,
                DEFAULT_AUTO_PREF
            )
        );
        if (ok) return;

        (ok,) = r.call(
            abi.encodeWithSelector(
                bytes4(
                    keccak256(
                        "swapExactTokensForTokens(uint256,uint256,address[],address,uint256)"
                    )
                ),
                amountIn,
                amountOutMin,
                path,
                address(this),
                deadline
            )
        );
        if (ok) return;

        revert RouterSwapFailed();
    }

    function _awardReputation(IBestExec.SwapIntent calldata it, uint256 surplus) internal {
        if (address(repOp) == address(0) || !venueEnabled[address(repOp)]) return;

        uint256 usdVol = 0;
        uint256 usdSaved = 0;

        if (address(valuer) != address(0) && venueEnabled[address(valuer)]) {
            try valuer.usdValue(it.tokenIn, it.amountIn) returns (uint256 v) {
                usdVol = v;
            } catch {}

            if (surplus > 0) {
                try valuer.usdValue(it.tokenOut, surplus) returns (uint256 s) {
                    usdSaved = s;
                } catch {}
            }
        }

        bytes32 intentId;
        if (venueEnabled[address(bestExec)]) {
            try bestExec.hashIntent(it) returns (bytes32 h) {
                intentId = h;
            } catch {}
        }

        try repOp.onPayflowExecuted(it.user, usdVol, usdSaved, intentId) {} catch {}
    }

    function _safeApprove(IERC20 t, address spender, uint256 needed) internal {
        SafeERC20.forceApprove(t, spender, needed);
    }

    function sweep(address token, address to) external onlyOwner {
        if (to == address(0)) revert BadSplit();
        uint256 bal = IERC20(token).balanceOf(address(this));
        if (bal > 0) {
            IERC20(token).safeTransfer(to, bal);
        }
        emit Swept(token, to, bal);
    }

    receive() external payable {}

    function sweepNative(address to) external onlyOwner {
        if (to == address(0)) revert BadSplit();
        uint256 bal = address(this).balance;
        if (bal > 0) {
            (bool ok,) = to.call{value: bal}("");
            if (!ok) revert RouterSwapFailed();
        }
        emit NativeSwept(to, bal);
    }

    function _toMemory(address[] calldata arr) internal pure returns (address[] memory out) {
        out = new address[](arr.length);
        for (uint256 i = 0; i < arr.length; i++) {
            out[i] = arr[i];
        }
    }

    function _toMemory(uint16[] calldata arr) internal pure returns (uint16[] memory out) {
        out = new uint16[](arr.length);
        for (uint256 i = 0; i < arr.length; i++) {
            out[i] = arr[i];
        }
    }
}
