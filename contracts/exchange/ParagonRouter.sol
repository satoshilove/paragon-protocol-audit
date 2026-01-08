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
        external
        view
        returns (uint[] memory amounts);

    function getAmountsOutUsingChainlink(uint amountIn, address[] memory path)
        external
        view
        returns (uint[] memory amounts);
}

/// @dev Router-admin policy module the Router can read from (whitelist + UI helpers + tolerances).
interface IParagonRouterAdmin {
    function whitelistEnabled() external view returns (bool);
    function whitelist(address) external view returns (bool);
    function feeOnTransferTolerance() external view returns (uint32);
}

/// @dev minimal paused() interface for XPGN kill-switch
interface IPausableToken {
    function paused() external view returns (bool);
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
    // RouterAdmin policy module (optional)
    // ---------------------------------------------------------
    IParagonRouterAdmin public admin;

    // ---------------------------------------------------------
    // Oracle guard (configurable)
    // ---------------------------------------------------------
    IParagonOracle public priceOracle; // optional; set after deploy

    bool   public guardEnabled    = true;   // global toggle
    bool   public useChainlink    = false;
    bool   public failOpen        = false;  // fail-closed by default
    uint16 public maxSlippageBips = 50;     // 0.5%
    uint16 public maxImpactBips   = 100;    // 1.0%

    mapping(address => bool) public protectedToken;

    // ---------------------------------------------------------
    // Auto-yield config (configurable)
    // ---------------------------------------------------------
    uint256 public autoYieldPid = 0;
    bool    public autoYieldEnabled = true;

    // Per-user auto-yield preference (percent 0..3). 255 = use saved pref in swap calls.
    mapping(address => uint8) public userAutoYieldBips;
    uint8 private constant USE_SAVED_PREF = 255;

    // ---------------------------------------------------------
    // Events
    // ---------------------------------------------------------
    event AdminUpdated(address indexed admin);
    event AutoYieldPreferenceSet(address indexed user, uint8 bips);

    constructor(address _factory, address _WNative, address _masterChef) Ownable(msg.sender) {
        require(_factory != address(0) && _WNative != address(0) && _masterChef != address(0), "Paragon: ZERO");
        factory    = _factory;
        WNative    = _WNative;
        masterChef = IParagonFarmController(_masterChef);
    }

    receive() external payable {
        require(msg.sender == WNative, "Paragon: NATIVE_ONLY_FROM_WNATIVE");
    }

    // ---------------------- Admin ----------------------
    function setAdmin(address _admin) external onlyOwner {
        admin = IParagonRouterAdmin(_admin);
        emit AdminUpdated(_admin);
    }

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

    // ---------------------- Policy checks (whitelist + XPGN pause) ----------------------
    function _enforceWhitelist() internal view {
        if (address(admin) == address(0)) return;
        if (admin.whitelistEnabled()) {
            require(admin.whitelist(msg.sender), "Paragon: NOT_WHITELISTED");
        }
    }

    function _enforceXpgnNotPaused(address[] memory path) internal view {
        address xpgn = IParagonFactory(factory).xpgnToken();
        if (xpgn == address(0)) return;

        for (uint i = 0; i < path.length; ++i) {
            if (path[i] == xpgn) {
                require(!IPausableToken(xpgn).paused(), "Paragon: XPGN_PAUSED");
                return;
            }
        }
    }

    function _fotToleranceBips() internal view returns (uint32) {
        if (address(admin) == address(0)) return 0;
        return admin.feeOnTransferTolerance();
    }

    function _enforceFOTTolerance(uint256 expectedIn, uint256 actualIn) internal view {
        uint32 tol = _fotToleranceBips();
        if (tol == 0) return;
        require(actualIn * 10000 >= expectedIn * (10000 - uint256(tol)), "Paragon: FOT_TOO_HIGH");
    }

    // ---------------------- Internals (auto-yield) ----------------------
    function _effectiveAutoYieldPercent(
        address msgSender,
        address to,
        uint8 autoYieldPercentParam
    ) internal view returns (uint8) {
        if (!autoYieldEnabled) return 0;

        if (autoYieldPercentParam != USE_SAVED_PREF) {
            if (autoYieldPercentParam > 3) return 3;
            return (to == msgSender) ? autoYieldPercentParam : 0;
        }

        if (to == msgSender) {
            uint8 saved = userAutoYieldBips[msgSender];
            return saved > 3 ? 3 : saved;
        }

        return 0;
    }

