// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

interface IVoterEscrowVotes {
    function balanceOf(address user) external view returns (uint256);
}

interface IUsageMultiplier {
    function multiplierBps(address user) external view returns (uint256);
    function applyDecay(address user) external;
}

/// @title GaugeController
/// @notice veXPGN voting controller with live voting during epoch and finalized snapshots for emission distribution
/// @dev Production-hardened: finalized previous-epoch weights prevent vote sniping on distribution
contract GaugeController is Ownable, Pausable {
    IVoterEscrowVotes public immutable ve;
    IUsageMultiplier public immutable usage;

    uint256 public constant WEEK = 7 days;
    uint256 public constant MAX_BPS = 10_000;
    uint256 public constant MAX_GAUGES = 500;

    uint256 public minVeToVote = 250e18;
    uint256 public maxGaugesPerVote = 10;
    uint256 public voteCooldown = 0;

    address[] public gauges;
    mapping(address => bool) public isGauge;

    // live weights (modifiable during current epoch)
    mapping(uint256 => mapping(address => uint256)) public gaugeWeight;
    mapping(uint256 => uint256) public totalWeight;

    // finalized snapshot (immutable after epoch close)
    mapping(uint256 => bool) public epochFinalized;
    mapping(uint256 => mapping(address => uint256)) public finalizedGaugeWeight;
    mapping(uint256 => uint256) public finalizedTotalWeight;

    mapping(uint256 => mapping(address => mapping(address => uint256))) public userVoteBps;
    mapping(uint256 => mapping(address => uint256)) public userUsedBps;
    mapping(uint256 => mapping(address => address[])) private userVotedGauges;
    mapping(uint256 => mapping(address => uint256)) public powerUsedAtVote;
    mapping(uint256 => mapping(address => uint256)) public userLastVoteTs;

    event GaugeAdded(address indexed gauge);
    event GaugeRemoved(address indexed gauge);
    event Voted(address indexed user, uint256 indexed epoch, uint256 userPowerCached, address[] gauges, uint256[] bps);
    event Reset(address indexed user, uint256 indexed epoch, uint256 userPowerCleared);
    event ParamsUpdated(uint256 minVeToVote, uint256 maxGaugesPerVote, uint256 voteCooldown);
    event EpochFinalized(uint256 indexed ep, uint256 totalWeightFinalized);

    constructor(address _ve, address _usage, address initialOwner) Ownable(initialOwner) {
        require(_ve != address(0), "ve=0");
        require(_usage != address(0), "usage=0");
        ve = IVoterEscrowVotes(_ve);
        usage = IUsageMultiplier(_usage);
    }

    function epoch() public view returns (uint256) {
        return block.timestamp / WEEK;
    }

    function setParams(uint256 _minVeToVote, uint256 _maxGaugesPerVote, uint256 _voteCooldown)
        external
        onlyOwner
    {
        require(_maxGaugesPerVote >= 1 && _maxGaugesPerVote <= 20, "maxGaugesPerVote out of range");
        require(_minVeToVote <= 10_000_000e18, "minVeToVote too high");

        minVeToVote = _minVeToVote;
        maxGaugesPerVote = _maxGaugesPerVote;
        voteCooldown = _voteCooldown;

        emit ParamsUpdated(_minVeToVote, _maxGaugesPerVote, _voteCooldown);
    }

    function addGauge(address gauge) external onlyOwner {
        require(gauge != address(0), "gauge=0");
        require(!isGauge[gauge], "gauge already exists");
        require(gauges.length < MAX_GAUGES, "max gauges reached");
        isGauge[gauge] = true;
        gauges.push(gauge);
        emit GaugeAdded(gauge);
    }

    function removeGauge(address gauge) external onlyOwner {
        require(isGauge[gauge], "gauge does not exist");
        isGauge[gauge] = false;

        uint256 L = gauges.length;
        for (uint256 i = 0; i < L; ++i) {
            if (gauges[i] == gauge) {
                gauges[i] = gauges[L - 1];
                gauges.pop();
                break;
            }
        }

        emit GaugeRemoved(gauge);
    }

    function n_gauges() external view returns (uint256) {
        return gauges.length;
    }

    function gaugesAt(uint256 i) external view returns (address) {
        return gauges[i];
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    function userPower(address user) public view returns (uint256) {
        uint256 veBal = ve.balanceOf(user);
        if (veBal < minVeToVote) return 0;

        uint256 m = usage.multiplierBps(user);
        return (veBal * m) / 10_000;
    }

    function reset() external whenNotPaused {
        _resetFor(epoch(), msg.sender);
    }

    function vote(address[] calldata _gauges, uint256[] calldata _bps) external whenNotPaused {
        require(_gauges.length == _bps.length, "arrays length mismatch");
        require(_gauges.length > 0, "empty vote");
        require(_gauges.length <= maxGaugesPerVote, "too many gauges");

        uint256 ep = epoch();
        require(!epochFinalized[ep], "current epoch already finalized");

        if (voteCooldown > 0) {
            require(block.timestamp >= userLastVoteTs[ep][msg.sender] + voteCooldown, "vote cooldown active");
        }

        usage.applyDecay(msg.sender);

        uint256 p = userPower(msg.sender);
        require(p > 0, "no voting power");

        for (uint256 i = 0; i < _gauges.length; ++i) {
            for (uint256 j = 0; j < i; ++j) {
                require(_gauges[i] != _gauges[j], "duplicate gauge");
            }
        }

        _resetFor(ep, msg.sender);
        powerUsedAtVote[ep][msg.sender] = p;

        uint256 used;
        for (uint256 i = 0; i < _gauges.length; ++i) {
            address g = _gauges[i];
            uint256 b = _bps[i];

            require(isGauge[g], "not a registered gauge");
            require(b <= MAX_BPS, "bps exceeds 100%");

            used += b;
            require(used <= MAX_BPS, "total bps exceeds 100%");

            userVoteBps[ep][msg.sender][g] = b;
            userVotedGauges[ep][msg.sender].push(g);

            uint256 delta = (p * b) / MAX_BPS;
            gaugeWeight[ep][g] += delta;
            totalWeight[ep] += delta;
        }

        userUsedBps[ep][msg.sender] = used;
        userLastVoteTs[ep][msg.sender] = block.timestamp;

        emit Voted(msg.sender, ep, p, _gauges, _bps);
    }

    function finalizeEpoch(uint256 ep) external whenNotPaused {
        _finalizeEpoch(ep);
    }

    function batchFinalize(uint256[] calldata eps) external whenNotPaused {
        for (uint256 i = 0; i < eps.length; ++i) {
            if (!epochFinalized[eps[i]]) {
                _finalizeEpoch(eps[i]);
            }
        }
    }

    function _finalizeEpoch(uint256 ep) internal {
        require(ep < epoch(), "epoch not yet closed");
        require(!epochFinalized[ep], "epoch already finalized");

        uint256 tw = totalWeight[ep];
        require(tw > 0, "no total weight");

        finalizedTotalWeight[ep] = tw;

        uint256 n = gauges.length;
        for (uint256 i = 0; i < n; ++i) {
            address g = gauges[i];
            if (isGauge[g]) {
                finalizedGaugeWeight[ep][g] = gaugeWeight[ep][g];
            }
        }

        epochFinalized[ep] = true;
        emit EpochFinalized(ep, tw);
    }

    function gaugeWeightAt(uint256 ep, address gauge) external view returns (uint256) {
        return gaugeWeight[ep][gauge];
    }

    function totalWeightAt(uint256 ep) external view returns (uint256) {
        return totalWeight[ep];
    }

    function gaugeWeightNow(address gauge) external view returns (uint256) {
        return gaugeWeight[epoch()][gauge];
    }

    function totalWeightNow() external view returns (uint256) {
        return totalWeight[epoch()];
    }

    function gaugeWeightFinal(uint256 ep, address gauge) external view returns (uint256) {
        return finalizedGaugeWeight[ep][gauge];
    }

    function totalWeightFinal(uint256 ep) external view returns (uint256) {
        return finalizedTotalWeight[ep];
    }

    function _resetFor(uint256 ep, address user) internal {
        address[] storage voted = userVotedGauges[ep][user];
        if (voted.length == 0) {
            userUsedBps[ep][user] = 0;
            powerUsedAtVote[ep][user] = 0;
            return;
        }

        uint256 p = powerUsedAtVote[ep][user];
        if (p == 0) p = userPower(user);

        for (uint256 i = 0; i < voted.length; ++i) {
            address g = voted[i];
            uint256 b = userVoteBps[ep][user][g];
            if (b == 0) continue;

            uint256 delta = (p * b) / MAX_BPS;
            gaugeWeight[ep][g] = gaugeWeight[ep][g] > delta ? gaugeWeight[ep][g] - delta : 0;
            totalWeight[ep] = totalWeight[ep] > delta ? totalWeight[ep] - delta : 0;
            userVoteBps[ep][user][g] = 0;
        }

        delete userVotedGauges[ep][user];
        userUsedBps[ep][user] = 0;
        powerUsedAtVote[ep][user] = 0;

        emit Reset(user, ep, p);
    }
}