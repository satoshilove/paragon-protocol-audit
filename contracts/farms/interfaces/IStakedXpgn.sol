// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

interface IStakedXpgn {
    // ========== user flows ==========
    function stake(uint256 amount /* underlying XPGN */) external;

    /// @notice Burn stXPGN shares and receive underlying XPGN.
    /// @param stAmount Amount of stXPGN shares to burn (NOT underlying).
    function unstake(uint256 stAmount) external;

    // ========== views ==========
    /// @notice Convert stXPGN shares to underlying XPGN (pro-rata, may round down).
    function getUnderlyingAmount(uint256 stAmount) external view returns (uint256);

    /// @notice Total underlying (staked + pending rewards) controlled by the wrapper.
    function getTotalUnderlying() external view returns (uint256);

    function getXpgnAddress() external view returns (address);

    // ERC20 (reads/writes you might use cross-contract)
    function totalSupply() external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);

    // Optional but handy for UIs/integrations:
    function compound() external; // no-op for integrators if they don’t call it
}