    function _isXPGN(address token) internal view returns (bool) {
        address xpgn = IParagonFactory(factory).xpgnToken();
        return xpgn != address(0) && token == xpgn;
    }

    function _shouldCustodyForAutoYield(address outToken, uint8 eff) internal view returns (bool) {
        return autoYieldEnabled && eff > 0 && _isXPGN(outToken);
    }

    function _minGrossOutForNet(uint256 amountOutMinNet, uint8 eff) internal pure returns (uint256) {
        if (eff == 0) return amountOutMinNet;
        uint8 cappedEff = eff > 3 ? 3 : eff;
        uint256 denom = 100 - cappedEff;
        return (amountOutMinNet * 100 + (denom - 1)) / denom;
    }

    function _handleAutoYield(address outToken, uint256 amountOut, address to, uint8 autoYieldPercent) internal {
        if (amountOut == 0) return;

        address xpgn = IParagonFactory(factory).xpgnToken();

        if (!autoYieldEnabled || autoYieldPercent == 0 || xpgn == address(0) || outToken != xpgn) {
            IERC20(outToken).safeTransfer(to, amountOut);
            return;
        }

        uint8 eff = autoYieldPercent > 3 ? 3 : autoYieldPercent;

        uint256 yieldAmount = (amountOut * eff) / 100;
        if (yieldAmount == 0) {
            IERC20(xpgn).safeTransfer(to, amountOut);
            return;
        }

        uint256 userAmount = amountOut - yieldAmount;

        IERC20(xpgn).safeTransfer(to, userAmount);

        IERC20(xpgn).forceApprove(address(masterChef), 0);
        IERC20(xpgn).forceApprove(address(masterChef), yieldAmount);

        try masterChef.depositFor(autoYieldPid, yieldAmount, to, address(0)) {
            IERC20(xpgn).forceApprove(address(masterChef), 0);
            emit AutoYieldStaked(to, yieldAmount, eff);
        } catch {
            IERC20(xpgn).forceApprove(address(masterChef), 0);
            IERC20(xpgn).safeTransfer(to, yieldAmount);
            emit AutoYieldFailed(to, yieldAmount, eff);
        }
    }

