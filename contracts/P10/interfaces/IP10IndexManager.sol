// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

interface IP10IndexManager {
    struct Asset {
        address token;
        uint8 decimals;
        uint96 unitsPerP10E18;
    }

    function snapshotId() external view returns (uint256);
    function mintFeeBps() external view returns (uint16);
    function redeemFeeBps() external view returns (uint16);
    function perTxMintCapUsdE18() external view returns (uint256);
    function dailyMintCapBps() external view returns (uint16);
    function mintPaused() external view returns (bool);
    function redeemPaused() external view returns (bool);
    function emergencyFrozen() external view returns (bool);

    function feeRecipient() external view returns (address);
    function pauser() external view returns (address);
    function guardian() external view returns (address);

    function mintVenue() external view returns (address);
    function redeemVenue() external view returns (address);

    function vault() external view returns (address);
    function executionManager() external view returns (address);

    function navPerP10USD() external view returns (uint256);
    function getAssetValue(address token, uint256 amount) external view returns (uint256);
    function getActiveAssets() external view returns (Asset[] memory);
}
