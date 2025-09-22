// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

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
 * Simple USD valuer: token amount -> USD 1e18 using Chainlink feeds.
 * Owner wires token -> aggregator; optional staleness window per feed.
 */
contract ChainlinkUsdValuer is Ownable {
    struct Feed {
        IAggregatorV3 agg;
        uint48  staleAfter; // seconds (0 = no staleness check)
    }

    mapping(address => Feed) public feeds; // token -> feed

    event FeedSet(address indexed token, address indexed aggregator, uint48 staleAfter);

    constructor(address initialOwner) Ownable(initialOwner) {}

    function setFeed(address token, address aggregator, uint48 staleAfter) external onlyOwner {
        feeds[token] = Feed(IAggregatorV3(aggregator), staleAfter);
        emit FeedSet(token, aggregator, staleAfter);
    }

    /// @notice Returns USD value scaled to 1e18
    function usdValue(address token, uint256 amount) external view returns (uint256) {
        Feed memory f = feeds[token];
        require(address(f.agg) != address(0), "no feed");

        (uint80 roundId, int256 price,, uint256 updatedAt, uint80 answeredInRound) = f.agg.latestRoundData();
        require(price > 0, "bad px");
        require(updatedAt != 0, "incomplete round");
        require(answeredInRound >= roundId, "stale round");

        if (f.staleAfter != 0) {
            require(block.timestamp - updatedAt <= f.staleAfter, "stale px");
        }

        uint8 pxDec = f.agg.decimals();
        uint8 tkDec = IERC20Metadata(token).decimals();

        // Normalize token amount to 1e18
        uint256 amt1e18 = amount;
        if (tkDec < 18) amt1e18 *= 10 ** (18 - tkDec);
        else if (tkDec > 18) amt1e18 /= 10 ** (tkDec - 18);

        // Normalize price to 1e18
        uint256 px1e18 = uint256(price);
        if (pxDec < 18) px1e18 *= 10 ** (18 - pxDec);
        else if (pxDec > 18) px1e18 /= 10 ** (pxDec - 18);

        // USD (1e18) = amt1e18 * px1e18 / 1e18
        return (amt1e18 * px1e18) / 1e18;
    }
}
