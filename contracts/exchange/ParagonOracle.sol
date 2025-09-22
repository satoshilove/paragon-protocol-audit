// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "./AggregatorV3Interface.sol";

// Paragon interfaces
import "./interfaces/IParagonPair.sol";
import "./interfaces/IParagonFactory.sol";

// Custom errors
error DivisionByZero();
error MultiplicationOverflow();
error IdenticalAddresses();
error ZeroAddress();
error InvalidPath();
error InsufficientTwapTime();
error InsufficientLiquidity();
error NoFeed();
error InvalidPrice();
error StalePrice();
error InvalidStaleness();
error TimeWindowTooShort();

library FixedPoint {
    struct uq112x112 { uint224 _x; }
    struct uq144x112 { uint256 _x; }

    uint8 private constant RESOLUTION = 112;

    function fraction(uint112 numerator, uint112 denominator) internal pure returns (uq112x112 memory) {
        unchecked {
            if (denominator == 0) revert DivisionByZero();
            return uq112x112((uint224(numerator) << RESOLUTION) / denominator);
        }
    }

    function mul(uq112x112 memory self, uint256 y) internal pure returns (uq144x112 memory) {
        uint256 z = 0;
        unchecked { z = uint256(self._x) * y; }
        if (z > type(uint256).max) revert MultiplicationOverflow();
        return uq144x112(z);
    }

    function decode144(uq144x112 memory self) internal pure returns (uint256) {
        return self._x >> RESOLUTION;
    }
}

