// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import "./interfaces/IP10IndexManager.sol";
import "./interfaces/IP10Token.sol";

contract P10View {
    IP10IndexManager public immutable manager;
    IP10Token public immutable p10;

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
        address vault;
        address executionManager;
        address mintVenue;
        address redeemVenue;
    }

    constructor(address _manager, address _p10) {
        manager = IP10IndexManager(_manager);
        p10 = IP10Token(_p10);
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
        cfg.vault = address(manager.vault());
        cfg.executionManager = address(manager.executionManager());
        cfg.mintVenue = manager.mintVenue();
        cfg.redeemVenue = manager.redeemVenue();
    }

    function navAndSupply() external view returns (uint256 navE18, uint256 totalSupply) {
        navE18 = manager.navPerP10USD();
        totalSupply = p10.totalSupply();
    }
}
