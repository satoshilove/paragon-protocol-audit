// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";

import "./AggregatorV3Interface.sol";
import "./interfaces/IParagonPair.sol";
import "./interfaces/IParagonFactory.sol";

// -------------------- Custom Errors --------------------
error DivisionByZero();
error IdenticalAddresses();
error ZeroAddress();
error InvalidPath();
error NoFeed();
error InvalidPrice();
error StalePrice();
error InvalidStaleness();
error TimeWindowTooShort();
error PairNotInitialized();
error NoLiquidity();
error NoObservation();
error FeedDecimalsDiffTooLarge();
error TokenDecimalsDiffTooLarge();
error NotUpdater();

// -------------------- FixedPoint (Uniswap-style) --------------------
library FixedPoint {
    struct uq112x112 {
        uint224 _x;
    }
    uint8 private constant RESOLUTION = 112;

    function fraction(uint112 numerator, uint112 denominator) internal pure returns (uq112x112 memory) {
        if (denominator == 0) revert DivisionByZero();
        unchecked {
            return uq112x112((uint224(numerator) << RESOLUTION) / denominator);
        }
    }

    function mulDecode(uq112x112 memory self, uint256 y) internal pure returns (uint256) {
        uint256 z = uint256(self._x) * y;
        return z >> RESOLUTION;
    }
}

// -------------------- Oracle Library --------------------
library ParagonOracleLibrary {
    function currentBlockTimestamp() internal view returns (uint32) {
        return uint32(block.timestamp % 2**32);
    }

    function currentCumulativePrices(address pair)
        internal
        view
        returns (uint256 price0Cumulative, uint256 price1Cumulative, uint32 blockTimestamp)
    {
        blockTimestamp = currentBlockTimestamp();
        price0Cumulative = IParagonPair(pair).price0CumulativeLast();
        price1Cumulative = IParagonPair(pair).price1CumulativeLast();

        (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast) = IParagonPair(pair).getReserves();

        if (blockTimestampLast != blockTimestamp) {
            unchecked {
                uint32 timeElapsed = blockTimestamp - blockTimestampLast;
                price0Cumulative += uint256(FixedPoint.fraction(reserve1, reserve0)._x) * timeElapsed;
                price1Cumulative += uint256(FixedPoint.fraction(reserve0, reserve1)._x) * timeElapsed;
            }
        }
    }
}