library ParagonOracleLibrary {
    using FixedPoint for *;

    struct TwapParams {
        uint256 price0Cumulative;
        uint256 price1Cumulative;
        uint32  blockTimestamp;
        uint256 price0CumulativeLast;
        uint256 price1CumulativeLast;
        uint32  blockTimestampLast;
        uint112 reserve0;
        uint112 reserve1;
    }

    function currentBlockTimestamp() internal view returns (uint32) {
        return uint32(block.timestamp % 2**32);
    }

    function currentCumulativePrices(address pair)
        public
        view
        returns (uint256 price0Cumulative, uint256 price1Cumulative, uint32 blockTimestamp)
    {
        blockTimestamp = currentBlockTimestamp();
        price0Cumulative = IParagonPair(pair).price0CumulativeLast();
        price1Cumulative = IParagonPair(pair).price1CumulativeLast();

        (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast) = IParagonPair(pair).getReserves();
        if (blockTimestampLast != blockTimestamp) {
            uint32 timeElapsed = blockTimestamp - blockTimestampLast;
            price0Cumulative += uint256(FixedPoint.fraction(reserve1, reserve0)._x) * timeElapsed;
            price1Cumulative += uint256(FixedPoint.fraction(reserve0, reserve1)._x) * timeElapsed;
        }
    }

    function calculateTwapAmountOut(
        uint256 amountIn,
        address tokenIn,
        address tokenOut,
        uint32  minTimeWindow,
        TwapParams memory params
    ) internal pure returns (uint256 amountOut) {
        (address token0, ) = _sortTokens(tokenIn, tokenOut);

        if (params.blockTimestampLast == 0) revert InsufficientTwapTime();
        if (params.reserve0 == 0 || params.reserve1 == 0) revert InsufficientLiquidity();

        uint32 timeElapsed = params.blockTimestamp - params.blockTimestampLast;
        if (timeElapsed < minTimeWindow) revert InsufficientTwapTime();

        uint224 price0AverageRaw = uint224((params.price0Cumulative - params.price0CumulativeLast) / timeElapsed);
        uint224 price1AverageRaw = uint224((params.price1Cumulative - params.price1CumulativeLast) / timeElapsed);
        FixedPoint.uq112x112 memory priceAverage = tokenIn == token0
            ? FixedPoint.uq112x112(price0AverageRaw)
            : FixedPoint.uq112x112(price1AverageRaw);

        amountOut = priceAverage.mul(amountIn).decode144();
    }

    function _sortTokens(address tokenA, address tokenB) private pure returns (address token0, address token1) {
        if (tokenA == tokenB) revert IdenticalAddresses();
        (token0, token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        if (token0 == address(0)) revert ZeroAddress();
    }
}

contract ParagonOracle is Ownable {
    using FixedPoint for *;

    // Chainlink config
    mapping(address => address) public chainlinkFeeds;               // token => feed
    mapping(address => uint256) public chainlinkStalenessThreshold;  // token => seconds
    uint32 public defaultTwapTimeWindow = 600; // 10 minutes

    // Factory for TWAP
    address public immutable factory;

    // Admin USD overrides (1e18 = $1)
    mapping(address => uint256) public adminUsdPrice1e18;
    mapping(address => bool)    public adminPriceEnabled;

    // Events
    event ChainlinkFeedSet(address indexed token, address indexed feed, uint256 stalenessThreshold);
    event TwapWindowUpdated(uint32 oldWindow, uint32 newWindow);
    event AdminPriceSet(address indexed token, uint256 price1e18, bool enabled);

    constructor(address _factory) Ownable(msg.sender) {
        factory = _factory;
    }

    // -------- Admin setters --------
    function setChainlinkFeed(address token, address feed, uint256 stalenessThreshold) external onlyOwner {
        if (token == address(0) || feed == address(0)) revert ZeroAddress();
        if (stalenessThreshold == 0) revert InvalidStaleness();
        chainlinkFeeds[token] = feed;
        chainlinkStalenessThreshold[token] = stalenessThreshold;
        emit ChainlinkFeedSet(token, feed, stalenessThreshold);
    }

    function setDefaultTwapTimeWindow(uint32 _timeWindow) external onlyOwner {
        if (_timeWindow < 60) revert TimeWindowTooShort();
        uint32 oldWindow = defaultTwapTimeWindow;
        defaultTwapTimeWindow = _timeWindow;
        emit TwapWindowUpdated(oldWindow, _timeWindow);
    }

    function setAdminPrice(address token, uint256 price1e18, bool enabled) external onlyOwner {
        if (token == address(0)) revert ZeroAddress();
        if (enabled && price1e18 == 0) revert InvalidPrice();
        adminUsdPrice1e18[token] = price1e18;
        adminPriceEnabled[token] = enabled;
        emit AdminPriceSet(token, price1e18, enabled);
    }

    // -------- Utils --------
    function sortTokens(address tokenA, address tokenB) public pure returns (address token0, address token1) {
        if (tokenA == tokenB) revert IdenticalAddresses();
        (token0, token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        if (token0 == address(0)) revert ZeroAddress();
    }

    function pairFor(address tokenA, address tokenB) public view returns (address pair) {
        (address token0, address token1) = sortTokens(tokenA, tokenB);
        bytes32 initHash = IParagonFactory(factory).INIT_CODE_PAIR_HASH();
        pair = address(uint160(uint256(keccak256(abi.encodePacked(
            hex"ff",
            factory,
            keccak256(abi.encodePacked(token0, token1)),
            initHash
        )))));
    }

    function mulDiv(uint256 a, uint256 b, uint256 c) public pure returns (uint256) {
        if (a == 0 || b == 0) return 0;
        if (c == 0) revert DivisionByZero();
        if (a > type(uint256).max / b) {
            return (a / c) * b + ((a % c) * b) / c;
        } else {
            return (a * b) / c;
        }
    }

    // -------- Chainlink --------
    function getChainlinkPrice(address token) public view returns (int256) {
        address feed = chainlinkFeeds[token];
        if (feed == address(0)) revert NoFeed();
        (, int256 price, , uint256 updatedAt, ) = AggregatorV3Interface(feed).latestRoundData();
        if (price <= 0) revert InvalidPrice();
        uint256 staleness = chainlinkStalenessThreshold[token];
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
            int256 priceIn  = getChainlinkPrice(path[i]);
            int256 priceOut = getChainlinkPrice(path[i + 1]);

            uint8 decimalsIn  = IERC20Metadata(path[i]).decimals();
            uint8 decimalsOut = IERC20Metadata(path[i + 1]).decimals();
            uint8 feedDecimalsIn  = AggregatorV3Interface(chainlinkFeeds[path[i]]).decimals();
            uint8 feedDecimalsOut = AggregatorV3Interface(chainlinkFeeds[path[i + 1]]).decimals();

            uint256 baseAmount  = amounts[i];
            uint256 scaledAmount = mulDiv(baseAmount, uint256(priceIn), uint256(priceOut));

            if (decimalsOut > decimalsIn) {
                uint256 diff = uint256(decimalsOut - decimalsIn);
                if (diff <= 18) { scaledAmount = scaledAmount * (10 ** diff); }
            } else if (decimalsIn > decimalsOut) {
                uint256 diff = uint256(decimalsIn - decimalsOut);
                scaledAmount = scaledAmount / (10 ** diff);
            }

            if (feedDecimalsOut > feedDecimalsIn) {
                uint256 fd = uint256(feedDecimalsOut - feedDecimalsIn);
                if (fd <= 18) { scaledAmount = scaledAmount * (10 ** fd); }
            } else if (feedDecimalsIn > feedDecimalsOut) {
                uint256 fd = uint256(feedDecimalsIn - feedDecimalsOut);
                scaledAmount = scaledAmount / (10 ** fd);
            }

            amounts[i + 1] = scaledAmount;
        }
    }

    // -------- TWAP helpers (single return; 0 on failure) --------
    function _safeTokenDecimals(address token) internal view returns (uint8) {
        try IERC20Metadata(token).decimals() returns (uint8 d) { return d; }
        catch { return 18; }
    }

    function _twapAmountOutOrZero(address tokenIn, address tokenOut, uint256 amountIn, uint32 window)
        internal
        view
        returns (uint256)
    {
        address pair = pairFor(tokenIn, tokenOut);
        // If pair missing or calls revert, return 0
        try IParagonPair(pair).getReserves() returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast) {
            (uint256 p0, uint256 p1, uint32 ts) = ParagonOracleLibrary.currentCumulativePrices(pair);
            ParagonOracleLibrary.TwapParams memory params = ParagonOracleLibrary.TwapParams({
                price0Cumulative: p0,
                price1Cumulative: p1,
                blockTimestamp: ts,
                price0CumulativeLast: IParagonPair(pair).price0CumulativeLast(),
                price1CumulativeLast: IParagonPair(pair).price1CumulativeLast(),
                blockTimestampLast: blockTimestampLast,
                reserve0: reserve0,
                reserve1: reserve1
            });
            // catch insufficient time/liquidity by returning 0
            try this._calcTwap(amountIn, tokenIn, tokenOut, window == 0 ? defaultTwapTimeWindow : window, params) returns (uint256 outAmt) {
                return outAmt;
            } catch { return 0; }
        } catch { return 0; }
    }

    // tiny external-view trampoline so we can try/catch a pure calc path
    function _calcTwap(
        uint256 amountIn,
        address tokenIn,
        address tokenOut,
        uint32 window,
        ParagonOracleLibrary.TwapParams memory params
    ) external pure returns (uint256) {
        return ParagonOracleLibrary.calculateTwapAmountOut(amountIn, tokenIn, tokenOut, window, params);
    }

    // Public TWAP wrappers (kept for compatibility)
    function getTwapAmountOut(uint256 amountIn, address tokenIn, address tokenOut, uint32 minTimeWindow)
        public
        view
        returns (uint256 amountOut)
    {
        uint32 w = (minTimeWindow == 0) ? defaultTwapTimeWindow : minTimeWindow;
        amountOut = _twapAmountOutOrZero(tokenIn, tokenOut, amountIn, w);
        if (amountOut == 0) revert InsufficientLiquidity();
    }

    function getAmountsOutUsingTwap(uint256 amountIn, address[] memory path, uint32 timeWindow)
        public
        view
        returns (uint256[] memory amounts)
    {
        if (path.length < 2 || path.length > 5) revert InvalidPath();
        uint32 w = (timeWindow == 0) ? defaultTwapTimeWindow : timeWindow;
        amounts = new uint256[](path.length);
        amounts[0] = amountIn;
        for (uint256 i = 0; i < path.length - 1; ++i) {
            uint256 outAmt = _twapAmountOutOrZero(path[i], path[i + 1], amounts[i], w);
            if (outAmt == 0) revert InsufficientLiquidity();
            amounts[i + 1] = outAmt;
        }
    }

    // -------- Price validation --------
    function validateOraclePrice(
        uint256 amountIn,
        uint256 amountOut,
        address[] memory path,
        uint256 maxSlippageBips,
        bool useChainlink
    ) external view returns (bool) {
        uint256 oracleAmountOut;
        if (useChainlink) {
            uint256[] memory oracleAmounts = getAmountsOutUsingChainlink(amountIn, path);
            oracleAmountOut = oracleAmounts[oracleAmounts.length - 1];
        } else {
            uint256[] memory oracleAmounts = getAmountsOutUsingTwap(amountIn, path, defaultTwapTimeWindow);
            oracleAmountOut = oracleAmounts[oracleAmounts.length - 1];
        }
        return amountOut >= (oracleAmountOut * (10000 - maxSlippageBips)) / 10000;
    }

    // -------- Misc helpers --------
    function hasChainlinkFeed(address token) external view returns (bool) {
        return chainlinkFeeds[token] != address(0);
    }

    function getChainlinkFeedInfo(address token) external view returns (address feed, uint256 stalenessThreshold, bool isActive) {
        feed = chainlinkFeeds[token];
        stalenessThreshold = chainlinkStalenessThreshold[token];
        isActive = feed != address(0);
    }

    function isPairInitialized(address tokenA, address tokenB) external view returns (bool) {
        address pair = pairFor(tokenA, tokenB);
        try IParagonPair(pair).getReserves() returns (uint112, uint112, uint32 timestamp) {
            return timestamp > 0;
        } catch { return false; }
    }

    function getChainlinkPrices(address[] calldata tokens) external view returns (int256[] memory prices, bool[] memory valid) {
        prices = new int256[](tokens.length);
        valid = new bool[](tokens.length);
        for (uint256 i = 0; i < tokens.length; i++) {
            try this.getChainlinkPrice(tokens[i]) returns (int256 price) {
                prices[i] = price; valid[i] = true;
            } catch {
                prices[i] = 0; valid[i] = false;
            }
        }
    }

    function removeChainlinkFeed(address token) external onlyOwner {
        delete chainlinkFeeds[token];
        delete chainlinkStalenessThreshold[token];
        emit ChainlinkFeedSet(token, address(0), 0);
    }

    function canUseTwap(address tokenA, address tokenB, uint32 minTimeWindow) external view returns (bool canUse, string memory reason) {
        address pair = pairFor(tokenA, tokenB);
        try IParagonPair(pair).getReserves() returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast) {
            if (blockTimestampLast == 0) return (false, "Pair not initialized");
            uint32 timeElapsed = uint32(block.timestamp % 2**32) - blockTimestampLast;
            if (timeElapsed < minTimeWindow) return (false, "Insufficient time elapsed");
            if (reserve0 == 0 || reserve1 == 0) return (false, "No liquidity");
            return (true, "");
        } catch {
            return (false, "Pair does not exist");
        }
    }

    function consult(address tokenIn, uint256 amountIn, address tokenOut) external view returns (uint256 amountOut) {
        return getTwapAmountOut(amountIn, tokenIn, tokenOut, defaultTwapTimeWindow);
    }

    function consultIn(address tokenIn, address tokenOut, uint256 amountOut) external view returns (uint256 amountIn) {
        uint8 decimalsIn = _safeTokenDecimals(tokenIn);
        uint256 oneUnit = 10 ** uint256(decimalsIn);
        uint256 amountOutForOneUnit = getTwapAmountOut(oneUnit, tokenIn, tokenOut, defaultTwapTimeWindow);
        if (amountOutForOneUnit == 0) revert InsufficientLiquidity();
        amountIn = mulDiv(amountOut, oneUnit, amountOutForOneUnit);
    }

    // -------- Unified USD price helpers --------
    function _usdPrice1e18(address token, address usdt, address wbnb) internal view returns (uint256) {
        // 1) Admin override
        if (adminPriceEnabled[token]) {
            uint256 p0 = adminUsdPrice1e18[token];
            if (p0 > 0) return p0;
        }

        // 2) Chainlink direct (token/USD)
        if (chainlinkFeeds[token] != address(0)) {
            int256 p1 = getChainlinkPrice(token);
            uint8 fd1 = AggregatorV3Interface(chainlinkFeeds[token]).decimals();
            uint256 pu1 = uint256(p1);
            if (fd1 < 18)      return pu1 * (10 ** uint256(18 - fd1));
            else if (fd1 > 18) return pu1 / (10 ** uint256(fd1 - 18));
            else               return pu1;
        }

        // Build 1 token input based on its decimals
        uint8 decIn = _safeTokenDecimals(token);
        uint256 amountIn = 10 ** uint256(decIn);

        // 3) TWAP token -> USDT (USDT≈$1)
        {
            uint256 outUsdt = _twapAmountOutOrZero(token, usdt, amountIn, defaultTwapTimeWindow);
            if (outUsdt > 0) return outUsdt; // if USDT has 18 decimals (mock), this is 1e18 USD
        }

        // 4) token -> WBNB TWAP then WBNB/USD via Chainlink or WBNB->USDT TWAP
        uint256 wbnbOut = _twapAmountOutOrZero(token, wbnb, amountIn, defaultTwapTimeWindow);
        if (wbnbOut == 0) return 0;

        // 4a) WBNB/USD via Chainlink
        if (chainlinkFeeds[wbnb] != address(0)) {
            int256 pbn = getChainlinkPrice(wbnb);
            uint8  fdbn = AggregatorV3Interface(chainlinkFeeds[wbnb]).decimals();
            uint256 wbnbUsd1e18 = uint256(pbn);
            if (fdbn < 18)      wbnbUsd1e18 = wbnbUsd1e18 * (10 ** uint256(18 - fdbn));
            else if (fdbn > 18) wbnbUsd1e18 = wbnbUsd1e18 / (10 ** uint256(fdbn - 18));
            uint8 wdec = _safeTokenDecimals(wbnb);
            return mulDiv(wbnbOut, wbnbUsd1e18, 10 ** uint256(wdec));
        }

        // 4b) WBNB -> USDT TWAP (USDT≈$1)
        uint256 usdViaUsdt = _twapAmountOutOrZero(wbnb, usdt, wbnbOut, defaultTwapTimeWindow);
        return usdViaUsdt; // 0 if not available
    }

    function priceUsd1e18(address token, address usdt, address wbnb) external view returns (uint256) {
        return _usdPrice1e18(token, usdt, wbnb);
    }

    function valueUsd1e18(address token, uint256 amountIn, address usdt, address wbnb) external view returns (uint256) {
        uint256 p = _usdPrice1e18(token, usdt, wbnb);
        if (p == 0) return 0;
        uint8 dec = _safeTokenDecimals(token);
        return mulDiv(amountIn, p, 10 ** uint256(dec));
    }
}
