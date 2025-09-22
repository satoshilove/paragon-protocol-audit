// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

/// @notice Minimal VE interface required by GaugeController and FeeDistributorERC20.
/// - GaugeController needs `balanceOf(user)`
/// - FeeDistributor needs historical reads at specific timestamps.
interface IVoterEscrowMinimal {
    /// @return current voting power of `account`
    function balanceOf(address account) external view returns (uint256);

    /// @return voting power of `account` at exact timestamp `ts`
    function balanceOfAtTime(address account, uint256 ts) external view returns (uint256);

    /// @return total ve supply at exact timestamp `ts`
    function totalSupplyAtTime(uint256 ts) external view returns (uint256);
}
