// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {IVoterEscrowMinimal} from "./interfaces/IVoterEscrowMinimal.sol";

contract GaugeController is Ownable, Pausable {
    IVoterEscrowMinimal public immutable ve;

    uint256 public constant WEEK = 7 days;
    uint256 public constant MAX_BPS = 10_000;
    uint256 public constant VOTE_COOLDOWN = 7 days;

    address[] public gauges;
    mapping(address => bool) public isGauge;

    // gauge => weight (0..MAX_BPS aggregation)
    mapping(address => uint256) public gaugeWeightBps;
    uint256 public totalWeightBps;

    // user votes
    mapping(address => mapping(address => uint256)) public userVoteBps; // user => gauge => bps
    mapping(address => uint256) public userUsedBps;
    mapping(address => uint256) public userLastVoteTs;

    event GaugeAdded(address indexed gauge);
    event GaugeRemoved(address indexed gauge);
    event Voted(address indexed user, address indexed gauge, uint256 bps);
    event VoteCleared(address indexed user, address indexed gauge);

    constructor(address _ve, address initialOwner) Ownable(initialOwner) {
        require(_ve != address(0), "ve=0");
        ve = IVoterEscrowMinimal(_ve);
    }

    // --- gauge mgmt

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

        // zero weight
        totalWeightBps -= gaugeWeightBps[gauge];
        gaugeWeightBps[gauge] = 0;

        // compact array (order not guaranteed)
        uint256 L = gauges.length;
        for (uint256 i = 0; i < L; i++) {
            if (gauges[i] == gauge) {
                gauges[i] = gauges[L - 1];
                gauges.pop();
                break;
            }
        }
        emit GaugeRemoved(gauge);
    }

    function n_gauges() external view returns (uint256) { return gauges.length; }
    function gaugesAt(uint256 i) external view returns (address) { return gauges[i]; }

    // --- voting

    function vote_for_gauge_weights(address gauge, uint256 bps) external whenNotPaused {
        require(isGauge[gauge], "not gauge");
        require(bps <= MAX_BPS, ">100%");
        require(block.timestamp >= userLastVoteTs[msg.sender] + VOTE_COOLDOWN, "cooldown");

        // recompute used weight by replacing previous vote to this gauge with new bps
        uint256 prev = userVoteBps[msg.sender][gauge];
        uint256 used = userUsedBps[msg.sender] + bps - prev;
        require(used <= MAX_BPS, "sum>100%");

        // accept vote only if user has some ve
        require(ve.balanceOf(msg.sender) > 0, "no ve");

        userVoteBps[msg.sender][gauge] = bps;
        userUsedBps[msg.sender] = used;
        userLastVoteTs[msg.sender] = block.timestamp;

        // update gauge weight (clamped to MAX_BPS)
        uint256 prevGauge = gaugeWeightBps[gauge];
        uint256 newGauge = prevGauge + bps - prev;
        if (newGauge > MAX_BPS) newGauge = MAX_BPS;

        totalWeightBps = totalWeightBps + newGauge - prevGauge;
        gaugeWeightBps[gauge] = newGauge;

        emit Voted(msg.sender, gauge, bps);
    }

    function clear_vote(address gauge) external whenNotPaused {
        uint256 prev = userVoteBps[msg.sender][gauge];
        require(prev > 0, "none");
        uint256 used = userUsedBps[msg.sender] - prev;
        userUsedBps[msg.sender] = used;
        userVoteBps[msg.sender][gauge] = 0;
        userLastVoteTs[msg.sender] = block.timestamp;

        uint256 prevGauge = gaugeWeightBps[gauge];
        uint256 newGauge = prevGauge > prev ? prevGauge - prev : 0;
        totalWeightBps = totalWeightBps + newGauge - prevGauge;
        gaugeWeightBps[gauge] = newGauge;

        emit VoteCleared(msg.sender, gauge);
    }

    // --- used by minter

    function totalWeight() external view returns (uint256) { return totalWeightBps; }

    function gaugeWeight(address gauge) external view returns (uint256) {
        return gaugeWeightBps[gauge];
    }

    // admin pause
    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }
}
