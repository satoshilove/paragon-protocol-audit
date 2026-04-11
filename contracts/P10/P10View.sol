// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import "./P10IndexManager.sol";

/**
 * @title P10View
 * @notice Read-only helper for frontends / analytics.
 * @dev Does NOT hold funds, does NOT have any permissions.
 */
contract P10View {
    P10IndexManager public immutable manager;
    P10Token public immutable p10;

    struct P10Config {
        uint256 snapshotId;
        uint16 mintFeeBps;
        uint16 redeemFeeBps;
        uint256 perTxMintCapUsdE18;
        uint16 dailyMintCapBps;
        bool mintPaused;
        bool redeemPaused;
        bool emergencyFrozen;
        address feeRecipient;
        address pauser;
        address guardian;
    }

    constructor(address _manager, address _p10) {
        manager = P10IndexManager(_manager);
        p10 = P10Token(_p10);
    }

    function getConfig() external view returns (P10Config memory cfg) {
        cfg.snapshotId = manager.snapshotId();
        cfg.mintFeeBps = manager.mintFeeBps();
        cfg.redeemFeeBps = manager.redeemFeeBps();
        cfg.perTxMintCapUsdE18 = manager.perTxMintCapUsdE18();
        cfg.dailyMintCapBps = manager.dailyMintCapBps();
        cfg.mintPaused = manager.mintPaused();
        cfg.redeemPaused = manager.redeemPaused();
        cfg.emergencyFrozen = manager.emergencyFrozen();
        cfg.feeRecipient = manager.feeRecipient();
        cfg.pauser = manager.pauser();
        cfg.guardian = manager.guardian();
    }

    function navAndSupply() external view returns (uint256 navE18, uint256 totalSupply) {
        navE18 = manager.navPerP10USD();
        totalSupply = p10.totalSupply();
    }
}
