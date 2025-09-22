// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

/// @notice Reputation/points sink interface with the same hook shape used by UsagePoints.
/// If your executor calls multiple sinks (e.g., UsagePoints + Reputation), both can share this signature.
interface IParagonReputation {
    /// @dev Called by the Payflow executor (or a router) when a user trade completes.
    /// Implementations can award reputation, badges, or side effects.
    function onPayflowExecuted(
        address user,
        uint256 usdVolume1e18,
        uint256 usdSaved1e18,
        bytes32 ref
    ) external;
}