    // ---------------------- Internals (liquidity & path) ----------------------
    function _checkPath(address[] memory path) internal pure {
        uint len = path.length;
        require(len >= 2 && len <= 5, "Paragon: BAD_PATH");
        for (uint i = 0; i < len - 1; ++i) require(path[i] != path[i + 1], "Paragon: IDENTICAL");
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
            } catch {
                return (0, false);
            }
        } else {
            try priceOracle.getAmountsOutUsingTwap(amountIn, route, 0) returns (uint[] memory arr) {
                o = arr;
            } catch {
                return (0, false);
            }
        }

        if (o.length == 0) return (0, false);

        uint quoteOut = o[o.length - 1];
        if (quoteOut == 0) return (0, false);

        minOut = (quoteOut * (10000 - maxSlippageBips)) / 10000;
        ok = true;
    }

    function _impactBips(uint /*amountIn*/, address[] memory route, uint[] memory amounts) internal view returns (uint16) {
        uint16 maxBips = 0;

        for (uint i = 0; i < route.length - 1; i++) {
            if (!(protectedToken[route[i]] || protectedToken[route[i + 1]])) continue;

            (uint rIn, uint rOut, ) = ParagonLibrary.getReserves(factory, route[i], route[i + 1]);
            if (rIn == 0 || rOut == 0) return type(uint16).max;

            uint hopIn = amounts[i];
            if (hopIn == 0) return type(uint16).max;

            uint ideal = (hopIn * rOut) / rIn;
            if (ideal == 0) return type(uint16).max;

            uint got = amounts[i + 1];
            if (got >= ideal) continue;

            uint diff = ideal - got;
            uint bips = (diff * 10000) / ideal;
            if (bips > type(uint16).max) bips = type(uint16).max;

            if (bips > maxBips) maxBips = uint16(bips);
        }

        return maxBips;
    }

    function _enforceOracleGuard(
        uint256 amountIn,
        address[] memory path,
        uint256 amountOut
    ) internal {
        if (!guardEnabled || !_pathHasProtected(path)) return;

        (uint256 minOut, bool oracleOk) = _oracleMinOutMaybe(amountIn, path);

        if (failOpen) {
            if (oracleOk && minOut > 0) {
                require(amountOut >= minOut, "Paragon: ORACLE_SLIPPAGE");
            }
        } else {
            require(oracleOk && minOut > 0, "Paragon: ORACLE_FAIL");
            require(amountOut >= minOut, "Paragon: ORACLE_SLIPPAGE");
        }

        uint256[] memory amountsCalc = ParagonLibrary.getAmountsOut(factory, amountIn, path);
        uint16 impact = _impactBips(amountIn, path, amountsCalc);
        require(impact <= maxImpactBips, "Paragon: PRICE_IMPACT");
    }

    function _enforceOracleGuardPostSwap(
        uint256 effectiveIn,
        address[] memory path,
        uint256 actualOut
    ) internal {
        if (!guardEnabled || !_pathHasProtected(path)) return;

        (uint256 minOut, bool oracleOk) = _oracleMinOutMaybe(effectiveIn, path);

        if (failOpen) {
            if (oracleOk && minOut > 0) {
                require(actualOut >= minOut, "Paragon: ORACLE_SLIPPAGE");
            }
        } else {
            require(oracleOk && minOut > 0, "Paragon: ORACLE_FAIL");
            require(actualOut >= minOut, "Paragon: ORACLE_SLIPPAGE");
        }

        uint256[] memory amountsCalc = ParagonLibrary.getAmountsOut(factory, effectiveIn, path);
        uint16 impact = _impactBips(effectiveIn, path, amountsCalc);
        require(impact <= maxImpactBips, "Paragon: PRICE_IMPACT");
    }

    // ---------------------- View quoting ----------------------
    function quote(uint amountA, uint reserveA, uint reserveB)
        external
        pure
        override
        returns (uint amountB)
    {
        return ParagonLibrary.quote(amountA, reserveA, reserveB);
    }

    function getAmountOut(uint amountIn, uint reserveIn, uint reserveOut)
        external
        view
        override
        returns (uint amountOut)
    {
        return ParagonLibrary.getAmountOut(
            amountIn,
            reserveIn,
            reserveOut,
            IParagonFactory(factory).swapFeeBips()
        );
    }

    function getAmountIn(uint amountOut, uint reserveIn, uint reserveOut)
        external
        view
        override
        returns (uint amountIn)
    {
        return ParagonLibrary.getAmountIn(
            amountOut,
            reserveIn,
            reserveOut,
            IParagonFactory(factory).swapFeeBips()
        );
    }

    function getAmountsOut(uint amountIn, address[] calldata path)
        external
        view
        override
        returns (uint[] memory amounts)
    {
        address[] memory r = path;
        _checkPath(r);
        return ParagonLibrary.getAmountsOut(factory, amountIn, r);
    }

    function getAmountsIn(uint amountOut, address[] calldata path)
        external
        view
        override
        returns (uint[] memory amounts)
    {
        address[] memory r = path;
        _checkPath(r);
        return ParagonLibrary.getAmountsIn(factory, amountOut, r);
    }

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
        external
        override
        ensure(deadline)
        whenNotPaused
        nonReentrant
        returns (uint amountA, uint amountB, uint liquidity)
    {
        _enforceWhitelist();

        address[] memory path = new address[](2);
        path[0] = tokenA;
        path[1] = tokenB;
        _enforceXpgnNotPaused(path);

        (amountA, amountB) = _addLiquidity(
            tokenA,
            tokenB,
            amountADesired,
            amountBDesired,
            amountAMin,
            amountBMin
        );
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
        external
        payable
        override
        ensure(deadline)
        whenNotPaused
        nonReentrant
        returns (uint amountToken, uint amountNative, uint liquidity)
    {
        _enforceWhitelist();

        address[] memory path = new address[](2);
        path[0] = token;
        path[1] = WNative;
        _enforceXpgnNotPaused(path);

        (amountToken, amountNative) = _addLiquidity(
            token,
            WNative,
            amountTokenDesired,
            msg.value,
            amountTokenMin,
            amountNativeMin
        );
        address pair = ParagonLibrary.pairFor(factory, token, WNative);
        IERC20(token).safeTransferFrom(msg.sender, pair, amountToken);
        IWETH(WNative).deposit{value: amountNative}();
        assert(IWETH(WNative).transfer(pair, amountNative));
        liquidity = IParagonPair(pair).mint(to);

        if (msg.value > amountNative) {
            (bool success, ) = msg.sender.call{value: msg.value - amountNative}("");
            require(success, "Paragon: REFUND_FAIL");
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
        public
        override
        ensure(deadline)
        whenNotPaused
        nonReentrant
        returns (uint amountA, uint amountB)
    {
        _enforceWhitelist();

        address[] memory path = new address[](2);
        path[0] = tokenA;
        path[1] = tokenB;
        _enforceXpgnNotPaused(path);

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
        public
        override
        ensure(deadline)
        whenNotPaused
        nonReentrant
        returns (uint amountToken, uint amountNative)
    {
        _enforceWhitelist();

        address[] memory path = new address[](2);
        path[0] = token;
        path[1] = WNative;
        _enforceXpgnNotPaused(path);

        address pair = ParagonLibrary.pairFor(factory, token, WNative);
        IERC20(pair).safeTransferFrom(msg.sender, pair, liquidity);
        (uint amount0, uint amount1) = IParagonPair(pair).burn(address(this));
        (address token0,) = ParagonLibrary.sortTokens(token, WNative);
        (uint outToken, uint outWNative) = token == token0 ? (amount0, amount1) : (amount1, amount0);
        require(outToken >= amountTokenMin, "Paragon: INSUFF_TOKEN");
        require(outWNative >= amountNativeMin, "Paragon: INSUFF_NATIVE");
        IERC20(token).safeTransfer(to, outToken);
        IWETH(WNative).withdraw(outWNative);
        (bool success, ) = to.call{value: outWNative}("");
        require(success, "Paragon: NATIVE_SEND_FAIL");
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
        uint8 v,
        bytes32 r,
        bytes32 s
    )
        external
        override
        returns (uint amountA, uint amountB)
    {
        address pair = ParagonLibrary.pairFor(factory, tokenA, tokenB);
        uint value = approveMax ? type(uint).max : liquidity;
        IERC20Permit(pair).permit(msg.sender, address(this), value, deadline, v, r, s);
        (amountA, amountB) = removeLiquidity(
            tokenA,
            tokenB,
            liquidity,
            amountAMin,
            amountBMin,
            to,
            deadline
        );
    }

    function removeLiquidityNativeWithPermit(
        address token,
        uint liquidity,
        uint amountTokenMin,
        uint amountNativeMin,
        address to,
        uint deadline,
        bool approveMax,
        uint8 v,
        bytes32 r,
        bytes32 s
    )
        external
        override
        returns (uint amountToken, uint amountNative)
    {
        address pair = ParagonLibrary.pairFor(factory, token, WNative);
        uint value = approveMax ? type(uint).max : liquidity;
        IERC20Permit(pair).permit(msg.sender, address(this), value, deadline, v, r, s);
        return removeLiquidityNative(token, liquidity, amountTokenMin, amountNativeMin, to, deadline);
    }

    // ---------------------- Swaps (classic) ----------------------
    function swapExactTokensForTokens(
        uint amountIn,
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline,
        uint8 autoYieldPercent
    )
        external
        override
        ensure(deadline)
        whenNotPaused
        nonReentrant
        returns (uint[] memory amounts)
    {
        _enforceWhitelist();

        address[] memory r = path;
        _checkPath(r);
        _enforceXpgnNotPaused(r);

        uint8 eff = _effectiveAutoYieldPercent(msg.sender, to, autoYieldPercent);
        address outToken = r[r.length - 1];

        bool custody = _shouldCustodyForAutoYield(outToken, eff);
        address finalTo = custody ? address(this) : to;

        uint256 grossMin = custody ? _minGrossOutForNet(amountOutMin, eff) : amountOutMin;

        amounts = ParagonLibrary.getAmountsOut(factory, amountIn, r);

        _enforceOracleGuard(amountIn, r, amounts[amounts.length - 1]);

        require(amounts[amounts.length - 1] >= grossMin, "Paragon: INSUFF_OUTPUT");

        IERC20(r[0]).safeTransferFrom(msg.sender, ParagonLibrary.pairFor(factory, r[0], r[1]), amountIn);

        ParagonRouterSwapHelper.swap(amounts, r, factory, finalTo);

        if (custody) {
            uint256 userBefore = IERC20(outToken).balanceOf(to);
            _handleAutoYield(outToken, amounts[amounts.length - 1], to, eff);
            uint256 userReceived = IERC20(outToken).balanceOf(to) - userBefore;
            require(userReceived >= amountOutMin, "Paragon: INSUFF_USER_OUT");
        }

        return amounts;
    }

    function swapTokensForExactTokens(
        uint amountOut,
        uint amountInMax,
        address[] calldata path,
        address to,
        uint deadline
    )
        external
        override
        ensure(deadline)
        whenNotPaused
        nonReentrant
        returns (uint[] memory amounts)
    {
        _enforceWhitelist();

        address[] memory r = path;
        _checkPath(r);
        _enforceXpgnNotPaused(r);

        amounts = ParagonLibrary.getAmountsIn(factory, amountOut, r);

        _enforceOracleGuard(amounts[0], r, amountOut);

        require(amounts[0] <= amountInMax, "Paragon: EXCESSIVE_INPUT");

        IERC20(r[0]).safeTransferFrom(msg.sender, ParagonLibrary.pairFor(factory, r[0], r[1]), amounts[0]);

        ParagonRouterSwapHelper.swap(amounts, r, factory, to);

        return amounts;
    }

    function swapExactNativeForTokens(
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline,
        uint8 autoYieldPercent
    )
        external
        payable
        override
        ensure(deadline)
        whenNotPaused
        nonReentrant
        returns (uint[] memory amounts)
    {
        _enforceWhitelist();

        require(path[0] == WNative, "Paragon: PATH_START_WNATIVE");

        address[] memory r = path;
        _checkPath(r);
        _enforceXpgnNotPaused(r);

        uint8 eff = _effectiveAutoYieldPercent(msg.sender, to, autoYieldPercent);
        address outToken = r[r.length - 1];

        bool custody = _shouldCustodyForAutoYield(outToken, eff);
        address finalTo = custody ? address(this) : to;

        uint256 grossMin = custody ? _minGrossOutForNet(amountOutMin, eff) : amountOutMin;

        amounts = ParagonLibrary.getAmountsOut(factory, msg.value, r);

        _enforceOracleGuard(msg.value, r, amounts[amounts.length - 1]);

        require(amounts[amounts.length - 1] >= grossMin, "Paragon: INSUFF_OUTPUT");

        IWETH(WNative).deposit{value: msg.value}();
        assert(IWETH(WNative).transfer(ParagonLibrary.pairFor(factory, r[0], r[1]), msg.value));

        ParagonRouterSwapHelper.swap(amounts, r, factory, finalTo);

        if (custody) {
            uint256 userBefore = IERC20(outToken).balanceOf(to);
            _handleAutoYield(outToken, amounts[amounts.length - 1], to, eff);
            uint256 userReceived = IERC20(outToken).balanceOf(to) - userBefore;
            require(userReceived >= amountOutMin, "Paragon: INSUFF_USER_OUT");
        }

        return amounts;
    }

    function swapExactTokensForNative(
        uint amountIn,
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    )
        external
        override
        ensure(deadline)
        whenNotPaused
        nonReentrant
        returns (uint[] memory amounts)
    {
        _enforceWhitelist();

        require(path[path.length - 1] == WNative, "Paragon: PATH_END_WNATIVE");

        address[] memory r = path;
        _checkPath(r);
        _enforceXpgnNotPaused(r);

        amounts = ParagonLibrary.getAmountsOut(factory, amountIn, r);

        _enforceOracleGuard(amountIn, r, amounts[amounts.length - 1]);

        require(amounts[amounts.length - 1] >= amountOutMin, "Paragon: INSUFF_OUTPUT");

        IERC20(r[0]).safeTransferFrom(msg.sender, ParagonLibrary.pairFor(factory, r[0], r[1]), amountIn);

        ParagonRouterSwapHelper.swap(amounts, r, factory, address(this));

        uint256 wOut = amounts[amounts.length - 1];
        IWETH(WNative).withdraw(wOut);
        (bool success, ) = to.call{value: wOut}("");
        require(success, "Paragon: NATIVE_SEND_FAIL");

        return amounts;
    }

    function swapTokensForExactNative(
        uint amountOut,
        uint amountInMax,
        address[] calldata path,
        address to,
        uint deadline
    )
        external
        override
        ensure(deadline)
        whenNotPaused
        nonReentrant
        returns (uint[] memory amounts)
    {
        _enforceWhitelist();

        require(path[path.length - 1] == WNative, "Paragon: PATH_END_WNATIVE");

        address[] memory r = path;
        _checkPath(r);
        _enforceXpgnNotPaused(r);

        amounts = ParagonLibrary.getAmountsIn(factory, amountOut, r);

        _enforceOracleGuard(amounts[0], r, amountOut);

        require(amounts[0] <= amountInMax, "Paragon: EXCESSIVE_INPUT");

        IERC20(r[0]).safeTransferFrom(msg.sender, ParagonLibrary.pairFor(factory, r[0], r[1]), amounts[0]);

        ParagonRouterSwapHelper.swap(amounts, r, factory, address(this));

        IWETH(WNative).withdraw(amountOut);
        (bool success, ) = to.call{value: amountOut}("");
        require(success, "Paragon: NATIVE_SEND_FAIL");

        return amounts;
    }

    function swapNativeForExactTokens(
        uint amountOut,
        address[] calldata path,
        address to,
        uint deadline
    )
        external
        payable
        override
        ensure(deadline)
        whenNotPaused
        nonReentrant
        returns (uint[] memory amounts)
    {
        _enforceWhitelist();

        require(path[0] == WNative, "Paragon: PATH_START_WNATIVE");

        address[] memory r = path;
        _checkPath(r);
        _enforceXpgnNotPaused(r);

        amounts = ParagonLibrary.getAmountsIn(factory, amountOut, r);

        _enforceOracleGuard(amounts[0], r, amountOut);

        require(amounts[0] <= msg.value, "Paragon: EXCESSIVE_INPUT");

        IWETH(WNative).deposit{value: amounts[0]}();
        assert(IWETH(WNative).transfer(ParagonLibrary.pairFor(factory, r[0], r[1]), amounts[0]));

        ParagonRouterSwapHelper.swap(amounts, r, factory, to);

        if (msg.value > amounts[0]) {
            (bool success, ) = msg.sender.call{value: msg.value - amounts[0]}("");
            require(success, "Paragon: REFUND_FAIL");
        }

        return amounts;
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
        external
        override
        ensure(deadline)
        whenNotPaused
        nonReentrant
        returns (uint amountOut)
    {
        _enforceWhitelist();

        address[] memory r = path;
        _checkPath(r);
        _enforceXpgnNotPaused(r);

        uint8 eff = _effectiveAutoYieldPercent(msg.sender, to, autoYieldPercent);
        address outToken = r[r.length - 1];

        bool custody = _shouldCustodyForAutoYield(outToken, eff);
        address finalTo = custody ? address(this) : to;

        uint256 grossMin = custody ? _minGrossOutForNet(amountOutMin, eff) : amountOutMin;

        address inputToken = r[0];
        address firstPair = ParagonLibrary.pairFor(factory, inputToken, r[1]);
        uint256 balanceBefore = IERC20(inputToken).balanceOf(firstPair);

        IERC20(inputToken).safeTransferFrom(msg.sender, firstPair, amountIn);

        uint256 actualIn = IERC20(inputToken).balanceOf(firstPair) - balanceBefore;

        _enforceFOTTolerance(amountIn, actualIn);

        uint256 beforeBal = IERC20(outToken).balanceOf(finalTo);

        ParagonRouterSwapHelper.swapSupportingFeeOnTransferTokens(r, factory, finalTo);

        amountOut = IERC20(outToken).balanceOf(finalTo) - beforeBal;

        _enforceOracleGuardPostSwap(actualIn, r, amountOut);

        require(amountOut >= grossMin, "Paragon: INSUFF_OUTPUT");

        if (custody) {
            uint256 userBefore = IERC20(outToken).balanceOf(to);
            _handleAutoYield(outToken, amountOut, to, eff);
            uint256 userReceived = IERC20(outToken).balanceOf(to) - userBefore;
            require(userReceived >= amountOutMin, "Paragon: INSUFF_USER_OUT");
        }

        return amountOut;
    }

    function swapExactNativeForTokensSupportingFeeOnTransferTokens(
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline,
        uint8 autoYieldPercent
    )
        external
        payable
        override
        ensure(deadline)
        whenNotPaused
        nonReentrant
        returns (uint amountOut)
    {
        _enforceWhitelist();

        require(path[0] == WNative, "Paragon: PATH_START_WNATIVE");

        address[] memory r = path;
        _checkPath(r);
        _enforceXpgnNotPaused(r);

        uint8 eff = _effectiveAutoYieldPercent(msg.sender, to, autoYieldPercent);
        address outToken = r[r.length - 1];

        bool custody = _shouldCustodyForAutoYield(outToken, eff);
        address finalTo = custody ? address(this) : to;

        uint256 grossMin = custody ? _minGrossOutForNet(amountOutMin, eff) : amountOutMin;

        IWETH(WNative).deposit{value: msg.value}();

        address firstPair = ParagonLibrary.pairFor(factory, r[0], r[1]);
        uint256 balanceBefore = IERC20(WNative).balanceOf(firstPair);

        assert(IWETH(WNative).transfer(firstPair, msg.value));

        uint256 actualIn = IERC20(WNative).balanceOf(firstPair) - balanceBefore;

        _enforceFOTTolerance(msg.value, actualIn);

        uint256 beforeBal = IERC20(outToken).balanceOf(finalTo);

        ParagonRouterSwapHelper.swapSupportingFeeOnTransferTokens(r, factory, finalTo);

        amountOut = IERC20(outToken).balanceOf(finalTo) - beforeBal;

        _enforceOracleGuardPostSwap(actualIn, r, amountOut);

        require(amountOut >= grossMin, "Paragon: INSUFF_OUTPUT");

        if (custody) {
            uint256 userBefore = IERC20(outToken).balanceOf(to);
            _handleAutoYield(outToken, amountOut, to, eff);
            uint256 userReceived = IERC20(outToken).balanceOf(to) - userBefore;
            require(userReceived >= amountOutMin, "Paragon: INSUFF_USER_OUT");
        }

        return amountOut;
    }

    function swapExactTokensForNativeSupportingFeeOnTransferTokens(
        uint amountIn,
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    )
        external
        override
        ensure(deadline)
        whenNotPaused
        nonReentrant
        returns (uint amountOut)
    {
        _enforceWhitelist();

        require(path[path.length - 1] == WNative, "Paragon: PATH_END_WNATIVE");

        address[] memory r = path;
        _checkPath(r);
        _enforceXpgnNotPaused(r);

        address inputToken = r[0];
        address firstPair = ParagonLibrary.pairFor(factory, inputToken, r[1]);
        uint256 balanceBefore = IERC20(inputToken).balanceOf(firstPair);

        IERC20(inputToken).safeTransferFrom(msg.sender, firstPair, amountIn);

        uint256 actualIn = IERC20(inputToken).balanceOf(firstPair) - balanceBefore;

        _enforceFOTTolerance(amountIn, actualIn);

        uint256 beforeBal = IERC20(WNative).balanceOf(address(this));

        ParagonRouterSwapHelper.swapSupportingFeeOnTransferTokens(r, factory, address(this));

        uint256 wReceived = IERC20(WNative).balanceOf(address(this)) - beforeBal;

        _enforceOracleGuardPostSwap(actualIn, r, wReceived);

        require(wReceived >= amountOutMin, "Paragon: INSUFF_OUTPUT");

        IWETH(WNative).withdraw(wReceived);
        (bool success, ) = to.call{value: wReceived}("");
        require(success, "Paragon: NATIVE_SEND_FAIL");

        amountOut = wReceived;

        return amountOut;
    }

    // ---------------------- Admin: pause/rescue ----------------------
    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    function rescueTokens(address token, address to) external onlyOwner {
        if (token == address(0)) {
            (bool success, ) = to.call{value: address(this).balance}("");
            require(success, "Paragon: NATIVE_SEND_FAIL");
        } else {
            IERC20(token).safeTransfer(to, IERC20(token).balanceOf(address(this)));
        }
    }
}