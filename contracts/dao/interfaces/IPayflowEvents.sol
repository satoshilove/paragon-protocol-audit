// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

/// @notice Canonical events interface for Payflow executors / indexers.
/// Keep-only-events interface; no functions here. Useful for `emit` typing and off-chain decoding.
interface IPayflowEvents {
    /// @dev Emitted by the Payflow executor when a user trade is processed.
    /// - `user`: wallet that triggered the flow
    /// - `usdVolume1e18`: trade notional in USD (1e18 precision)
    /// - `usdSaved1e18`: measured savings in USD (1e18 precision)
    /// - `ref`: optional correlation id / order hash
    /// - `caller`: msg.sender that invoked the executor
    event PayflowExecuted(
        address indexed user,
        uint256 usdVolume1e18,
        uint256 usdSaved1e18,
        bytes32 indexed ref,
        address indexed caller
    );
}
