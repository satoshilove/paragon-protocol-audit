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

contract GaugeController is Ownable, Pausable {
    IVoterEscrowVotes public immutable ve;
    IUsageMultiplier public immutable usage;

    uint256 public constant WEEK = 7 days;
    uint256 public constant MAX_BPS = 10_000;

    uint256 public minVeToVote = 250e18;
    uint256 public maxGaugesPerVote = 10;
    uint256 public voteCooldown = 0;

    address[] public gauges;
    mapping(address => bool) public isGauge;

    mapping(uint256 => mapping(address => uint256)) public gaugeWeight;
    mapping(uint256 => uint256) public totalWeight;

    mapping(uint256 => mapping(address => mapping(address => uint256))) public userVoteBps;
    mapping(uint256 => mapping(address => uint256)) public userUsedBps;
    mapping(uint256 => mapping(address => address[])) private userVotedGauges;
    mapping(uint256 => mapping(address => uint256)) public powerUsedAtVote;
    mapping(uint256 => mapping(address => uint256)) public userLastVoteTs;

    event GaugeAdded(address indexed gauge);
    event GaugeRemoved(address indexed gauge);
    event Voted(address indexed user, uint256 indexed epoch, uint256 userPowerCached, address[] gauges, uint256[] bps);
    event Reset(address indexed user, uint256 indexed epoch, uint256 userPowerCleared);
    event ParamsSet(uint256 minVeToVote, uint256 maxGaugesPerVote, uint256 voteCooldown);

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
        require(_maxGaugesPerVote >= 1 && _maxGaugesPerVote <= 20, "bad max");
        require(_minVeToVote <= 10_000_000e18, "min too high");

        minVeToVote = _minVeToVote;
        maxGaugesPerVote = _maxGaugesPerVote;
        voteCooldown = _voteCooldown;

        emit ParamsSet(_minVeToVote, _maxGaugesPerVote, _voteCooldown);
    }

    function addGauge(address gauge) external onlyOwner {
        require(gauge != address(0), "0");
        require(!isGauge[gauge], "exists");
        isGauge[gauge] = true;
        gauges.push(gauge);
        emit GaugeAdded(gauge);
    }

    function removeGauge(address gauge) external onlyOwner {
        require(isGauge[gauge], "none");
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
        require(_gauges.length == _bps.length, "len");
        require(_gauges.length > 0, "empty");
        require(_gauges.length <= maxGaugesPerVote, "too many");

        uint256 ep = epoch();

        if (voteCooldown > 0) {
            require(block.timestamp >= userLastVoteTs[ep][msg.sender] + voteCooldown, "cooldown");
        }

        usage.applyDecay(msg.sender);

        uint256 p = userPower(msg.sender);
        require(p > 0, "no power");

        for (uint256 i = 0; i < _gauges.length; ++i) {
            for (uint256 j = 0; j < i; ++j) {
                require(_gauges[i] != _gauges[j], "dup gauge");
            }
        }

        _resetFor(ep, msg.sender);
        powerUsedAtVote[ep][msg.sender] = p;

        uint256 used;
        for (uint256 i = 0; i < _gauges.length; ++i) {
            address g = _gauges[i];
            uint256 b = _bps[i];

            require(isGauge[g], "not gauge");
            require(b <= MAX_BPS, "bps");

            used += b;
            require(used <= MAX_BPS, "sum>100%");

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

    function _resetFor(uint256 ep, address user) internal {
        address[] storage voted = userVotedGauges[ep][user];

        if (voted.length == 0) {
            userUsedBps[ep][user] = 0;
            powerUsedAtVote[ep][user] = 0;
            return;
        }

        uint256 p = powerUsedAtVote[ep][user];
        if (p == 0) {
            p = userPower(user);
        }

        for (uint256 i = 0; i < voted.length; ++i) {
            address g = voted[i];
            uint256 b = userVoteBps[ep][user][g];
            if (b == 0) continue;

            uint256 delta = (p * b) / MAX_BPS;

            uint256 gw = gaugeWeight[ep][g];
            gaugeWeight[ep][g] = gw > delta ? gw - delta : 0;

            uint256 tw = totalWeight[ep];
            totalWeight[ep] = tw > delta ? tw - delta : 0;

            userVoteBps[ep][user][g] = 0;
        }

        delete userVotedGauges[ep][user];
        userUsedBps[ep][user] = 0;
        powerUsedAtVote[ep][user] = 0;

        emit Reset(user, ep, p);
    }
}