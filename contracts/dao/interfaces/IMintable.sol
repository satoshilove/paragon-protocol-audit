// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.25;

/// @notice Minimal minting interface used by EmissionsMinter.
interface IMintable {
    function mint(address to, uint256 amount) external;
}
