// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

/// @notice Minimal interface your executor already satisfies (same shape as your ReputationOperator hook)
interface IUsageHook {
    function onPayflowExecuted(
        address user,
        uint256 usdVolume1e18,
        uint256 usdSaved1e18,
        bytes32 ref
    ) external;
}

interface IUsagePointsView {
    function pointsOf(address user, uint256 epoch) external view returns (uint256);
    function totalOf(uint256 epoch) external view returns (uint256);
}

/// @title UsagePoints — epoch-based usage accumulator for “trade mining → ve auto-lock”
contract UsagePoints is Ownable, Pausable, IUsageHook, IUsagePointsView {
    // notifier set (e.g., ParagonPayflowExecutorV2)
    mapping(address => bool) public callers;

    // epoch = floor(block.timestamp / 1 weeks)
    function currentEpoch() public view returns (uint256) {
        return block.timestamp / 1 weeks;
    }
    function dayKey() public view returns (uint256) {
        return block.timestamp / 1 days;
    }

    // weights (in bips, 10_000 = 1.0)
    uint16 public weightVolBips   = 10_000; // 100% of usdVolume
    uint16 public weightSavedBips = 20_000; // 200% of usdSaved (optional boost)

    // daily per-user cap in "points" (1e18-precision)
    uint256 public dailyCapPerUser = 100_000e18; // tune

    // epoch => user => points(1e18)
    mapping(uint256 => mapping(address => uint256)) public points;
    // epoch => totalPoints(1e18)
    mapping(uint256 => uint256) public totalPoints;
    // user => dayKey => accrued(1e18)
    mapping(address => mapping(uint256 => uint256)) public dailyAccrued;

    event CallerSet(address indexed caller, bool allowed);
    event WeightsSet(uint16 weightVolBips, uint16 weightSavedBips);
    event DailyCapSet(uint256 cap);
    event PointsAdded(
        address indexed user,
        uint256 indexed epoch,
        uint256 added,
        uint256 newUserPoints,
        uint256 newTotalPoints,
        bytes32 ref
    );
    event Paused();
    event Unpaused();

    constructor(address initialOwner) Ownable(initialOwner) {}

    modifier onlyCaller() {
        require(callers[msg.sender], "UsagePoints:notifier");
        _;
    }

    // --- Admin ---
    function setCaller(address c, bool allowed) external onlyOwner {
        callers[c] = allowed;
        emit CallerSet(c, allowed);
    }

    function setWeights(uint16 volBips, uint16 savedBips) external onlyOwner {
        require(volBips <= 20_000 && savedBips <= 50_000, "UsagePoints:too-high");
        weightVolBips   = volBips;
        weightSavedBips = savedBips;
        emit WeightsSet(volBips, savedBips);
    }

    function setDailyCap(uint256 cap) external onlyOwner {
        dailyCapPerUser = cap;
        emit DailyCapSet(cap);
    }

    function pause() external onlyOwner { _pause(); emit Paused(); }
    function unpause() external onlyOwner { _unpause(); emit Unpaused(); }

    // --- Hook from executor ---
    function onPayflowExecuted(
        address user,
        uint256 usdVolume1e18,
        uint256 usdSaved1e18,
        bytes32 ref
    ) external onlyCaller whenNotPaused {
        if (user == address(0)) return;

        // compute score = vol*w1 + saved*w2  (1e18 precision retained)
        uint256 score = 0;
        if (usdVolume1e18 > 0 && weightVolBips > 0)
            score += (usdVolume1e18 * weightVolBips) / 10_000;
        if (usdSaved1e18 > 0 && weightSavedBips > 0)
            score += (usdSaved1e18 * weightSavedBips) / 10_000;

        if (score == 0) return;

        // enforce daily cap
        uint256 dkey = dayKey();
        uint256 cur = dailyAccrued[user][dkey];
        if (cur >= dailyCapPerUser) return;
        uint256 grant = score;
        if (cur + grant > dailyCapPerUser) grant = dailyCapPerUser - cur;

        uint256 ep = currentEpoch();
        points[ep][user] += grant;
        totalPoints[ep]  += grant;
        dailyAccrued[user][dkey] = cur + grant;

        emit PointsAdded(user, ep, grant, points[ep][user], totalPoints[ep], ref);
    }

    // --- Views ---
    function pointsOf(address user, uint256 epoch) external view returns (uint256) {
        return points[epoch][user];
    }
    function totalOf(uint256 epoch) external view returns (uint256) {
        return totalPoints[epoch];
    }
}
