// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IParagonFarmController {
    // ---------- Views (existing) ----------
    function rewardToken() external view returns (IERC20);
    function rewardPerBlock() external view returns (uint256);
    function startBlock() external view returns (uint256);
    function totalAllocPoint() external view returns (uint256);
    function poolLength() external view returns (uint256);
    function poolLpToken(uint256 pid) external view returns (address);

    function getUserOverview(
        uint256 pid,
        address user
    ) external view returns (uint256 staked, uint256 pending, uint256 autoYieldTotal, uint256 lastDeposit);

    function userInfo(uint256 pid, address user) external view returns (uint256 amount, uint256 rewardDebt, uint256 lastDepositTime);
    function pendingReward(uint256 pid, address user) external view returns (uint256);
    function pendingRewardAfterFee(uint256 pid, address user) external view returns (uint256 net, uint256 gross, uint16 feeBips);

    // ---------- Core actions (existing) ----------
    function depositFor(uint256 pid, uint256 amount, address user, address referrer) external;
    function withdraw(uint256 pid, uint256 amount) external;
    function harvest(uint256 pid) external;
    function emergencyWithdraw(uint256 pid) external;

    // ---------- Admin / config (existing) ----------
    function addPool(uint256 allocPoint, IERC20 lpToken, uint256 harvestDelay, uint256 vestingDuration) external;
    function setPool(uint256 pid, uint256 allocPoint, uint256 harvestDelay, uint256 vestingDuration) external;
    function setAllocPointsBatch(uint256[] calldata pids, uint256[] calldata allocs) external;
    function setAutoYieldRouter(address router) external;
    function setReferralManager(address referral) external;
    function setBoostManager(address boost) external;
    function setGovPower(address govPower) external;
    function setRewardPerBlock(uint256 rewardPerBlock) external;
    function setEmissionsPaused(bool paused) external;
    function enableEpochs(bool enabled) external;
    function setEpochs(uint256[] calldata endBlocks, uint256[] calldata rewards) external;
    function setPerformanceFee(address recipient, uint16 bips) external;
    function massUpdatePools(uint256[] calldata pids) external;

    // ---------- NEW (only if another contract must call/read) ----------
    function configureSuperFarm90d(uint256 superRpbWei, uint256 baseRpbWei) external;
    function configureSuperFarm90dDefault() external;

    // epoch state getters (public vars in the controller; add here if you’ll read cross-contract)
    function epochsEnabled() external view returns (bool);
    function currentEpochIndex() external view returns (uint256);
    function epochs(uint256 index) external view returns (uint256 endBlock, uint256 rewardPerBlock);
}