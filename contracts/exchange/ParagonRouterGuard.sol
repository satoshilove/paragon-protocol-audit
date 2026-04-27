// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.25;

import "@openzeppelin/contracts/access/Ownable.sol";

import "./interfaces/IParagonFactory.sol";
import "./libraries/ParagonLibrary.sol";

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

interface IParagonRouterAdminForGuard {
    function maxSlippageBips() external view returns (uint32);
    function maxPriceImpactBips() external view returns (uint32);
    function feeOnTransferTolerance() external view returns (uint32);
    function twapOracle() external view returns (address);
    function useTwap() external view returns (bool);
}

contract ParagonRouterGuard is Ownable {
    address public immutable factory;
    IParagonRouterAdminForGuard public admin;

    bool public enabled = true;
    bool public failOpen = false;

    mapping(address => bool) public protectedToken;

    event GuardEnabledUpdated(bool enabled);
    event GuardFailOpenUpdated(bool failOpen);
    event GuardAdminUpdated(address indexed admin);
    event ProtectedTokenUpdated(address indexed token, bool isProtected);

    constructor(address initialOwner, address _factory, address _admin) Ownable(initialOwner) {
        require(_factory != address(0), "ParagonGuard: ZERO_FACTORY");
        require(_admin != address(0), "ParagonGuard: ZERO_ADMIN");
        factory = _factory;
        admin = IParagonRouterAdminForGuard(_admin);
    }

    // ---------------------- Admin ----------------------
    function setAdmin(address _admin) external onlyOwner {
        require(_admin != address(0), "ParagonGuard: ZERO_ADMIN");
        admin = IParagonRouterAdminForGuard(_admin);
        emit GuardAdminUpdated(_admin);
    }

    function setEnabled(bool _enabled) external onlyOwner {
        enabled = _enabled;
        emit GuardEnabledUpdated(_enabled);
    }

    function setFailOpen(bool _failOpen) external onlyOwner {
        failOpen = _failOpen;
        emit GuardFailOpenUpdated(_failOpen);
    }

    function setProtectedToken(address token, bool isProtected) external onlyOwner {
        protectedToken[token] = isProtected;
        emit ProtectedTokenUpdated(token, isProtected);
    }

    // ---------------------- External validation entrypoints ----------------------
    function validatePreSwap(
        uint256 amountIn,
        address[] calldata path,
        uint256 quotedOut
    ) external view {
        if (!enabled || !_pathHasProtected(path)) return;

        (uint256 minOut, bool oracleOk) = _oracleMinOutMaybe(amountIn, path);

        if (failOpen) {
            if (oracleOk && minOut > 0) {
                require(quotedOut >= minOut, "Paragon: ORACLE_SLIPPAGE");
            }
        } else {
            require(oracleOk && minOut > 0, "Paragon: ORACLE_FAIL");
            require(quotedOut >= minOut, "Paragon: ORACLE_SLIPPAGE");
        }

        uint256[] memory amountsCalc = ParagonLibrary.getAmountsOut(factory, amountIn, path);
        uint16 impact = _impactBips(path, amountsCalc);
        require(impact <= admin.maxPriceImpactBips(), "Paragon: PRICE_IMPACT");
    }

    function validatePostSwap(
        uint256 effectiveIn,
        address[] calldata path,
        uint256 actualOut,
        uint256 expectedOutPreSwap
    ) external view {
        if (!enabled || !_pathHasProtected(path)) return;

        (uint256 quoteOut, bool oracleOk) = _oracleQuoteOutMaybe(effectiveIn, path);

        uint256 extra = uint256(admin.feeOnTransferTolerance());
        uint256 totalSlip = uint256(admin.maxSlippageBips()) + extra;
        if (totalSlip > 10000) totalSlip = 10000;

        uint256 minOut = oracleOk ? (quoteOut * (10000 - totalSlip)) / 10000 : 0;

        if (failOpen) {
            if (oracleOk && minOut > 0) {
                require(actualOut >= minOut, "Paragon: ORACLE_SLIPPAGE");
            }
        } else {
            require(oracleOk && minOut > 0, "Paragon: ORACLE_FAIL");
            require(actualOut >= minOut, "Paragon: ORACLE_SLIPPAGE");
        }

        require(expectedOutPreSwap > 0, "Paragon: BAD_PREQUOTE");

        uint16 impactOverall = _impactBipsOverall(expectedOutPreSwap, actualOut);
        uint256 allowed = uint256(admin.maxPriceImpactBips()) + extra;
        if (allowed > 2000) allowed = 2000;

        require(uint256(impactOverall) <= allowed, "Paragon: PRICE_IMPACT");
    }

    // ---------------------- Internals ----------------------
    function _pathHasProtected(address[] calldata pth) internal view returns (bool) {
        for (uint i = 0; i < pth.length; i++) {
            if (protectedToken[pth[i]]) return true;
        }
        return false;
    }

    function _oracleQuoteOutMaybe(uint amountIn, address[] calldata route)
        internal
        view
        returns (uint quoteOut, bool ok)
    {
        address oracleAddr = admin.twapOracle();
        if (oracleAddr == address(0)) return (0, false);

        IParagonOracle oracle = IParagonOracle(oracleAddr);
        uint[] memory o;

        if (admin.useTwap()) {
            try oracle.getAmountsOutUsingTwap(amountIn, _toMemory(route), 0) returns (uint[] memory arr) {
                o = arr;
            } catch {
                return (0, false);
            }
        } else {
            try oracle.getAmountsOutUsingChainlink(amountIn, _toMemory(route)) returns (uint[] memory arr) {
                o = arr;
            } catch {
                return (0, false);
            }
        }

        if (o.length == 0) return (0, false);
        quoteOut = o[o.length - 1];
        if (quoteOut == 0) return (0, false);

        ok = true;
    }

    function _oracleMinOutMaybe(uint amountIn, address[] calldata route)
        internal
        view
        returns (uint minOut, bool ok)
    {
        (uint quoteOut, bool qOk) = _oracleQuoteOutMaybe(amountIn, route);
        if (!qOk) return (0, false);

        minOut = (quoteOut * (10000 - admin.maxSlippageBips())) / 10000;
        ok = true;
    }

    function _impactBips(address[] calldata route, uint[] memory amounts) internal view returns (uint16) {
        uint16 maxBips = 0;

        for (uint i = 0; i < route.length - 1; i++) {
            if (!(protectedToken[route[i]] || protectedToken[route[i + 1]])) continue;

            (uint rIn, uint rOut,) = ParagonLibrary.getReserves(factory, route[i], route[i + 1]);
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

    function _impactBipsOverall(uint256 expectedOut, uint256 actualOut) internal pure returns (uint16) {
        if (expectedOut == 0) return type(uint16).max;
        if (actualOut >= expectedOut) return 0;

        uint256 diff = expectedOut - actualOut;
        uint256 bips = (diff * 10000) / expectedOut;
        if (bips > type(uint16).max) return type(uint16).max;
        return uint16(bips);
    }

    function _toMemory(address[] calldata arr) internal pure returns (address[] memory out) {
        out = new address[](arr.length);
        for (uint i = 0; i < arr.length; i++) {
            out[i] = arr[i];
        }
    }
}
