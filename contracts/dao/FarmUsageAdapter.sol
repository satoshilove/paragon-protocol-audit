// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.25;

import {SignedUsageAdapterBase} from "./SignedUsageAdapterBase.sol";

interface IUsagePointsFarmHook {
    function onLiquidityRetained(
        address user,
        uint256 usdValue1e18,
        bytes32 ref
    ) external;
}

contract FarmUsageAdapter is SignedUsageAdapterBase {
    IUsagePointsFarmHook public immutable usagePoints;

    event FarmRetentionRecorded(address indexed user, uint256 usdValue1e18, bytes32 indexed ref, uint256 epoch);

    constructor(
        address initialOwner,
        address usagePoints_
    ) SignedUsageAdapterBase(initialOwner) {
        require(usagePoints_ != address(0), "usage=0");
        usagePoints = IUsagePointsFarmHook(usagePoints_);
    }

    function _domainName() internal pure override returns (string memory) {
        return "ParagonFarmUsageAdapter";
    }

    function submitFarmRetainedLiquidity(
        UsageClaim calldata c,
        bytes calldata signature
    ) external whenNotPaused nonReentrant {
        _verifyAndConsume(c, signature);
        usagePoints.onLiquidityRetained(c.user, c.usdValue1e18, c.ref);
        emit FarmRetentionRecorded(c.user, c.usdValue1e18, c.ref, c.epoch);
    }
}
