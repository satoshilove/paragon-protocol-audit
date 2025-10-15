// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.25;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { IUsdValuer } from "../interfaces/IUsdValuer.sol"; // ← add interface import

interface IAggregatorV3 {
    function latestRoundData() external view returns (
        uint80 roundId,
        int256 answer,
        uint256 startedAt,
        uint256 updatedAt,
        uint80 answeredInRound
    );
    function decimals() external view returns (uint8);
}

/**
 * @title ChainlinkUsdValuer
 * @notice Simple USD valuer: token amount -> USD 1e18 using Chainlink feeds.
 *         Owner wires token -> aggregator; optional staleness window per feed.
 * @dev    Implements IUsdValuer. Freshness guards (answeredInRound, updatedAt, >0 answer).
 *         Optional max price cap (1e18 units). Pausable: blocks usdValue() during incidents while
 *         keeping monitor reads available. Scaling uses integer math; truncation possible for >18
 *         decimals (negligible for USD). Future-proof: Easy to extend _readChainlink with fallbacks.
 *
 * @notice Governance:
 *         - All setters are onlyOwner; hand ownership to a TimelockController (e.g., 48h) governed by a multisig.
 *         - Events emitted for every governance action for auditability.
 */
contract ChainlinkUsdValuer is IUsdValuer, Ownable, Pausable {
    // ── Errors ────────────────────────────────────────────────────────────────
    error FeedNotSet();
    error BadAnswer();     // non-positive price or incomplete round
    error StalePrice();    // answeredInRound < roundId or exceeded staleAfter
    error ExtremePrice();  // scaled price exceeds configured cap

    struct Feed {
        IAggregatorV3 agg;
        uint48  staleAfter; // seconds (0 = no staleness check)
    }

    mapping(address => Feed) public feeds; // token -> feed

    // Optional global cap on price (scaled to 1e18). 0 = disabled.
    uint256 public maxPrice1e18;

    // ── Events ────────────────────────────────────────────────────────────────
    event FeedSet(address indexed token, address indexed aggregator, uint48 staleAfter);
    event FeedCleared(address indexed token);
    event PausedByOwner(address indexed owner, string reason);
    event UnpausedByOwner(address indexed owner);
    event MaxPriceSet(uint256 maxPrice1e18);

    constructor(address initialOwner) Ownable(initialOwner) {
        maxPrice1e18 = 0; // Disabled by default
    }

    // ── Admin ────────────────────────────────────────────────────────────────

    /**
     * @notice Pause usdValue() (e.g., on oracle compromise). Monitoring calls remain available.
     * @param reason Brief description for audit trail.
     */
    function pause(string calldata reason) external onlyOwner {
        _pause();
        emit PausedByOwner(msg.sender, reason);
    }

    /**
     * @notice Unpause after resolution.
     */
    function unpause() external onlyOwner {
        _unpause();
        emit UnpausedByOwner(msg.sender);
    }

    /**
     * @notice Set a feed for token valuation.
     * @param token The ERC20 token address.
     * @param aggregator Chainlink aggregator address.
     * @param staleAfter Max seconds since update before staleness (0 = disable).
     */
    function setFeed(address token, address aggregator, uint48 staleAfter) external onlyOwner {
        require(token != address(0) && aggregator != address(0), "zero addr");
        feeds[token] = Feed(IAggregatorV3(aggregator), staleAfter);
        emit FeedSet(token, aggregator, staleAfter);
    }

    /**
     * @notice Remove a feed (disables valuation for this token).
     * @param token The ERC20 token address.
     */
    function clearFeed(address token) external onlyOwner {
        require(token != address(0), "zero addr");
        delete feeds[token];
        emit FeedCleared(token);
    }

    /**
     * @notice Configure optional max price cap (1e18 units). 0 disables the cap.
     * @param v The cap value (e.g., 1_000_000e18 for $1M max per unit).
     * @dev Prevents extreme prices from oracle manipulation.
     */
    function setMaxPrice1e18(uint256 v) external onlyOwner {
        // no special overflow risk here beyond normal 256-bit math; check is illustrative
        require(v <= type(uint256).max, "cap too large");
        maxPrice1e18 = v;
        emit MaxPriceSet(v);
    }

    // ── Views ────────────────────────────────────────────────────────────────

    /**
     * @inheritdoc IUsdValuer
     */
    function usdValue(address token, uint256 amount)
        external
        view
        override
        whenNotPaused
        returns (uint256)
    {
        require(token != address(0), "zero token");
        require(amount != 0, "zero amount");

        (uint256 px, uint8 pxDec, /*updatedAt*/) = _readChainlink(token);

        uint8 tkDec = IERC20Metadata(token).decimals();

        // Normalize token amount to 1e18
        uint256 amt1e18 = _to1e18(amount, tkDec);

        // Normalize price to 1e18
        uint256 px1e18 = _to1e18(px, pxDec);

        // USD (1e18) = amt1e18 * px1e18 / 1e18
        return (amt1e18 * px1e18) / 1e18;
    }

    /**
     * @notice Returns the latest price scaled to 1e18 and last update time.
     * @dev    DELIBERATELY not gated by pause so monitors can read during incidents.
     */
    function lastPrice1e18(address token) external view returns (uint256 price1e18, uint256 updatedAt) {
        require(token != address(0), "zero token");
        (uint256 px, uint8 pxDec, uint256 ts) = _readChainlink(token);
        return (_to1e18(px, pxDec), ts);
    }

    /**
     * @notice Quick helper for monitors: true if feed exists and not stale at the moment.
     * @dev    DELIBERATELY not gated by pause so monitors can read during incidents.
     */
    function isFresh(address token) external view returns (bool) {
        Feed memory f = feeds[token];
        if (address(f.agg) == address(0)) return false;

        (uint80 roundId, int256 answer, , uint256 updatedAt, uint80 answeredInRound) = f.agg.latestRoundData();

        if (answer <= 0 || updatedAt == 0) return false;
        if (answeredInRound < roundId) return false;
        if (f.staleAfter != 0 && block.timestamp - updatedAt > f.staleAfter) return false;

        // Optional extreme price cap in 1e18 units
        if (maxPrice1e18 != 0) {
            uint8 d = f.agg.decimals();
            uint256 px1e18 = _to1e18(uint256(answer), d);
            if (px1e18 > maxPrice1e18) return false;
        }
        return true;
        }

    // ── Internals ────────────────────────────────────────────────────────────

    /**
     * @dev Reads Chainlink with standard guards. Reverts if stale/invalid or exceeds optional cap.
     */
    function _readChainlink(address token) internal view returns (uint256 px, uint8 dec, uint256 updatedAt) {
        Feed memory f = feeds[token];
        if (address(f.agg) == address(0)) revert FeedNotSet();

        (uint80 roundId, int256 answer, , uint256 _updatedAt, uint80 answeredInRound) = f.agg.latestRoundData();

        // Basic sanity: non-zero update, positive answer
        if (answer <= 0 || _updatedAt == 0) revert BadAnswer();

        // Ensure we are not looking at an incomplete/carry-over round
        if (answeredInRound < roundId) revert StalePrice();

        // Optional staleness window (per-feed heartbeat)
        if (f.staleAfter != 0 && block.timestamp - _updatedAt > f.staleAfter) revert StalePrice();

        dec = f.agg.decimals();

        // Optional extreme price cap (compare in 1e18 units)
        if (maxPrice1e18 != 0) {
            uint256 px1e18 = _to1e18(uint256(answer), dec);
            if (px1e18 > maxPrice1e18) revert ExtremePrice();
        }

        px = uint256(answer);
        updatedAt = _updatedAt;
    }

    /**
     * @dev Scales an x with 'fromDec' decimals to 1e18 units.
     */
    function _to1e18(uint256 x, uint8 fromDec) internal pure returns (uint256) {
        if (fromDec == 18) return x;
        if (fromDec < 18) return x * (10 ** uint256(18 - fromDec));
        // fromDec > 18: integer division (truncates)
        return x / (10 ** uint256(fromDec - 18));
    }
}
