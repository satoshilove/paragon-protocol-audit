// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.25;

interface IUsdValuer {
    /// @notice Returns USD value scaled to 1e18 for a token amount.
    function usdValue(address token, uint256 amount) external view returns (uint256);
}
