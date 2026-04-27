// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.25;

import {SignedUsageAdapterBase} from "./SignedUsageAdapterBase.sol";

interface IUsagePointsHook {
    function onLiquidityAdded(
        address user,
        uint256 usdValue1e18,
        bytes32 ref
    ) external;

    function onLiquidityRetained(
        address user,
        uint256 usdValue1e18,
        bytes32 ref
    ) external;
}

contract LiquidityUsageAdapter is SignedUsageAdapterBase {
    IUsagePointsHook public immutable usagePoints;

    event LiquidityAddedRecorded(address indexed user, uint256 usdValue1e18, bytes32 indexed ref, uint256 epoch);
    event LiquidityRetainedRecorded(address indexed user, uint256 usdValue1e18, bytes32 indexed ref, uint256 epoch);

    constructor(
        address initialOwner,
        address usagePoints_
    ) SignedUsageAdapterBase(initialOwner) {
        require(usagePoints_ != address(0), "usage=0");
        usagePoints = IUsagePointsHook(usagePoints_);
    }

    function _domainName() internal pure override returns (string memory) {
        return "ParagonLiquidityUsageAdapter";
    }

    function submitLiquidityAdded(
        UsageClaim calldata c,
        bytes calldata signature
    ) external whenNotPaused nonReentrant {
        _verifyAndConsume(c, signature);
        usagePoints.onLiquidityAdded(c.user, c.usdValue1e18, c.ref);
        emit LiquidityAddedRecorded(c.user, c.usdValue1e18, c.ref, c.epoch);
    }

    function submitLiquidityRetained(
        UsageClaim calldata c,
        bytes calldata signature
    ) external whenNotPaused nonReentrant {
        _verifyAndConsume(c, signature);
        usagePoints.onLiquidityRetained(c.user, c.usdValue1e18, c.ref);
        emit LiquidityRetainedRecorded(c.user, c.usdValue1e18, c.ref, c.epoch);
    }
}
