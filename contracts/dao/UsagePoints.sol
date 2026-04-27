// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.25;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

contract UsagePoints is Ownable, Pausable {
    mapping(address => bool) public callers;

    modifier onlyCaller() {
        require(callers[msg.sender], "not notifier");
        _;
    }

    uint256 public constant WEEK = 7 days;
    uint256 public constant DAY = 1 days;
    uint256 public constant MAX_DECAY_DAYS = 90;

    enum ActionType {
        SWAP,
        PAYFLOW,
        LP_ADD,
        LP_RETAIN,
        P10,
        AGENT
    }

    mapping(uint256 => mapping(address => uint256)) public points;
    mapping(uint256 => uint256) public totalPoints;
    mapping(address => mapping(uint256 => mapping(uint8 => uint256))) public dailyAccrued;

    uint256 public dailyCapSwapPoints = 15_000e18;
    uint256 public dailyCapPayflowPoints = 25_000e18;
    uint256 public dailyCapLpAddPoints = 20_000e18;
    uint256 public dailyCapLpRetainPoints = 20_000e18;
    uint256 public dailyCapP10Points = 20_000e18;
    uint256 public dailyCapAgentPoints = 20_000e18;
    uint256 public dailyCapAllTypes = 100_000e18;

    mapping(address => uint256) public usageScore;
    mapping(address => uint256) public lastActiveTs;
    mapping(address => uint256) public lastDecayDay;

    uint256 public constant SCORE_MAX = 10_000e18;
    uint256 public constant SCORE_FLOOR = 500e18;

    uint256 public inactivityGrace = 15 days;
    uint256 public decayBpsPerDay = 700;

    uint256 public constant MULT_MIN_BPS = 2_500;
    uint256 public constant MULT_MAX_BPS = 15_000;

    uint16 public wSwapVolBps = 2_000;
    uint16 public wPayVolBps = 10_000;
    uint16 public wPaySavedBps = 20_000;
    uint16 public wLpAddBps = 5_000;
    uint16 public wLpRetainBps = 5_000;
    uint16 public wP10Bps = 7_500;
    uint16 public wAgentBps = 0;

    event CallerSet(address indexed caller, bool allowed);
    event DailyCapsSet(
        uint256 swapCap,
        uint256 payflowCap,
        uint256 lpAddCap,
        uint256 lpRetainCap,
        uint256 p10Cap,
        uint256 agentCap,
        uint256 allTypesCap
    );
    event WeightsSet(
        uint16 swapVol,
        uint16 payVol,
        uint16 paySaved,
        uint16 lpAdd,
        uint16 lpRetain,
        uint16 p10,
        uint16 agent
    );
    event DecayParamsSet(uint256 gracePeriod, uint256 decayBpsPerDay);
    event DecayApplied(address indexed user, uint256 newScore, uint256 lastDecayDayKey);

    constructor(address initialOwner) Ownable(initialOwner) {}

    function currentEpoch() public view returns (uint256) {
        return block.timestamp / WEEK;
    }

    function dayKey() public view returns (uint256) {
        return block.timestamp / DAY;
    }

    function setCaller(address caller, bool allowed) external onlyOwner {
        callers[caller] = allowed;
        emit CallerSet(caller, allowed);
    }

    function setDailyCaps(
        uint256 swap,
        uint256 payflow,
        uint256 lpAdd,
        uint256 lpRetain,
        uint256 p10,
        uint256 agent,
        uint256 all
    ) external onlyOwner {
        dailyCapSwapPoints = swap;
        dailyCapPayflowPoints = payflow;
        dailyCapLpAddPoints = lpAdd;
        dailyCapLpRetainPoints = lpRetain;
        dailyCapP10Points = p10;
        dailyCapAgentPoints = agent;
        dailyCapAllTypes = all;

        emit DailyCapsSet(swap, payflow, lpAdd, lpRetain, p10, agent, all);
    }

    function setWeights(
        uint16 swapVol,
        uint16 payVol,
        uint16 paySaved,
        uint16 lpAdd,
        uint16 lpRetain,
        uint16 p10,
        uint16 agent
    ) external onlyOwner {
        require(swapVol <= 30_000, "swap too high");
        require(payVol <= 30_000, "pay vol too high");
        require(paySaved <= 60_000, "pay saved too high");
        require(lpAdd <= 30_000, "lp add too high");
        require(lpRetain <= 30_000, "lp retain too high");
        require(p10 <= 40_000, "p10 too high");
        require(agent <= 40_000, "agent too high");

        wSwapVolBps = swapVol;
        wPayVolBps = payVol;
        wPaySavedBps = paySaved;
        wLpAddBps = lpAdd;
        wLpRetainBps = lpRetain;
        wP10Bps = p10;
        wAgentBps = agent;

        emit WeightsSet(swapVol, payVol, paySaved, lpAdd, lpRetain, p10, agent);
    }

    function setDecayParams(uint256 _grace, uint256 _decayBps) external onlyOwner {
        require(_grace <= 90 days, "grace too long");
        require(_decayBps <= 3_000, "decay too high");
        inactivityGrace = _grace;
        decayBpsPerDay = _decayBps;

        emit DecayParamsSet(_grace, _decayBps);
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    function applyDecay(address user) external whenNotPaused {
        _applyDecay(user);
    }

    function onPayflowExecuted(address user, uint256 vol, uint256 saved, bytes32 ref) external onlyCaller whenNotPaused {
        ref;
        if (user == address(0)) return;

        uint256 score;
        if (vol > 0) score += (vol * wPayVolBps) / 10_000;
        if (saved > 0) score += (saved * wPaySavedBps) / 10_000;

        _accrue(user, ActionType.PAYFLOW, score);
    }

    function onSwapExecuted(address user, uint256 vol, bytes32 ref) external onlyCaller whenNotPaused {
        ref;
        if (user == address(0)) return;

        uint256 score = vol > 0 ? (vol * wSwapVolBps) / 10_000 : 0;
        _accrue(user, ActionType.SWAP, score);
    }

    function onLiquidityAdded(address user, uint256 value, bytes32 ref) external onlyCaller whenNotPaused {
        ref;
        if (user == address(0)) return;

        uint256 score = value > 0 ? (value * wLpAddBps) / 10_000 : 0;
        _accrue(user, ActionType.LP_ADD, score);
    }

    function onLiquidityRetained(address user, uint256 value, bytes32 ref) external onlyCaller whenNotPaused {
        ref;
        if (user == address(0)) return;

        uint256 score = value > 0 ? (value * wLpRetainBps) / 10_000 : 0;
        _accrue(user, ActionType.LP_RETAIN, score);
    }

    function onP10Action(address user, uint256 value, bytes32 ref) external onlyCaller whenNotPaused {
        ref;
        if (user == address(0)) return;

        uint256 score = value > 0 ? (value * wP10Bps) / 10_000 : 0;
        _accrue(user, ActionType.P10, score);
    }

    function onAgentRun(address user, uint256 complexity, bytes32 ref) external onlyCaller whenNotPaused {
        ref;
        if (user == address(0) || complexity == 0) return;

        uint256 score = wAgentBps > 0
            ? (complexity * uint256(wAgentBps) * 1e18) / 10_000
            : 50e18 + (complexity * 1e18) / 10;

        _accrue(user, ActionType.AGENT, score);
    }

    function pointsOf(address user, uint256 epoch_) external view returns (uint256) {
        return points[epoch_][user];
    }

    function totalOf(uint256 epoch_) external view returns (uint256) {
        return totalPoints[epoch_];
    }

    function usageScoreOf(address user) external view returns (uint256) {
        return usageScore[user] == 0 ? SCORE_FLOOR : usageScore[user];
    }

    function lastActiveAt(address user) external view returns (uint256) {
        return lastActiveTs[user];
    }

    function multiplierBps(address user) public view returns (uint256) {
        uint256 s = usageScore[user];
        if (s == 0) s = SCORE_FLOOR;

        uint256 low = 1_000e18;
        uint256 mid = 7_000e18;

        if (s < low) return MULT_MIN_BPS;

        uint256 m = MULT_MIN_BPS;

        if (s <= mid) {
            uint256 progress = s - low;
            m += (10_000 * progress) / 6_000e18;
            return m > 12_500 ? 12_500 : m;
        }

        m = 12_500;
        uint256 highProgress = s - mid;
        m += (2_500 * highProgress) / 3_000e18;
        return m > MULT_MAX_BPS ? MULT_MAX_BPS : m;
    }

    function _capFor(ActionType t) internal view returns (uint256) {
        if (t == ActionType.SWAP) return dailyCapSwapPoints;
        if (t == ActionType.PAYFLOW) return dailyCapPayflowPoints;
        if (t == ActionType.LP_ADD) return dailyCapLpAddPoints;
        if (t == ActionType.LP_RETAIN) return dailyCapLpRetainPoints;
        if (t == ActionType.P10) return dailyCapP10Points;
        return dailyCapAgentPoints;
    }

    function _accrue(address user, ActionType t, uint256 raw) internal {
        if (raw == 0) return;

        _applyDecay(user);
        uint256 d = dayKey();

        if (dailyCapAllTypes > 0) {
            uint256 todayTotal =
                dailyAccrued[user][d][uint8(ActionType.SWAP)] +
                dailyAccrued[user][d][uint8(ActionType.PAYFLOW)] +
                dailyAccrued[user][d][uint8(ActionType.LP_ADD)] +
                dailyAccrued[user][d][uint8(ActionType.LP_RETAIN)] +
                dailyAccrued[user][d][uint8(ActionType.P10)] +
                dailyAccrued[user][d][uint8(ActionType.AGENT)];

            if (todayTotal >= dailyCapAllTypes) return;
            if (todayTotal + raw > dailyCapAllTypes) raw = dailyCapAllTypes - todayTotal;
        }

        uint256 cap = _capFor(t);
        uint256 cur = dailyAccrued[user][d][uint8(t)];

        if (cap > 0) {
            if (cur >= cap) return;
            if (cur + raw > cap) raw = cap - cur;
        }

        if (raw == 0) return;

        dailyAccrued[user][d][uint8(t)] = cur + raw;

        uint256 ep = currentEpoch();
        points[ep][user] += raw;
        totalPoints[ep] += raw;

        uint256 add = raw / 10;
        uint256 s = usageScore[user] + add;
        if (s > SCORE_MAX) s = SCORE_MAX;
        if (s < SCORE_FLOOR) s = SCORE_FLOOR;

        usageScore[user] = s;
        lastActiveTs[user] = block.timestamp;
    }

    function _applyDecay(address user) internal {
        uint256 s = usageScore[user];

        if (s == 0) {
            usageScore[user] = SCORE_FLOOR;
            lastDecayDay[user] = dayKey();
            emit DecayApplied(user, SCORE_FLOOR, dayKey());
            return;
        }

        uint256 last = lastActiveTs[user];
        if (last == 0) {
            lastDecayDay[user] = dayKey();
            emit DecayApplied(user, s, dayKey());
            return;
        }

        if (block.timestamp <= last + inactivityGrace) {
            lastDecayDay[user] = dayKey();
            emit DecayApplied(user, s, dayKey());
            return;
        }

        uint256 today = dayKey();
        uint256 ld = lastDecayDay[user];
        if (ld == 0) ld = today;
        if (today <= ld) return;

        uint256 daysPassed = today - ld;
        if (daysPassed > MAX_DECAY_DAYS) daysPassed = MAX_DECAY_DAYS;

        uint256 keep = 10_000 - decayBpsPerDay;
        for (uint256 i = 0; i < daysPassed; ++i) {
            s = (s * keep) / 10_000;
            if (s <= SCORE_FLOOR) {
                s = SCORE_FLOOR;
                break;
            }
        }

        usageScore[user] = s;
        lastDecayDay[user] = today;

        emit DecayApplied(user, s, today);
    }
}