// -------------------- ParagonOracle --------------------
contract ParagonOracle is Ownable {
    using FixedPoint for FixedPoint.uq112x112;

    // ────────────────────────────────────────────────
    // TWAP observation storage – RING BUFFER (PAD-29 FULL FIX)
    // 12 slots: covers ~12 min with 60s updates → safe for 600s default window
    // ────────────────────────────────────────────────
    struct Observation {
        uint256 price0Cumulative;
        uint256 price1Cumulative;
        uint32 timestamp;
    }

    struct ObsRing {
        Observation[12] obs;     // fixed-size circular buffer
        uint8 index;             // last written index (valid only when count > 0)
        uint8 count;             // number of valid observations written (≤12)
    }

    mapping(address => ObsRing) public observationRings; // pair => ring buffer

    uint32 public defaultTwapTimeWindow = 600;
    uint32 public minObservationPeriod = 60;

    // Chainlink config
    mapping(address => address) public chainlinkFeeds;
    mapping(address => uint256) public chainlinkStalenessThreshold;

    address public immutable factory;

    mapping(address => uint256) public adminUsdPrice1e18;
    mapping(address => bool) public adminPriceEnabled;

    mapping(address => bool) public isUpdater;

    // Events
    event ChainlinkFeedSet(address indexed token, address indexed feed, uint256 stalenessThreshold);
    event ChainlinkFeedRemoved(address indexed token);
    event TwapWindowUpdated(uint32 oldWindow, uint32 newWindow);
    event MinObservationPeriodUpdated(uint32 oldPeriod, uint32 newPeriod);
    event AdminPriceSet(address indexed token, uint256 price1e18, bool enabled);
    event ObservationUpdated(address indexed pair, uint256 p0, uint256 p1, uint32 ts, uint8 newIndex);
    event UpdaterSet(address indexed updater, bool allowed);

    uint8 private constant RING_SIZE = 12;

    constructor(address _factory) Ownable(msg.sender) {
        if (_factory == address(0)) revert ZeroAddress();
        factory = _factory;
        isUpdater[msg.sender] = true;
        emit UpdaterSet(msg.sender, true);
    }

    // ────────────────────────────────────────────────
    // Admin setters
    // ────────────────────────────────────────────────
    function setUpdater(address updater, bool allowed) external onlyOwner {
        if (updater == address(0)) revert ZeroAddress();
        isUpdater[updater] = allowed;
        emit UpdaterSet(updater, allowed);
    }

    function setChainlinkFeed(address token, address feed, uint256 stalenessThreshold) external onlyOwner {
        if (token == address(0) || feed == address(0)) revert ZeroAddress();
        if (stalenessThreshold == 0) revert InvalidStaleness();
        chainlinkFeeds[token] = feed;
        chainlinkStalenessThreshold[token] = stalenessThreshold;
        emit ChainlinkFeedSet(token, feed, stalenessThreshold);
    }

    function removeChainlinkFeed(address token) external onlyOwner {
        if (token == address(0)) revert ZeroAddress();
        delete chainlinkFeeds[token];
        delete chainlinkStalenessThreshold[token];
        emit ChainlinkFeedRemoved(token);
    }

    function setDefaultTwapTimeWindow(uint32 _timeWindow) external onlyOwner {
        if (_timeWindow < 60) revert TimeWindowTooShort();
        uint32 oldWindow = defaultTwapTimeWindow;
        defaultTwapTimeWindow = _timeWindow;
        emit TwapWindowUpdated(oldWindow, _timeWindow);
    }

    function setMinObservationPeriod(uint32 _period) external onlyOwner {
        uint32 old = minObservationPeriod;
        minObservationPeriod = _period;
        emit MinObservationPeriodUpdated(old, _period);
    }

    function setAdminPrice(address token, uint256 price1e18, bool enabled) external onlyOwner {
        if (token == address(0)) revert ZeroAddress();
        if (enabled && price1e18 == 0) revert InvalidPrice();
        adminUsdPrice1e18[token] = price1e18;
        adminPriceEnabled[token] = enabled;
        emit AdminPriceSet(token, price1e18, enabled);
    }

    // ────────────────────────────────────────────────
    // Utils
    // ────────────────────────────────────────────────
    function sortTokens(address tokenA, address tokenB) public pure returns (address token0, address token1) {
        if (tokenA == tokenB) revert IdenticalAddresses();
        (token0, token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        if (token0 == address(0)) revert ZeroAddress();
    }

    function pairFor(address tokenA, address tokenB) public view returns (address pair) {
        (address token0, address token1) = sortTokens(tokenA, tokenB);
        bytes32 initHash = IParagonFactory(factory).INIT_CODE_PAIR_HASH();
        pair = address(
            uint160(
                uint256(
                    keccak256(
                        abi.encodePacked(
                            hex"ff",
                            factory,
                            keccak256(abi.encodePacked(token0, token1)),
                            initHash
                        )
                    )
                )
            )
        );
    }

    function _safeTokenDecimals(address token) internal view returns (uint8) {
        try IERC20Metadata(token).decimals() returns (uint8 d) {
            return d;
        } catch {
            return 18;
        }
    }

    function _pow10Feed(uint256 n) internal pure returns (uint256) {
        if (n > 18) revert FeedDecimalsDiffTooLarge();
        return 10 ** n;
    }

    function _pow10Token(uint256 n) internal pure returns (uint256) {
        if (n > 18) revert TokenDecimalsDiffTooLarge();
        return 10 ** n;
    }

    // ────────────────────────────────────────────────
    // Chainlink
    // ────────────────────────────────────────────────
    function getChainlinkPrice(address token) public view returns (int256) {
        address feed = chainlinkFeeds[token];
        if (feed == address(0)) revert NoFeed();
        (, int256 price, , uint256 updatedAt, ) = AggregatorV3Interface(feed).latestRoundData();
        if (price <= 0) revert InvalidPrice();
        uint256 staleness = chainlinkStalenessThreshold[token];
        if (staleness == 0) revert InvalidStaleness();
        if (block.timestamp - updatedAt > staleness) revert StalePrice();
        return price;
    }

    function getAmountsOutUsingChainlink(uint256 amountIn, address[] memory path)
        public
        view
        returns (uint256[] memory amounts)
    {
        if (path.length < 2 || path.length > 5) revert InvalidPath();
        amounts = new uint256[](path.length);
        amounts[0] = amountIn;

        for (uint256 i = 0; i < path.length - 1; ++i) {
            address tIn = path[i];
            address tOut = path[i + 1];

            uint256 pIn = uint256(getChainlinkPrice(tIn));
            uint256 pOut = uint256(getChainlinkPrice(tOut));

            uint8 fdIn = AggregatorV3Interface(chainlinkFeeds[tIn]).decimals();
            uint8 fdOut = AggregatorV3Interface(chainlinkFeeds[tOut]).decimals();

            if (fdIn < fdOut) pIn *= _pow10Feed(uint256(fdOut - fdIn));
            else if (fdOut < fdIn) pOut *= _pow10Feed(uint256(fdIn - fdOut));

            uint256 out = Math.mulDiv(amounts[i], pIn, pOut);

            uint8 dIn = _safeTokenDecimals(tIn);
            uint8 dOut = _safeTokenDecimals(tOut);

            if (dOut > dIn) out *= _pow10Token(uint256(dOut - dIn));
            else if (dIn > dOut) out /= _pow10Token(uint256(dIn - dOut));

            amounts[i + 1] = out;
        }
    }

    // ────────────────────────────────────────────────
    // TWAP – Ring Buffer Update (fixed first-write + prev selection)
    // ────────────────────────────────────────────────
    function updateObservation(address tokenA, address tokenB) external returns (bool updated) {
        if (!isUpdater[msg.sender]) revert NotUpdater();

        address pair = pairFor(tokenA, tokenB);

        (uint112 r0, uint112 r1, uint32 tsLast) = IParagonPair(pair).getReserves();
        if (tsLast == 0) revert PairNotInitialized();
        if (r0 == 0 || r1 == 0) revert NoLiquidity();

        (uint256 p0, uint256 p1, uint32 ts) = ParagonOracleLibrary.currentCumulativePrices(pair);

        ObsRing storage ring = observationRings[pair];

        // last observation (only meaningful once count > 0)
        Observation memory prev = ring.count == 0 ? Observation(0, 0, 0) : ring.obs[ring.index];

        if (prev.timestamp != 0) {
            unchecked {
                uint32 elapsed = ts - prev.timestamp;
                if (elapsed < minObservationPeriod) return false;
            }
        }

        // first write goes to slot 0; then circular
        uint8 next = ring.count == 0 ? 0 : uint8((ring.index + 1) % RING_SIZE);

        ring.obs[next] = Observation({
            price0Cumulative: p0,
            price1Cumulative: p1,
            timestamp: ts
        });

        ring.index = next;

        if (ring.count < RING_SIZE) ring.count++;

        emit ObservationUpdated(pair, p0, p1, ts, next);
        return true;
    }

    // ────────────────────────────────────────────────
    // Select newest observation old enough for the required window
    // ────────────────────────────────────────────────
    function _selectObservation(address pair, uint32 nowTs, uint32 requiredWindow)
        internal
        view
        returns (Observation memory chosen, bool ok)
    {
        ObsRing storage ring = observationRings[pair];
        if (ring.count == 0) return (Observation(0, 0, 0), false);

        // clamp to avoid underflow
        uint32 cutoff = nowTs > requiredWindow ? nowTs - requiredWindow : 0;

        // Walk backwards from newest to oldest
        for (uint8 k = 0; k < ring.count; ++k) {
            uint8 idx = uint8((RING_SIZE + ring.index - k) % RING_SIZE);
            Observation memory o = ring.obs[idx];
            if (o.timestamp != 0 && o.timestamp <= cutoff) {
                return (o, true);
            }
        }

        return (Observation(0, 0, 0), false);
    }

    // ────────────────────────────────────────────────
    // Core TWAP computation using ring buffer
    // ────────────────────────────────────────────────
    function _twapPriceAvgOrZero(address tokenIn, address tokenOut, uint32 window)
        internal
        view
        returns (FixedPoint.uq112x112 memory priceAvg, bool ok)
    {
        address pair = pairFor(tokenIn, tokenOut);

        uint112 r0;
        uint112 r1;
        uint32 tsLast;
        try IParagonPair(pair).getReserves() returns (uint112 _r0, uint112 _r1, uint32 _tsLast) {
            r0 = _r0;
            r1 = _r1;
            tsLast = _tsLast;
        } catch {
            return (FixedPoint.uq112x112(0), false);
        }

        if (tsLast == 0 || r0 == 0 || r1 == 0) return (FixedPoint.uq112x112(0), false);

        (uint256 p0, uint256 p1, uint32 nowTs) = ParagonOracleLibrary.currentCumulativePrices(pair);

        uint32 required = window == 0 ? defaultTwapTimeWindow : window;

        (Observation memory startObs, bool haveObs) = _selectObservation(pair, nowTs, required);
        if (!haveObs) return (FixedPoint.uq112x112(0), false);

        // Monotonicity check
        if (p0 < startObs.price0Cumulative || p1 < startObs.price1Cumulative) {
            return (FixedPoint.uq112x112(0), false);
        }

        uint32 elapsed = nowTs - startObs.timestamp;
        if (elapsed == 0 || elapsed < required) return (FixedPoint.uq112x112(0), false);

        (address token0, ) = sortTokens(tokenIn, tokenOut);

        uint256 p0Avg = (p0 - startObs.price0Cumulative) / elapsed;
        uint256 p1Avg = (p1 - startObs.price1Cumulative) / elapsed;

        if (p0Avg > type(uint224).max || p1Avg > type(uint224).max) {
            return (FixedPoint.uq112x112(0), false);
        }

        priceAvg = (tokenIn == token0)
            ? FixedPoint.uq112x112(uint224(p0Avg))
            : FixedPoint.uq112x112(uint224(p1Avg));

        return (priceAvg, true);
    }

    function _twapOutOrZero(address tokenIn, address tokenOut, uint256 amountIn, uint32 window)
        internal
        view
        returns (uint256 out)
    {
        (FixedPoint.uq112x112 memory priceAvg, bool ok) = _twapPriceAvgOrZero(tokenIn, tokenOut, window);
        if (!ok) return 0;
        return priceAvg.mulDecode(amountIn);
    }

    // ────────────────────────────────────────────────
    // Public TWAP wrappers
    // ────────────────────────────────────────────────
    function getTwapAmountOut(uint256 amountIn, address tokenIn, address tokenOut, uint32 minTimeWindow)
        public
        view
        returns (uint256 amountOut)
    {
        uint32 w = minTimeWindow == 0 ? defaultTwapTimeWindow : minTimeWindow;
        amountOut = _twapOutOrZero(tokenIn, tokenOut, amountIn, w);
        if (amountOut == 0) revert NoObservation();
    }

    function getAmountsOutUsingTwap(uint256 amountIn, address[] memory path, uint32 timeWindow)
        public
        view
        returns (uint256[] memory amounts)
    {
        if (path.length < 2 || path.length > 5) revert InvalidPath();
        uint32 w = timeWindow == 0 ? defaultTwapTimeWindow : timeWindow;

        amounts = new uint256[](path.length);
        amounts[0] = amountIn;

        for (uint256 i = 0; i < path.length - 1; ++i) {
            uint256 outAmt = _twapOutOrZero(path[i], path[i + 1], amounts[i], w);
            if (outAmt == 0) revert NoObservation();
            amounts[i + 1] = outAmt;
        }
    }

    function consult(address tokenIn, uint256 amountIn, address tokenOut) external view returns (uint256 amountOut) {
        amountOut = _twapOutOrZero(tokenIn, tokenOut, amountIn, defaultTwapTimeWindow);
        if (amountOut == 0) revert NoObservation();
    }

    function consultIn(address tokenIn, address tokenOut, uint256 amountOut) external view returns (uint256 amountIn) {
        (FixedPoint.uq112x112 memory priceAvg, bool ok) = _twapPriceAvgOrZero(tokenIn, tokenOut, defaultTwapTimeWindow);
        if (!ok || priceAvg._x == 0) revert NoObservation();

        uint256 numerator = amountOut * (uint256(1) << 112);
        amountIn = (numerator + uint256(priceAvg._x) - 1) / uint256(priceAvg._x);
        if (amountIn == 0) revert NoObservation();
    }

    // ────────────────────────────────────────────────
    // Price validation & View helpers
    // ────────────────────────────────────────────────
    function validateOraclePrice(
        uint256 amountIn,
        uint256 amountOut,
        address[] memory path,
        uint256 maxSlippageBips,
        bool useChainlink
    ) external view returns (bool) {
        uint256 oracleOut;

        if (useChainlink) {
            uint256[] memory oracleAmounts = getAmountsOutUsingChainlink(amountIn, path);
            oracleOut = oracleAmounts[oracleAmounts.length - 1];
        } else {
            uint256[] memory oracleAmounts = getAmountsOutUsingTwap(amountIn, path, defaultTwapTimeWindow);
            oracleOut = oracleAmounts[oracleAmounts.length - 1];
        }

        uint256 minOut = (oracleOut * (10000 - maxSlippageBips)) / 10000;
        return amountOut >= minOut;
    }

    function hasChainlinkFeed(address token) external view returns (bool) {
        return chainlinkFeeds[token] != address(0);
    }

    function getChainlinkFeedInfo(address token)
        external
        view
        returns (address feed, uint256 stalenessThreshold, bool isActive)
    {
        feed = chainlinkFeeds[token];
        stalenessThreshold = chainlinkStalenessThreshold[token];
        isActive = (feed != address(0));
    }

    function canUseTwap(address tokenA, address tokenB, uint32 minTimeWindow)
        external
        view
        returns (bool canUse, string memory reason)
    {
        address pair = pairFor(tokenA, tokenB);
        uint32 required = minTimeWindow == 0 ? defaultTwapTimeWindow : minTimeWindow;

        try IParagonPair(pair).getReserves() returns (uint112 r0, uint112 r1, uint32 tsLast) {
            if (tsLast == 0) return (false, "Pair not initialized");
            if (r0 == 0 || r1 == 0) return (false, "No liquidity");
        } catch {
            return (false, "Pair does not exist");
        }

        uint32 nowTs = uint32(block.timestamp % 2**32);
        (Observation memory obs, bool have) = _selectObservation(pair, nowTs, required);
        if (!have) return (false, "No observation old enough");

        uint32 elapsed = nowTs - obs.timestamp;
        if (elapsed < required) return (false, "Insufficient observation age");

        return (true, "");
    }

    // ────────────────────────────────────────────────
    // USD helpers
    // ────────────────────────────────────────────────
    function _usdPrice1e18(address token, address usdt, address wbnb) internal view returns (uint256) {
        if (token == address(0) || usdt == address(0) || wbnb == address(0)) return 0;

        if (adminPriceEnabled[token] && adminUsdPrice1e18[token] > 0) {
            return adminUsdPrice1e18[token];
        }

        if (chainlinkFeeds[token] != address(0)) {
            uint256 p = uint256(getChainlinkPrice(token));
            uint8 fd = AggregatorV3Interface(chainlinkFeeds[token]).decimals();
            if (fd < 18) return p * _pow10Feed(18 - fd);
            if (fd > 18) return p / _pow10Feed(fd - 18);
            return p;
        }

        uint8 dec = _safeTokenDecimals(token);
        uint256 one = 10 ** uint256(dec);

        uint256 outUsdt = _twapOutOrZero(token, usdt, one, defaultTwapTimeWindow);
        if (outUsdt > 0) return outUsdt;

        uint256 outWbnb = _twapOutOrZero(token, wbnb, one, defaultTwapTimeWindow);
        if (outWbnb == 0) return 0;

        if (chainlinkFeeds[wbnb] != address(0)) {
            uint256 wUsd = uint256(getChainlinkPrice(wbnb));
            uint8 fdbn = AggregatorV3Interface(chainlinkFeeds[wbnb]).decimals();
            if (fdbn < 18) wUsd *= _pow10Feed(18 - fdbn);
            else if (fdbn > 18) wUsd /= _pow10Feed(fdbn - 18);
            uint8 wDec = _safeTokenDecimals(wbnb);
            return Math.mulDiv(outWbnb, wUsd, 10 ** uint256(wDec));
        }

        return _twapOutOrZero(wbnb, usdt, outWbnb, defaultTwapTimeWindow);
    }

    function priceUsd1e18(address token, address usdt, address wbnb) external view returns (uint256) {
        return _usdPrice1e18(token, usdt, wbnb);
    }

    function valueUsd1e18(address token, uint256 amountIn, address usdt, address wbnb)
        external
        view
        returns (uint256)
    {
        uint256 p = _usdPrice1e18(token, usdt, wbnb);
        if (p == 0) return 0;
        uint8 dec = _safeTokenDecimals(token);
        return Math.mulDiv(amountIn, p, 10 ** uint256(dec));
    }
}
