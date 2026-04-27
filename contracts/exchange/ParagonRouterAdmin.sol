// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.25;

import "@openzeppelin/contracts/access/Ownable.sol";
import "./interfaces/IParagonFactory.sol";
import "./libraries/ParagonLibrary.sol";

/// @dev Minimal paused() interface (avoid hard-importing token contract)
interface IPausableToken {
    function paused() external view returns (bool);
}

/// @notice Router policy/config contract read by ParagonRouter (whitelist + tolerances + helper views)
/// @dev
/// This contract is intentionally "dumb":
/// - it stores policy/config values consumed by the Router / RouterGuard
/// - it exposes helper / estimation / UI-oriented validation functions
///
/// IMPORTANT DESIGN NOTE:
/// The helper functions in this contract are NOT execution guarantees.
/// Actual swap acceptance is determined at execution time by ParagonRouter
/// and, where configured, ParagonRouterGuard using live reserves, actual input,
/// oracle checks, fee-on-transfer tolerance, and post-swap conditions.
///
/// In particular, helper functions such as:
/// - checkSlippageExactOut
/// - getPathPriceImpact
/// - checkPriceImpactMultiHop
/// - isSwapSafe
/// - calculateOptimalSlippage
/// - getMaxSwapAmount
///
/// should be treated as off-chain / UI guidance only.
///
/// Integrators MUST NOT assume that a positive helper result guarantees
/// successful execution, because live Router / Guard enforcement may differ
/// due to reserve changes, oracle state, FoT behavior, protected-token paths,
/// and post-swap validation rules.
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

    // Events
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
            assembly { size := extcodesize(_oracle) }
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
    // Internal fee helper (PAD-34 fix)
    // ==========================
    /// @dev Returns the effective swap fee for a specific hop (tokenA->tokenB),
    /// honoring per-pair overrides via factory.getEffectiveSwapFeeBips(pair).
    function _effectiveFeeBipsForHop(address factory, address tokenA, address tokenB) internal view returns (uint32) {
        address pair = IParagonFactory(factory).getPair(tokenA, tokenB);
        if (pair == address(0)) {
            // No pair - fall back to global for estimation (liquidity checks will fail anyway)
            return IParagonFactory(factory).swapFeeBips();
        }
        return IParagonFactory(factory).getEffectiveSwapFeeBips(pair);
    }

    // ==========================
    // Validation helpers (optional UI calls)
    // ==========================

    /// @notice Pure path-shape validation helper for UI / off-chain callers.
    /// @dev This does NOT guarantee a live swap will succeed.
    function validatePath(address[] calldata path) external pure returns (bool valid) {
        if (path.length < 2 || path.length > 5) return false;
        for (uint i; i < path.length - 1; i++) {
            if (path[i] == address(0) || path[i + 1] == address(0)) return false;
            if (path[i] == path[i + 1]) return false;
        }
        return true;
    }

    /// @notice Enforces XPGN paused() if path touches XPGN.
    /// @dev This mirrors only the paused-token check and is not a full execution guarantee.
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

    /// @notice Heuristic multi-hop price impact check for UI / off-chain guidance.
    /// @dev
    /// This is NOT identical to live Router / Guard execution-time validation.
    /// It uses an approximation:
    ///   impact ≈ 2 × amountIn / (reserveIn + amountIn)
    /// and progresses hop inputs using current reserve math and effective per-hop fees.
    ///
    /// Actual execution may still fail due to reserve movement, oracle requirements,
    /// fee-on-transfer behavior, protected-token checks, or post-swap guard validation.
    function checkPriceImpactMultiHop(address factory, uint amountIn, address[] calldata path) external view {
        require(path.length >= 2, "INVALID_PATH");

        uint currentIn = amountIn;
        uint32 maxImpact = maxPriceImpactBips;

        for (uint i; i < path.length - 1; ) {
            (uint112 reserveA, uint112 reserveB, ) = ParagonLibrary.getReserves(factory, path[i], path[i + 1]);
            require(reserveA > 0 && reserveB > 0, "INSUFFICIENT_LIQUIDITY");

            // Improved: marginal impact ≈ 2 * currentIn / (reserveIn + currentIn)
            uint256 impact = (currentIn * 20_000) / (uint(reserveA) + currentIn);
            require(impact <= maxImpact, "PRICE_IMPACT_EXCEEDED");

            uint32 feeBips = _effectiveFeeBipsForHop(factory, path[i], path[i + 1]);
            currentIn = ParagonLibrary.getAmountOut(currentIn, reserveA, reserveB, feeBips);

            unchecked { ++i; }
        }
    }

    /// @notice Exact-out slippage precheck helper for UI / off-chain guidance.
    /// @dev
    /// This estimates whether amountInMax is likely sufficient under current reserves.
    /// It is NOT a guarantee of success under live Router / Guard enforcement.
    ///
    /// PAD-34 FIX: for 2-hop direct math, uses effective per-pair fee (honors overrides)
    function checkSlippageExactOut(address factory, uint amountOut, uint amountInMax, address[] calldata path) external view {
        require(path.length >= 2, "INVALID_PATH");

        if (path.length == 2) {
            (uint112 reserveA, uint112 reserveB, ) = ParagonLibrary.getReserves(factory, path[0], path[1]);
            require(reserveA > 0 && reserveB > 0, "INSUFFICIENT_LIQUIDITY");
            require(amountOut < reserveB, "AMOUNT_OUT_TOO_HIGH");

            uint32 feeBips = _effectiveFeeBipsForHop(factory, path[0], path[1]);

            uint256 expectedIn =
                (uint(reserveA) * amountOut * 10_000) / ((uint(reserveB) - amountOut) * (10_000 - feeBips)) + 1;

            require(expectedIn <= amountInMax, "EXCESSIVE_INPUT_AMOUNT");
        } else {
            uint[] memory amounts = ParagonLibrary.getAmountsIn(factory, amountOut, path); // already uses effective fees
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

    /// @notice Returns a heuristic max swap size estimate for UI guidance.
    /// @dev
    /// This estimate is reserve-based and uses the configured maxPriceImpactBips threshold.
    /// It is most meaningful for direct swaps (path.length == 2).
    ///
    /// For multi-hop paths, each hop has a different input-token unit context, so the
    /// minimum bound across hops should be treated as guidance only, not a precise
    /// execution-safe limit.
    function getMaxSwapAmount(address factory, address[] calldata path) external view returns (uint maxAmount) {
        require(path.length >= 2, "INVALID_PATH");
        uint32 maxImpact = maxPriceImpactBips;
        if (maxImpact >= 10_000) return type(uint).max;

        maxAmount = type(uint).max;

        for (uint i; i < path.length - 1; ) {
            (uint112 reserveA,,) = ParagonLibrary.getReserves(factory, path[i], path[i + 1]);
            if (reserveA == 0) return 0;

            // Solve: 2*in / (reserveIn + in) <= maxImpact/10000
            // => in <= reserveIn * maxImpact / (20000 - maxImpact)
            uint maxForHop = (uint(reserveA) * maxImpact) / (20_000 - maxImpact);

            if (maxForHop < maxAmount) maxAmount = maxForHop;
            unchecked { ++i; }
        }
    }

    /// @notice Returns per-hop heuristic price impact estimates for UI / off-chain callers.
    /// @dev
    /// These are estimates only and are not identical to execution-time Router / Guard logic.
    /// PAD-34 FIX: intermediate amount progression uses per-hop effective fees.
    function getPathPriceImpact(address factory, uint amountIn, address[] calldata path)
        external
        view
        returns (uint[] memory impacts)
    {
        require(path.length >= 2, "INVALID_PATH");
        impacts = new uint[](path.length - 1);

        uint currentIn = amountIn;

        for (uint i; i < path.length - 1; ) {
            (uint112 reserveA, uint112 reserveB, ) = ParagonLibrary.getReserves(factory, path[i], path[i + 1]);
            if (reserveA > 0 && reserveB > 0) {
                // Improved: ×2 factor for better marginal impact approximation
                impacts[i] = (currentIn * 20_000) / (uint(reserveA) + currentIn);

                uint32 feeBips = _effectiveFeeBipsForHop(factory, path[i], path[i + 1]);
                currentIn = ParagonLibrary.getAmountOut(currentIn, reserveA, reserveB, feeBips);
            } else {
                impacts[i] = type(uint).max;
            }
            unchecked { ++i; }
        }
    }

    /// @notice Suggests a heuristic slippage setting based on estimated path impact.
    /// @dev
    /// This is UI guidance only and is not a promise that the Router / Guard will accept the swap.
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

    /// @notice High-level safety helper for UI / off-chain callers.
    /// @dev
    /// This function is heuristic only. A `true` result does NOT guarantee execution success.
    /// Live Router / Guard checks may still fail because of:
    /// - reserve movement between quote and execution
    /// - oracle validation differences
    /// - fee-on-transfer behavior
    /// - protected-token checks
    /// - post-swap validation rules
    ///
    /// For direct swaps (path.length == 2), this also compares amountIn against getMaxSwapAmount().
    /// For multi-hop paths, getMaxSwapAmount() is not directly comparable hop-by-hop in a strict
    /// execution sense because units differ across hops, so this check is intentionally omitted.
    function isSwapSafe(address factory, uint amountIn, address[] calldata path)
        external
        view
        returns (bool safe, string memory reason)
    {
        if (path.length < 2 || path.length > 5) return (false, "Invalid path length");
        for (uint i; i < path.length - 1; i++) {
            if (path[i] == address(0) || path[i + 1] == address(0)) return (false, "Zero address");
            if (path[i] == path[i + 1]) return (false, "Identical hops");
        }

        try this.checkPriceImpactMultiHop(factory, amountIn, path) {
            // PAD-38 FIX:
            // getMaxSwapAmount() returns a per-hop bound denominated in that hop's input token.
            // For multi-hop paths, the minimum hop bound may be in path[i] units (i>0),
            // so only compare directly against amountIn for direct swaps.
            if (path.length == 2) {
                uint maxSwap = this.getMaxSwapAmount(factory, path);
                if (amountIn > maxSwap) return (false, "Amount exceeds max swap limit");
            }
            return (true, "");
        } catch Error(string memory err) {
            return (false, err);
        } catch {
            return (false, "Unknown validation error");
        }
    }
}
