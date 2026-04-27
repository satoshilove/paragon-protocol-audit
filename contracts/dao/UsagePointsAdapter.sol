// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.25;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

interface IUsagePointsHook {
    function onPayflowExecuted(
        address user,
        uint256 usdVolume1e18,
        uint256 usdSaved1e18,
        bytes32 ref
    ) external;

    function onSwapExecuted(
        address user,
        uint256 usdVolume1e18,
        bytes32 ref
    ) external;

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

    function onP10Action(
        address user,
        uint256 usdValue1e18,
        bytes32 ref
    ) external;

    function onAgentRun(
        address user,
        uint256 complexity,
        bytes32 ref
    ) external;
}

interface IReputationOperatorCompat {
    function onPayflowExecuted(
        address user,
        uint256 usdVol1e18,
        uint256 usdSaved1e18,
        bytes32 ref
    ) external;
}

contract UsagePointsAdapter is Ownable, IReputationOperatorCompat {
    IUsagePointsHook public immutable usagePoints;

    mapping(address => bool) public allowedCallers;

    event CallerSet(address indexed caller, bool allowed);

    constructor(address initialOwner, address _usagePoints) Ownable(initialOwner) {
        require(_usagePoints != address(0), "usage=0");
        usagePoints = IUsagePointsHook(_usagePoints);
    }

    modifier onlyAllowedCaller() {
        require(allowedCallers[msg.sender], "not allowed");
        _;
    }

    function setCaller(address caller, bool allowed) external onlyOwner {
        require(caller != address(0), "caller=0");
        allowedCallers[caller] = allowed;
        emit CallerSet(caller, allowed);
    }

    // Payflow hook used by ParagonPayflowExecutorV2
    function onPayflowExecuted(
        address user,
        uint256 usdVol1e18,
        uint256 usdSaved1e18,
        bytes32 ref
    ) external override onlyAllowedCaller {
        usagePoints.onPayflowExecuted(user, usdVol1e18, usdSaved1e18, ref);
    }

    // optional helper paths for later
    function forwardSwapExecuted(
        address user,
        uint256 usdVolume1e18,
        bytes32 ref
    ) external onlyAllowedCaller {
        usagePoints.onSwapExecuted(user, usdVolume1e18, ref);
    }

    function forwardLiquidityAdded(
        address user,
        uint256 usdValue1e18,
        bytes32 ref
    ) external onlyAllowedCaller {
        usagePoints.onLiquidityAdded(user, usdValue1e18, ref);
    }

    function forwardLiquidityRetained(
        address user,
        uint256 usdValue1e18,
        bytes32 ref
    ) external onlyAllowedCaller {
        usagePoints.onLiquidityRetained(user, usdValue1e18, ref);
    }

    function forwardP10Action(
        address user,
        uint256 usdValue1e18,
        bytes32 ref
    ) external onlyAllowedCaller {
        usagePoints.onP10Action(user, usdValue1e18, ref);
    }

    function forwardAgentRun(
        address user,
        uint256 complexity,
        bytes32 ref
    ) external onlyAllowedCaller {
        usagePoints.onAgentRun(user, complexity, ref);
    }
}
