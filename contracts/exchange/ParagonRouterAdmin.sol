// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import "@openzeppelin/contracts/access/Ownable.sol";
import "./interfaces/IParagonFactory.sol";
import "./libraries/ParagonLibrary.sol";

/// @dev minimal paused() interface (avoid hard-importing token contract)
interface IPausableToken {
    function paused() external view returns (bool);
}

/// @notice Router policy/config contract read by ParagonRouter (whitelist + tolerances + helper views)
/// @dev Keep this contract "dumb": store config + expose helpers. The Router enforces.
contract ParagonRouterAdmin is Ownable {
    // -------------------- Core config --------------------
    uint32 public maxSlippageBips = 50;           // 0.5%
    uint32 public maxPriceImpactBips = 100;       // 1.0%
    uint32 public feeOnTransferTolerance = 200;   // 2.0% (bips)
    uint32 public twapToleranceBips = 500;        // 5.0% (bips)
    address public twapOracle;
    bool   public useTwap;

    // Whitelist gate (router checks admin.whitelistEnabled() then admin.whitelist(msg.sender))
    bool public whitelistEnabled;
    mapping(address => bool) public whitelist;

    // XPGN token address is read from the Factory (no hardcoded address)
    event SlippageUpdated(uint32 bips);
    event PriceImpactUpdated(uint32 bips);
    event FeeToleranceUpdated(uint32 tolerance);
    event TwapToleranceUpdated(uint32 tolerance);
    event TwapOracleConfigured(address indexed oracle, bool enabled);
    event WhitelistStatusChanged(bool enabled);
    event WhitelistAdded(address indexed account);
    event WhitelistRemoved(address indexed account);

    constructor(address initialOwner) Ownable(initialOwner) {}

    // ==========================
    // Admin setters
    // ==========================
    function setMaxSlippageBips(uint32 _bips) external onlyOwner {
        require(_bips <= 10_000, "INVALID_SLIPPAGE");
        maxSlippageBips = _bips;
        emit SlippageUpdated(_bips);
    }

    function setMaxPriceImpactBips(uint32 _bips) external onlyOwner {
        require(_bips <= 10_000, "INVALID_PRICE_IMPACT");
        maxPriceImpactBips = _bips;
        emit PriceImpactUpdated(_bips);
    }

    function setFeeOnTransferTolerance(uint32 _tolerance) external onlyOwner {
        // keep tight: <= 10% default cap (adjust if you want)
        require(_tolerance <= 1_000, "INVALID_TOLERANCE");
        feeOnTransferTolerance = _tolerance;
        emit FeeToleranceUpdated(_tolerance);
    }

    function setTwapToleranceBips(uint32 _tolerance) external onlyOwner {
        require(_tolerance <= 2_000, "INVALID_TWAP_TOLERANCE");
        twapToleranceBips = _tolerance;
        emit TwapToleranceUpdated(_tolerance);
    }

    function configureTwapOracle(address _oracle, bool _enabled) external onlyOwner {
        if (_enabled) {
            require(_oracle != address(0), "ZERO_ORACLE");
            uint256 size;
            assembly {
                size := extcodesize(_oracle)
            }
            require(size > 0, "INVALID_ORACLE");
        }
        twapOracle = _oracle;
        useTwap = _enabled;
        emit TwapOracleConfigured(_oracle, _enabled);
    }

    function setWhitelistEnabled(bool _on) external onlyOwner {
        whitelistEnabled = _on;
        emit WhitelistStatusChanged(_on);
    }

    function addToWhitelist(address _acct) external onlyOwner {
        require(_acct != address(0), "INVALID_ACCOUNT");
        whitelist[_acct] = true;
        emit WhitelistAdded(_acct);
    }

    function removeFromWhitelist(address _acct) external onlyOwner {
        require(_acct != address(0), "INVALID_ACCOUNT");
        whitelist[_acct] = false;
        emit WhitelistRemoved(_acct);
    }

    function batchUpdateWhitelist(address[] calldata accounts, bool[] calldata statuses) external onlyOwner {
        require(accounts.length == statuses.length, "ARRAY_LENGTH_MISMATCH");
        for (uint i; i < accounts.length; ) {
            address a = accounts[i];
            require(a != address(0), "INVALID_ACCOUNT");
            whitelist[a] = statuses[i];
            if (statuses[i]) emit WhitelistAdded(a);
            else emit WhitelistRemoved(a);
            unchecked { ++i; }
        }
    }

    // ==========================
    // Validation helpers (optional UI calls)
    // ==========================

    function validatePath(address[] calldata path) external pure returns (bool valid) {
        if (path.length < 2 || path.length > 5) return false;
        for (uint i; i < path.length - 1; i++) {
            if (path[i] == address(0) || path[i + 1] == address(0)) return false;
            if (path[i] == path[i + 1]) return false;
        }
        return true;
    }

    /// @notice Enforces XPGN paused() if path touches XPGN
    function checkXpgnNotPaused(address factory, address[] calldata path) external view {
        address xpgn = IParagonFactory(factory).xpgnToken();
        if (xpgn == address(0)) return;

        for (uint i; i < path.length; ++i) {
            if (path[i] == xpgn) {
                require(!IPausableToken(xpgn).paused(), "XPGN_TOKEN_PAUSED");
                return;
            }
        }
    }

    /// @notice Conservative multi-hop impact check (linear approx, matches router-style guard)
    function checkPriceImpactMultiHop(address factory, uint amountIn, address[] calldata path) external view {
        require(path.length >= 2, "INVALID_PATH");

        uint currentIn = amountIn;
        uint32 swapFeeBips = IParagonFactory(factory).swapFeeBips();
        uint32 maxImpact = maxPriceImpactBips;

        for (uint i; i < path.length - 1; ) {
            (uint112 reserveA, uint112 reserveB, ) = ParagonLibrary.getReserves(factory, path[i], path[i + 1]);
            require(reserveA > 0 && reserveB > 0, "INSUFFICIENT_LIQUIDITY");

            // approx impact = in / (reserveIn + in)
            uint256 impact = (currentIn * 10_000) / (uint(reserveA) + currentIn);
            require(impact <= maxImpact, "PRICE_IMPACT_EXCEEDED");

            currentIn = ParagonLibrary.getAmountOut(currentIn, reserveA, reserveB, swapFeeBips);

            unchecked { ++i; }
        }
    }

    /// @notice Exact-out slippage guard helper (UI / off-chain precheck)
    function checkSlippageExactOut(address factory, uint amountOut, uint amountInMax, address[] calldata path) external view {
        require(path.length >= 2, "INVALID_PATH");
        uint32 swapFeeBips = IParagonFactory(factory).swapFeeBips();

        if (path.length == 2) {
            (uint112 reserveA, uint112 reserveB, ) = ParagonLibrary.getReserves(factory, path[0], path[1]);
            require(reserveA > 0 && reserveB > 0, "INSUFFICIENT_LIQUIDITY");
            // expectedIn = (reserveIn * amountOut * 10000)/( (reserveOut-amountOut)*(10000-fee) ) + 1
            require(amountOut < reserveB, "AMOUNT_OUT_TOO_HIGH");
            uint256 expectedIn =
                (uint(reserveA) * amountOut * 10_000) / ((uint(reserveB) - amountOut) * (10_000 - swapFeeBips)) + 1;
            require(expectedIn <= amountInMax, "EXCESSIVE_INPUT_AMOUNT");
        } else {
            uint[] memory amounts = ParagonLibrary.getAmountsIn(factory, amountOut, path);
            require(amounts[0] <= amountInMax, "EXCESSIVE_INPUT_AMOUNT");
        }
    }

    // ==========================
    // Views for UI
    // ==========================
    function isWhitelisted(address account) external view returns (bool) {
        return whitelist[account];
    }

    function getConfig()
        external
        view
        returns (
            uint32 _maxSlippageBips,
            uint32 _maxPriceImpactBips,
            uint32 _feeOnTransferTolerance,
            uint32 _twapToleranceBips,
            address _twapOracle,
            bool _useTwap,
            bool _whitelistEnabled
        )
    {
        return (
            maxSlippageBips,
            maxPriceImpactBips,
            feeOnTransferTolerance,
            twapToleranceBips,
            twapOracle,
            useTwap,
            whitelistEnabled
        );
    }

    function getMaxSwapAmount(address factory, address[] calldata path) external view returns (uint maxAmount) {
        require(path.length >= 2, "INVALID_PATH");
        uint32 maxImpact = maxPriceImpactBips;
        if (maxImpact >= 10_000) return type(uint).max;

        maxAmount = type(uint).max;

        for (uint i; i < path.length - 1; ) {
            (uint112 reserveA,,) = ParagonLibrary.getReserves(factory, path[i], path[i + 1]);
            if (reserveA == 0) return 0;

            // Solve: in/(reserveIn+in) <= maxImpact/10000
            // => in <= reserveIn * maxImpact / (10000 - maxImpact)
            uint maxForHop = (uint(reserveA) * maxImpact) / (10_000 - maxImpact);

            if (maxForHop < maxAmount) maxAmount = maxForHop;
            unchecked { ++i; }
        }
    }

    function getPathPriceImpact(address factory, uint amountIn, address[] calldata path)
        external
        view
        returns (uint[] memory impacts)
    {
        require(path.length >= 2, "INVALID_PATH");
        impacts = new uint[](path.length - 1);

        uint currentIn = amountIn;
        uint32 swapFeeBips = IParagonFactory(factory).swapFeeBips();

        for (uint i; i < path.length - 1; ) {
            (uint112 reserveA, uint112 reserveB, ) = ParagonLibrary.getReserves(factory, path[i], path[i + 1]);
            if (reserveA > 0 && reserveB > 0) {
                impacts[i] = (currentIn * 10_000) / (uint(reserveA) + currentIn);
                currentIn = ParagonLibrary.getAmountOut(currentIn, reserveA, reserveB, swapFeeBips);
            } else {
                impacts[i] = type(uint).max;
            }
            unchecked { ++i; }
        }
    }

    function calculateOptimalSlippage(address factory, uint amountIn, address[] calldata path)
        external
        view
        returns (uint32 optimalSlippage)
    {
        if (path.length < 2) return maxSlippageBips;

        uint[] memory impacts = this.getPathPriceImpact(factory, amountIn, path);
        uint totalImpact;

        for (uint i; i < impacts.length; i++) {
            if (impacts[i] == type(uint).max) return maxSlippageBips;
            totalImpact += impacts[i];
        }

        // base 0.5% + half the estimated impact, capped by maxSlippageBips
        uint32 dyn = uint32(50 + (totalImpact / 2));
        optimalSlippage = dyn > maxSlippageBips ? maxSlippageBips : dyn;
    }

    function isSwapSafe(address factory, uint amountIn, address[] calldata path)
        external
        view
        returns (bool safe, string memory reason)
    {
        // inline validatePath (avoid external call overhead)
        if (path.length < 2 || path.length > 5) return (false, "Invalid path length");
        for (uint i; i < path.length - 1; i++) {
            if (path[i] == address(0) || path[i + 1] == address(0)) return (false, "Zero address");
            if (path[i] == path[i + 1]) return (false, "Identical hops");
        }

        try this.checkPriceImpactMultiHop(factory, amountIn, path) {
            uint maxSwap = this.getMaxSwapAmount(factory, path);
            if (amountIn > maxSwap) return (false, "Amount exceeds max swap limit");
            return (true, "");
        } catch Error(string memory err) {
            return (false, err);
        } catch {
            return (false, "Unknown validation error");
        }
    }
}
