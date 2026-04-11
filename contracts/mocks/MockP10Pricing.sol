// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {IP10Pricing} from "../p10/interfaces/IP10Core.sol";

contract MockP10Pricing is IP10Pricing {
    struct PriceData {
        uint256 priceE18;
        uint256 updatedAt;
        bool isSafe;
    }

    mapping(address => PriceData) public prices;

    function setPrice(address token, uint256 priceE18, bool isSafe) external {
        prices[token] = PriceData({
            priceE18: priceE18,
            updatedAt: block.timestamp,
            isSafe: isSafe
        });
    }

    function getSafePriceUSD(
        address token
    ) external view override returns (uint256 priceE18, uint256 updatedAt, bool isSafe) {
        PriceData memory data = prices[token];
        return (data.priceE18, data.updatedAt, data.isSafe);
    }
}
