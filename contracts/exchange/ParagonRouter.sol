// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

import "./interfaces/IParagonFactory.sol";
import "./interfaces/IParagonPair.sol";
import "./interfaces/IParagonRouter.sol";
import "./interfaces/IWETH.sol";
import "./interfaces/IParagonFarmController.sol";
import "./libraries/ParagonLibrary.sol";
import "./ParagonRouterSwapHelper.sol";

interface IParagonOracle {
    function getAmountsOutUsingTwap(uint amountIn, address[] memory path, uint32 timeWindow)
        external view returns (uint[] memory amounts);
    function getAmountsOutUsingChainlink(uint amountIn, address[] memory path)
        external view returns (uint[] memory amounts);
}

contract ParagonRouter is IParagonRouter, Ownable, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ---------------------------------------------------------
    // Immutable config
    // ---------------------------------------------------------
    address public immutable override factory;
    address public immutable override WNative;
    IParagonFarmController public immutable masterChef;

    // ---------------------------------------------------------
    // Oracle guard (configurable)
    // ---------------------------------------------------------
    IParagonOracle public priceOracle;   // optional; set after deploy
    bool   public guardEnabled   = true; // global toggle
    bool   public useChainlink   = false;
    bool   public failOpen       = true; // ignore oracle errors if true
    uint16 public maxSlippageBips = 300; // 3%
    uint16 public maxImpactBips   = 300; // 3%
    mapping(address => bool) public protectedToken;

    // ---------------------------------------------------------
    // Auto-yield config (configurable)
    // ---------------------------------------------------------
    uint256 public autoYieldPid = 0;        // default PID for auto-yield deposits
    bool    public autoYieldEnabled = true; // global toggle

    // Per-user auto-yield preference (percent 0..3). 255 = use saved pref in swap calls.
    mapping(address => uint8) public userAutoYieldBips;
    uint8 private constant USE_SAVED_PREF = 255;

    // New event (NOT in interface) — safe to declare here
    event AutoYieldPreferenceSet(address indexed user, uint8 bips);

    constructor(address _factory, address _WNative, address _masterChef) Ownable(msg.sender) {
        require(_factory != address(0) && _WNative != address(0) && _masterChef != address(0), "Paragon: ZERO");
        factory   = _factory;
        WNative   = _WNative;
        masterChef = IParagonFarmController(_masterChef);
    }

    receive() external payable {
        require(msg.sender == WNative, "Paragon: NATIVE_ONLY_FROM_WNATIVE");
    }

    // ---------------------- Admin ----------------------
    function setOracle(address _oracle) external onlyOwner {
        priceOracle = IParagonOracle(_oracle);
        emit OracleUpdated(_oracle);
    }

    function setGuardParams(
        bool _enabled,
        bool _useChainlink,
        bool _failOpen,
        uint16 _maxSlippageBips,
        uint16 _maxImpactBips
    ) external onlyOwner {
        require(_maxSlippageBips <= 2000 && _maxImpactBips <= 2000, "Paragon: LIMITS_HIGH");
        guardEnabled     = _enabled;
        useChainlink     = _useChainlink;
        failOpen         = _failOpen;
        maxSlippageBips  = _maxSlippageBips;
        maxImpactBips    = _maxImpactBips;
        emit GuardParamsUpdated(_enabled, _useChainlink, _failOpen, _maxSlippageBips, _maxImpactBips);
    }

    function setProtectedToken(address token, bool isProtected) external onlyOwner {
        protectedToken[token] = isProtected;
        emit ProtectedTokenSet(token, isProtected);
    }

    // Configure which pool receives auto-yield deposits, and enable/disable globally
    function setAutoYieldConfig(uint256 _pid, bool _enabled) external onlyOwner {
        autoYieldPid = _pid;
        autoYieldEnabled = _enabled;
        emit AutoYieldConfigUpdated(_pid, _enabled);
    }

    // ---------------------- User pref API ----------------------
    function setAutoYieldPreference(uint8 bips) external {
        require(bips <= 3, "Paragon: PREF_TOO_HIGH");
        userAutoYieldBips[msg.sender] = bips;
        emit AutoYieldPreferenceSet(msg.sender, bips);
    }

    // ---------------------- Modifiers ----------------------
    modifier ensure(uint deadline) {
        require(block.timestamp <= deadline, "Paragon: EXPIRED");
        _;
    }

    // ---------------------- Internals ----------------------
    function _effectiveAutoYieldPercent(
        address msgSender,
        address to,
        uint8 autoYieldPercentParam
    ) internal view returns (uint8 p) {
        if (!autoYieldEnabled) return 0;

        // Explicit override 0..3 only valid when the receiver is the caller
        if (autoYieldPercentParam != USE_SAVED_PREF) {
            if (autoYieldPercentParam > 3) return 3;
            return (to == msgSender) ? autoYieldPercentParam : uint8(0);
        }

        // USE_SAVED_PREF (255): only honor if receiver is the caller
        if (to == msgSender) {
            uint8 saved = userAutoYieldBips[msgSender];
            return saved > 3 ? 3 : saved;
        }

        return 0;
    }

    function _handleAutoYield(address outToken, uint256 amountOut, address to, uint8 autoYieldPercent) internal {
        if (amountOut == 0) return;

        address xpgn = IParagonFactory(factory).xpgnToken();

        // If disabled, or not XPGN, or user set 0%, just transfer out
        if (!autoYieldEnabled || autoYieldPercent == 0 || xpgn == address(0) || outToken != xpgn) {
            IERC20(outToken).safeTransfer(to, amountOut);
            return;
        }

        // Cap at 3%
        if (autoYieldPercent > 3) autoYieldPercent = 3;

        uint256 yieldAmount = (amountOut * autoYieldPercent) / 100;
        if (yieldAmount == 0) { IERC20(xpgn).safeTransfer(to, amountOut); return; } // guard

        uint256 userAmount  = amountOut - yieldAmount;

        // Send user portion
        IERC20(xpgn).safeTransfer(to, userAmount);

        // Approve & deposit yield (best-effort)
        IERC20(xpgn).forceApprove(address(masterChef), 0);
        IERC20(xpgn).forceApprove(address(masterChef), yieldAmount);

        try masterChef.depositFor(autoYieldPid, yieldAmount, to, address(0)) {
            IERC20(xpgn).forceApprove(address(masterChef), 0);
            emit AutoYieldStaked(to, yieldAmount, autoYieldPercent);
        } catch {
            IERC20(xpgn).forceApprove(address(masterChef), 0);
            IERC20(xpgn).safeTransfer(to, yieldAmount);
            emit AutoYieldFailed(to, yieldAmount, autoYieldPercent);
        }
    }

    function _checkPath(address[] memory path) internal pure {
        uint len = path.length;
        require(len >= 2 && len <= 5, "Paragon: BAD_PATH");
        for (uint i = 0; i < len - 1; ++i) require(path[i] != path[i+1], "Paragon: IDENTICAL");
    }

    function _addLiquidity(
        address tokenA,
        address tokenB,
        uint amountADesired,
        uint amountBDesired,
        uint amountAMin,
        uint amountBMin
    ) internal returns (uint amountA, uint amountB) {
        if (IParagonFactory(factory).getPair(tokenA, tokenB) == address(0)) {
            IParagonFactory(factory).createPair(tokenA, tokenB);
        }
        (uint reserveA, uint reserveB, ) = ParagonLibrary.getReserves(factory, tokenA, tokenB);
        if (reserveA == 0 && reserveB == 0) {
            (amountA, amountB) = (amountADesired, amountBDesired);
        } else {
            uint amountBOptimal = ParagonLibrary.quote(amountADesired, reserveA, reserveB);
            if (amountBOptimal <= amountBDesired) {
                require(amountBOptimal >= amountBMin, "Paragon: INSUFF_B");
                (amountA, amountB) = (amountADesired, amountBOptimal);
            } else {
                uint amountAOptimal = ParagonLibrary.quote(amountBDesired, reserveB, reserveA);
                require(amountAOptimal >= amountAMin, "Paragon: INSUFF_A");
                (amountA, amountB) = (amountAOptimal, amountBDesired);
            }
        }
    }

    function _pathHasProtected(address[] memory path) internal view returns (bool) {
        for (uint i = 0; i < path.length; i++) {
            if (protectedToken[path[i]]) return true;
        }
        return false;
    }

    function _oracleMinOutMaybe(uint amountIn, address[] memory route) internal view returns (uint minOut, bool ok) {
        if (address(priceOracle) == address(0)) return (0, false);
        uint[] memory o;
        if (useChainlink) {
            try priceOracle.getAmountsOutUsingChainlink(amountIn, route) returns (uint[] memory arr) {
                o = arr;
            } catch { return (0, false); }
        } else {
            try priceOracle.getAmountsOutUsingTwap(amountIn, route, 0) returns (uint[] memory arr) {
                o = arr;
            } catch { return (0, false); }
        }
        if (o.length == 0) return (0, false);
        uint quoteOut = o[o.length - 1];
        if (quoteOut == 0) return (0, false);
        minOut = (quoteOut * (10000 - maxSlippageBips)) / 10000;
        ok = true;
    }

    function _impactBips(uint amountIn, address[] memory route, uint[] memory amts) internal view returns (uint16) {
        (uint rIn, uint rOut, ) = ParagonLibrary.getReserves(factory, route[0], route[1]);
        if (rIn == 0 || rOut == 0) return type(uint16).max;
        uint ideal = (amountIn * rOut) / rIn; // linear approx
        if (ideal == 0) return type(uint16).max;
        uint got = amts[1];
        if (got >= ideal) return 0;
        uint diff = ideal - got;
        uint bips = (diff * 10000) / ideal;
        if (bips > type(uint16).max) bips = type(uint16).max;
        return uint16(bips);
    }

    // ---------------------- View quoting ----------------------
    function quote(uint amountA, uint reserveA, uint reserveB)
        external pure override returns (uint amountB)
    { return ParagonLibrary.quote(amountA, reserveA, reserveB); }

    function getAmountOut(uint amountIn, uint reserveIn, uint reserveOut)
        external view override returns (uint amountOut)
    { return ParagonLibrary.getAmountOut(amountIn, reserveIn, reserveOut, IParagonFactory(factory).swapFeeBips()); }

    function getAmountIn(uint amountOut, uint reserveIn, uint reserveOut)
        external view override returns (uint amountIn)
    { return ParagonLibrary.getAmountIn(amountOut, reserveIn, reserveOut, IParagonFactory(factory).swapFeeBips()); }

    function getAmountsOut(uint amountIn, address[] calldata path)
        external view override returns (uint[] memory amts)
    { address[] memory r = path; _checkPath(r); return ParagonLibrary.getAmountsOut(factory, amountIn, r); }

    function getAmountsIn(uint amountOut, address[] calldata path)
        external view override returns (uint[] memory amts)
    { address[] memory r = path; _checkPath(r); return ParagonLibrary.getAmountsIn(factory, amountOut, r); }

    function getAmountOutFor(address tokenIn, address tokenOut, uint amountIn)
        external
        view
        returns (uint amountOut)
    {
        (uint112 rIn, uint112 rOut,) = ParagonLibrary.getReserves(factory, tokenIn, tokenOut);
        address pair = ParagonLibrary.pairFor(factory, tokenIn, tokenOut);
        uint32 fee = IParagonFactory(factory).getEffectiveSwapFeeBips(pair);
        return ParagonLibrary.getAmountOut(amountIn, rIn, rOut, fee);
    }

    function getAmountInFor(address tokenIn, address tokenOut, uint amountOut)
        external
        view
        returns (uint amountIn)
    {
        (uint112 rIn, uint112 rOut,) = ParagonLibrary.getReserves(factory, tokenIn, tokenOut);
        address pair = ParagonLibrary.pairFor(factory, tokenIn, tokenOut);
        uint32 fee = IParagonFactory(factory).getEffectiveSwapFeeBips(pair);
        return ParagonLibrary.getAmountIn(amountOut, rIn, rOut, fee);
    }

    // ---------------------- Add Liquidity ----------------------
    function addLiquidity(
        address tokenA,
        address tokenB,
        uint amountADesired,
        uint amountBDesired,
        uint amountAMin,
        uint amountBMin,
        address to,
        uint deadline
    )
        external override ensure(deadline) whenNotPaused nonReentrant
        returns (uint amountA, uint amountB, uint liquidity)
    {
        (amountA, amountB) = _addLiquidity(tokenA, tokenB, amountADesired, amountBDesired, amountAMin, amountBMin);
        address pair = ParagonLibrary.pairFor(factory, tokenA, tokenB);
        IERC20(tokenA).safeTransferFrom(msg.sender, pair, amountA);
        IERC20(tokenB).safeTransferFrom(msg.sender, pair, amountB);
        liquidity = IParagonPair(pair).mint(to);
    }

    function addLiquidityNative(
        address token,
        uint amountTokenDesired,
        uint amountTokenMin,
        uint amountNativeMin,
        address to,
        uint deadline
    )
        external payable override ensure(deadline) whenNotPaused nonReentrant
        returns (uint amountToken, uint amountNative, uint liquidity)
    {
        (amountToken, amountNative) = _addLiquidity(token, WNative, amountTokenDesired, msg.value, amountTokenMin, amountNativeMin);
        address pair = ParagonLibrary.pairFor(factory, token, WNative);
        IERC20(token).safeTransferFrom(msg.sender, pair, amountToken);
        IWETH(WNative).deposit{value: amountNative}();
        assert(IWETH(WNative).transfer(pair, amountNative));
        liquidity = IParagonPair(pair).mint(to);
        if (msg.value > amountNative) {
            (bool refundOk, ) = msg.sender.call{value: msg.value - amountNative}("");
            require(refundOk, "Paragon: REFUND_FAIL");
        }
    }

    // ---------------------- Remove Liquidity ----------------------
    function removeLiquidity(
        address tokenA,
        address tokenB,
        uint liquidity,
        uint amountAMin,
        uint amountBMin,
        address to,
        uint deadline
    )
        public override ensure(deadline) whenNotPaused nonReentrant
        returns (uint amountA, uint amountB)
    {
        address pair = ParagonLibrary.pairFor(factory, tokenA, tokenB);
        IERC20(pair).safeTransferFrom(msg.sender, pair, liquidity);
        (uint amount0, uint amount1) = IParagonPair(pair).burn(to);
        (address token0,) = ParagonLibrary.sortTokens(tokenA, tokenB);
        (amountA, amountB) = tokenA == token0 ? (amount0, amount1) : (amount1, amount0);
        require(amountA >= amountAMin, "Paragon: INSUFF_A");
        require(amountB >= amountBMin, "Paragon: INSUFF_B");
    }

    function removeLiquidityNative(
        address token,
        uint liquidity,
        uint amountTokenMin,
        uint amountNativeMin,
        address to,
        uint deadline
    )
        public override ensure(deadline) whenNotPaused nonReentrant
        returns (uint amountToken, uint amountNative)
    {
        address pair = ParagonLibrary.pairFor(factory, token, WNative);
        IERC20(pair).safeTransferFrom(msg.sender, pair, liquidity);
        (uint amount0, uint amount1) = IParagonPair(pair).burn(address(this));
        (address token0,) = ParagonLibrary.sortTokens(token, WNative);
        (uint outToken, uint outWNative) = token == token0 ? (amount0, amount1) : (amount1, amount0);
        require(outToken >= amountTokenMin, "Paragon: INSUFF_TOKEN");
        require(outWNative >= amountNativeMin, "Paragon: INSUFF_NATIVE");
        IERC20(token).safeTransfer(to, outToken);
        IWETH(WNative).withdraw(outWNative);
        (bool sendOk, ) = to.call{value: outWNative}("");
        require(sendOk, "Paragon: NATIVE_SEND_FAIL");
        return (outToken, outWNative);
    }

    function removeLiquidityWithPermit(
        address tokenA,
        address tokenB,
        uint liquidity,
        uint amountAMin,
        uint amountBMin,
        address to,
        uint deadline,
        bool approveMax,
        uint8 v, bytes32 r, bytes32 s
    )
        external override
        returns (uint amountA, uint amountB)
    {
        address pair = ParagonLibrary.pairFor(factory, tokenA, tokenB);
        uint value = approveMax ? type(uint).max : liquidity;
        IERC20Permit(pair).permit(msg.sender, address(this), value, deadline, v, r, s);
        (amountA, amountB) = removeLiquidity(tokenA, tokenB, liquidity, amountAMin, amountBMin, to, deadline);
    }

    function removeLiquidityNativeWithPermit(
        address token,
        uint liquidity,
        uint amountTokenMin,
        uint amountNativeMin,
        address to,
        uint deadline,
        bool approveMax,
        uint8 v, bytes32 r, bytes32 s
    )
        external override
        returns (uint amountToken, uint amountNative)
    {
        address pair = ParagonLibrary.pairFor(factory, token, WNative);
        uint value = approveMax ? type(uint).max : liquidity;
        IERC20Permit(pair).permit(msg.sender, address(this), value, deadline, v, r, s);
        // ✅ Avoid shadowing return variables: return directly
        return removeLiquidityNative(token, liquidity, amountTokenMin, amountNativeMin, to, deadline);
    }

    // ---------------------- Swaps (exact-in/out) ----------------------
    function swapExactTokensForTokens(
        uint amountIn,
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline,
        uint8 autoYieldPercent
    )
        external override ensure(deadline) whenNotPaused nonReentrant
        returns (uint[] memory amts)
    {
        address[] memory r = path;
        _checkPath(r);
        amts = ParagonLibrary.getAmountsOut(factory, amountIn, r);

        if (guardEnabled && _pathHasProtected(r)) {
            (uint minOut, bool oracleOk) = _oracleMinOutMaybe(amountIn, r);
            if (failOpen) { if (oracleOk && minOut > 0) require(amts[amts.length - 1] >= minOut, "Paragon: ORACLE_SLIPPAGE"); }
            else { require(oracleOk && minOut > 0, "Paragon: ORACLE_FAIL"); require(amts[amts.length - 1] >= minOut, "Paragon: ORACLE_SLIPPAGE"); }
            uint16 impact = _impactBips(amountIn, r, amts);
            require(impact <= maxImpactBips, "Paragon: PRICE_IMPACT");
        }

        require(amts[amts.length - 1] >= amountOutMin, "Paragon: INSUFF_OUTPUT");
        IERC20(r[0]).safeTransferFrom(msg.sender, ParagonLibrary.pairFor(factory, r[0], r[1]), amts[0]);
        ParagonRouterSwapHelper.swap(amts, r, factory, address(this));

        uint8 eff = _effectiveAutoYieldPercent(msg.sender, to, autoYieldPercent);
        _handleAutoYield(r[r.length - 1], amts[amts.length - 1], to, eff);
    }

    function swapTokensForExactTokens(
        uint amountOut,
        uint amountInMax,
        address[] calldata path,
        address to,
        uint deadline
    )
        external override ensure(deadline) whenNotPaused nonReentrant
        returns (uint[] memory amts)
    {
        address[] memory r = path;
        _checkPath(r);
        amts = ParagonLibrary.getAmountsIn(factory, amountOut, r);
        require(amts[0] <= amountInMax, "Paragon: EXCESSIVE_INPUT");
        IERC20(r[0]).safeTransferFrom(msg.sender, ParagonLibrary.pairFor(factory, r[0], r[1]), amts[0]);
        ParagonRouterSwapHelper.swap(amts, r, factory, to);
    }

    function swapExactNativeForTokens(
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline,
        uint8 autoYieldPercent
    )
        external payable override ensure(deadline) whenNotPaused nonReentrant
        returns (uint[] memory amts)
    {
        require(path[0] == WNative, "Paragon: PATH_START_WNATIVE");
        address[] memory r = path;
        _checkPath(r);
        amts = ParagonLibrary.getAmountsOut(factory, msg.value, r);

        if (guardEnabled && _pathHasProtected(r)) {
            (uint minOut, bool oracleOk) = _oracleMinOutMaybe(msg.value, r);
            if (failOpen) { if (oracleOk && minOut > 0) require(amts[amts.length - 1] >= minOut, "Paragon: ORACLE_SLIPPAGE"); }
            else { require(oracleOk && minOut > 0, "Paragon: ORACLE_FAIL"); require(amts[amts.length - 1] >= minOut, "Paragon: ORACLE_SLIPPAGE"); }
            uint16 impact = _impactBips(msg.value, r, amts);
            require(impact <= maxImpactBips, "Paragon: PRICE_IMPACT");
        }

        require(amts[amts.length - 1] >= amountOutMin, "Paragon: INSUFF_OUTPUT");
        IWETH(WNative).deposit{value: amts[0]}();
        assert(IWETH(WNative).transfer(ParagonLibrary.pairFor(factory, r[0], r[1]), amts[0]));
        ParagonRouterSwapHelper.swap(amts, r, factory, address(this));

        uint8 eff = _effectiveAutoYieldPercent(msg.sender, to, autoYieldPercent);
        _handleAutoYield(r[r.length - 1], amts[amts.length - 1], to, eff);

        if (msg.value > amts[0]) {
            (bool refundOk, ) = msg.sender.call{value: msg.value - amts[0]}("");
            require(refundOk, "Paragon: REFUND_FAIL");
        }
    }

    function swapTokensForExactNative(
        uint amountOut,
        uint amountInMax,
        address[] calldata path,
        address to,
        uint deadline
    )
        external override ensure(deadline) whenNotPaused nonReentrant
        returns (uint[] memory amts)
    {
        require(path[path.length - 1] == WNative, "Paragon: PATH_END_WNATIVE");
        address[] memory r = path;
        _checkPath(r);
        amts = ParagonLibrary.getAmountsIn(factory, amountOut, r);
        require(amts[0] <= amountInMax, "Paragon: EXCESSIVE_INPUT");
        IERC20(r[0]).safeTransferFrom(msg.sender, ParagonLibrary.pairFor(factory, r[0], r[1]), amts[0]);
        ParagonRouterSwapHelper.swap(amts, r, factory, address(this));
        IWETH(WNative).withdraw(amts[amts.length - 1]);
        (bool sendOk, ) = to.call{value: amts[amts.length - 1]}("");
        require(sendOk, "Paragon: NATIVE_SEND_FAIL");
    }

    function swapNativeForExactTokens(
        uint amountOut,
        address[] calldata path,
        address to,
        uint deadline
    )
        external payable override ensure(deadline) whenNotPaused nonReentrant
        returns (uint[] memory amts)
    {
        require(path[0] == WNative, "Paragon: PATH_START_WNATIVE");
        address[] memory r = path;
        _checkPath(r);
        amts = ParagonLibrary.getAmountsIn(factory, amountOut, r);
        require(amts[0] <= msg.value, "Paragon: EXCESSIVE_INPUT");
        IWETH(WNative).deposit{value: amts[0]}();
        assert(IWETH(WNative).transfer(ParagonLibrary.pairFor(factory, r[0], r[1]), amts[0]));
        ParagonRouterSwapHelper.swap(amts, r, factory, to);
        if (msg.value > amts[0]) {
            (bool refundOk, ) = msg.sender.call{value: msg.value - amts[0]}("");
            require(refundOk, "Paragon: REFUND_FAIL");
        }
    }

    // ---------------------- FOT Support (exact-in) ----------------------
    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        uint amountIn,
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline,
        uint8 autoYieldPercent
    )
        external override ensure(deadline) whenNotPaused nonReentrant
        returns (uint outAmt)
    {
        address[] memory r = path;
        _checkPath(r);

        IERC20(r[0]).safeTransferFrom(msg.sender, ParagonLibrary.pairFor(factory, r[0], r[1]), amountIn);

        address outToken = r[r.length - 1];
        uint256 beforeBal = IERC20(outToken).balanceOf(address(this));

        ParagonRouterSwapHelper.swapSupportingFeeOnTransferTokens(r, factory, address(this));

        outAmt = IERC20(outToken).balanceOf(address(this)) - beforeBal;

        if (guardEnabled && _pathHasProtected(r)) {
            (uint minOut, bool oracleOk) = _oracleMinOutMaybe(amountIn, r);
            if (failOpen) { if (oracleOk && minOut > 0) require(outAmt >= minOut, "Paragon: ORACLE_SLIPPAGE"); }
            else { require(oracleOk && minOut > 0, "Paragon: ORACLE_FAIL"); require(outAmt >= minOut, "Paragon: ORACLE_SLIPPAGE"); }
            uint[] memory amtsChk = ParagonLibrary.getAmountsOut(factory, amountIn, r);
            uint16 impact = _impactBips(amountIn, r, amtsChk);
            require(impact <= maxImpactBips, "Paragon: PRICE_IMPACT");
        }

        require(outAmt >= amountOutMin, "Paragon: INSUFF_OUTPUT");

        uint8 eff = _effectiveAutoYieldPercent(msg.sender, to, autoYieldPercent);
        _handleAutoYield(outToken, outAmt, to, eff);
    }

    function swapExactNativeForTokensSupportingFeeOnTransferTokens(
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline,
        uint8 autoYieldPercent
    )
        external payable override ensure(deadline) whenNotPaused nonReentrant
        returns (uint outAmt)
    {
        require(path[0] == WNative, "Paragon: PATH_START_WNATIVE");
        address[] memory r = path;
        _checkPath(r);

        IWETH(WNative).deposit{value: msg.value}();
        assert(IWETH(WNative).transfer(ParagonLibrary.pairFor(factory, r[0], r[1]), msg.value));

        address outToken = r[r.length - 1];
        uint256 beforeBal = IERC20(outToken).balanceOf(address(this));

        ParagonRouterSwapHelper.swapSupportingFeeOnTransferTokens(r, factory, address(this));

        outAmt = IERC20(outToken).balanceOf(address(this)) - beforeBal;

        if (guardEnabled && _pathHasProtected(r)) {
            (uint minOut, bool oracleOk) = _oracleMinOutMaybe(msg.value, r);
            if (failOpen) { if (oracleOk && minOut > 0) require(outAmt >= minOut, "Paragon: ORACLE_SLIPPAGE"); }
            else { require(oracleOk && minOut > 0, "Paragon: ORACLE_FAIL"); require(outAmt >= minOut, "Paragon: ORACLE_SLIPPAGE"); }
            uint[] memory amtsChk = ParagonLibrary.getAmountsOut(factory, msg.value, r);
            uint16 impact = _impactBips(msg.value, r, amtsChk);
            require(impact <= maxImpactBips, "Paragon: PRICE_IMPACT");
        }

        require(outAmt >= amountOutMin, "Paragon: INSUFF_OUTPUT");

        uint8 eff = _effectiveAutoYieldPercent(msg.sender, to, autoYieldPercent);
        _handleAutoYield(outToken, outAmt, to, eff);
    }

    function swapExactTokensForNativeSupportingFeeOnTransferTokens(
        uint amountIn,
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    )
        external override ensure(deadline) whenNotPaused nonReentrant
        returns (uint outAmt)
    {
        require(path[path.length - 1] == WNative, "Paragon: PATH_END_WNATIVE");

        address[] memory r = path;
        _checkPath(r);

        IERC20(r[0]).safeTransferFrom(msg.sender, ParagonLibrary.pairFor(factory, r[0], r[1]), amountIn);

        uint256 beforeBal = IERC20(WNative).balanceOf(address(this));
        ParagonRouterSwapHelper.swapSupportingFeeOnTransferTokens(r, factory, address(this));
        uint256 wReceived = IERC20(WNative).balanceOf(address(this)) - beforeBal;

        if (guardEnabled && _pathHasProtected(r)) {
            (uint minOut, bool oracleOk) = _oracleMinOutMaybe(amountIn, r);
            if (failOpen) { if (oracleOk && minOut > 0) require(wReceived >= minOut, "Paragon: ORACLE_SLIPPAGE"); }
            else { require(oracleOk && minOut > 0, "Paragon: ORACLE_FAIL"); require(wReceived >= minOut, "Paragon: ORACLE_SLIPPAGE"); }
            uint[] memory amtsChk = ParagonLibrary.getAmountsOut(factory, amountIn, r);
            uint16 impact = _impactBips(amountIn, r, amtsChk);
            require(impact <= maxImpactBips, "Paragon: PRICE_IMPACT");
        }

        require(wReceived >= amountOutMin, "Paragon: INSUFF_OUTPUT");
        IWETH(WNative).withdraw(wReceived);
        (bool sendOk, ) = to.call{value: wReceived}("");
        require(sendOk, "Paragon: NATIVE_SEND_FAIL");

        outAmt = wReceived;
    }

    // ---------------------- Admin: pause/rescue ----------------------
    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }

    function rescueTokens(address token, address to) external onlyOwner {
        if (token == address(0)) {
            (bool sendOk, ) = to.call{value: address(this).balance}("");
            require(sendOk, "Paragon: NATIVE_SEND_FAIL");
        } else {
            IERC20(token).safeTransfer(to, IERC20(token).balanceOf(address(this)));
        }
    }
}
