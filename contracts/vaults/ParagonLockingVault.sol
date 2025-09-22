// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

interface IParagonFarm {
    function depositFor(uint256 pid, uint256 amount, address user, address referrer) external;
    function withdraw(uint256 pid, uint256 amount) external;
    function harvest(uint256 pid) external;
    function poolLpToken(uint256 pid) external view returns (address);
    function pendingReward(uint256 pid, address user) external view returns (uint256);
}

contract ParagonLockingVault is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    struct Position {
        uint256 amount;      // LP principal
        uint64  unlockTime;  // unlock timestamp
        uint16  tier;        // 0=30d, 1=60d, 2=90d
        uint256 rewardDebt;  // shares * accRewardPerShare / 1e12
        uint256 shares;      // amount * multiplierBips / 10000
    }

    // Immutable config
    IParagonFarm public immutable farm;
    IERC20       public immutable lpToken;
    IERC20       public immutable rewardToken;
    uint256      public immutable pid;

    // Admin config
    address public dao; // receives penalties

    uint64  public lock30 = 30 days;
    uint64  public lock60 = 60 days;
    uint64  public lock90 = 90 days;

    uint16  public mult30 = 12000; // 1.20x (bips)
    uint16  public mult60 = 15000; // 1.50x
    uint16  public mult90 = 20000; // 2.00x

    uint16  public earlyPenaltyBips = 250; // 2.5%
    bool    public emergencyMode;

    // Reward accounting
    uint256 public accRewardPerShare; // scaled by 1e12
    uint256 public totalShares;

    mapping(address => Position[]) public positions;

    // Events
    event Deposited(address indexed user, uint256 indexed idx, uint256 amount, uint256 shares, uint64 unlockAt, uint16 tier);
    event Claimed(address indexed user, uint256 indexed idx, uint256 amount);
    event ClaimedAll(address indexed user, uint256 amount);
    event Unlocked(address indexed user, uint256 indexed idx, uint256 amount);
    event EarlyUnlocked(address indexed user, uint256 indexed idx, uint256 returnedToUser, uint256 penaltyToDao);
    event Harvested(uint256 amount);
    event ParamsUpdated(uint64 l30, uint64 l60, uint64 l90, uint16 m30, uint16 m60, uint16 m90);
    event EarlyPenaltyUpdated(uint16 bips);
    event EmergencyModeUpdated(bool enabled);
    event DaoUpdated(address dao);
    event Rescued(address token, uint256 amount, address to);

    constructor(
        address initialOwner,
        address _lpToken,
        address _rewardToken,
        address _farm,
        uint256 _pid,
        address _dao
    ) Ownable(initialOwner) {
        require(_lpToken != address(0) && _rewardToken != address(0) && _farm != address(0) && _dao != address(0), "zero addr");
        farm = IParagonFarm(_farm);
        lpToken = IERC20(_lpToken);
        rewardToken = IERC20(_rewardToken);
        pid = _pid;
        dao = _dao;

        // sanity: pool's LP must match
        require(IParagonFarm(_farm).poolLpToken(_pid) == _lpToken, "pool/lp mismatch");

        // pre-approve farm with max to avoid repeated approvals
        lpToken.forceApprove(_farm, type(uint256).max);
    }

    // ---------------------------- User API ----------------------------

    modifier whenNotEmergency() {
        require(!emergencyMode, "emergency");
        _;
    }

    function deposit(uint256 amount, uint8 tier, address referrer) external nonReentrant whenNotEmergency {
        require(amount > 0, "amount=0");
        (uint64 duration, uint16 mult) = _tier(tier);
        uint64 unlockAt = uint64(block.timestamp) + duration;

        _harvest(); // update accRewardPerShare

        uint256 shares = (amount * mult) / 10000;
        totalShares += shares;

        // Pull LP into vault, then stake from vault into farm
        lpToken.safeTransferFrom(msg.sender, address(this), amount);
        farm.depositFor(pid, amount, address(this), referrer);

        Position memory p = Position({
            amount: amount,
            unlockTime: unlockAt,
            tier: uint16(tier),
            rewardDebt: (shares * accRewardPerShare) / 1e12,
            shares: shares
        });
        positions[msg.sender].push(p);
        uint256 idx = positions[msg.sender].length - 1;

        emit Deposited(msg.sender, idx, amount, shares, unlockAt, tier);
    }

    function claim(uint256 idx) public nonReentrant {
        _harvest();
        Position storage p = positions[msg.sender][idx];
        uint256 pendingAmt = _pendingFor(p);
        p.rewardDebt = (p.shares * accRewardPerShare) / 1e12;
        if (pendingAmt > 0) {
            rewardToken.safeTransfer(msg.sender, pendingAmt);
            emit Claimed(msg.sender, idx, pendingAmt);
        }
    }

    function claimAll() external nonReentrant {
        _harvest();
        Position[] storage arr = positions[msg.sender];
        uint256 total;
        for (uint256 i = 0; i < arr.length; i++) {
            uint256 amt = _pendingFor(arr[i]);
            arr[i].rewardDebt = (arr[i].shares * accRewardPerShare) / 1e12;
            total += amt;
        }
        if (total > 0) {
            rewardToken.safeTransfer(msg.sender, total);
        }
        emit ClaimedAll(msg.sender, total);
    }

    function unlock(uint256 idx) external nonReentrant {
        _harvest();
        Position storage p = positions[msg.sender][idx];
        require(emergencyMode || block.timestamp >= p.unlockTime, "locked");

        // pay rewards
        uint256 pendingAmt = _pendingFor(p);
        if (pendingAmt > 0) {
            rewardToken.safeTransfer(msg.sender, pendingAmt);
        }

        // withdraw principal from farm and send to user
        uint256 amount = p.amount;
        if (amount > 0) {
            farm.withdraw(pid, amount);
            lpToken.safeTransfer(msg.sender, amount);
        }

        totalShares -= p.shares;
        _clearPosition(p);

        emit Unlocked(msg.sender, idx, amount);
    }

    function unlockEarly(uint256 idx) external nonReentrant {
        _harvest();
        Position storage p = positions[msg.sender][idx];
        require(p.amount > 0, "no pos");

        // pay rewards
        uint256 pendingAmt = _pendingFor(p);
        if (pendingAmt > 0) {
            rewardToken.safeTransfer(msg.sender, pendingAmt);
        }

        // withdraw principal and apply penalty
        uint256 amount = p.amount;
        farm.withdraw(pid, amount);

        uint256 penalty = (amount * earlyPenaltyBips) / 10000;
        uint256 userAmt = amount - penalty;

        if (penalty > 0) lpToken.safeTransfer(dao, penalty);
        lpToken.safeTransfer(msg.sender, userAmt);

        totalShares -= p.shares;
        _clearPosition(p);

        emit EarlyUnlocked(msg.sender, idx, userAmt, penalty);
    }

    // ---------------------------- Admin ----------------------------

    function harvest() external nonReentrant {
        _harvest();
    }

    function setParams(
        uint64 _lock30, uint64 _lock60, uint64 _lock90,
        uint16 _mult30, uint16 _mult60, uint16 _mult90
    ) external onlyOwner {
        require(_mult30 > 0 && _mult60 > 0 && _mult90 > 0, "mult=0");
        lock30 = _lock30; lock60 = _lock60; lock90 = _lock90;
        mult30 = _mult30; mult60 = _mult60; mult90 = _mult90;
        emit ParamsUpdated(_lock30, _lock60, _lock90, _mult30, _mult60, _mult90);
    }

    function setEarlyPenaltyBips(uint16 bips) external onlyOwner {
        require(bips <= 10000, "bips>10000");
        earlyPenaltyBips = bips;
        emit EarlyPenaltyUpdated(bips);
    }

    function setEmergencyMode(bool enabled) external onlyOwner {
        emergencyMode = enabled;
        emit EmergencyModeUpdated(enabled);
    }

    function setDao(address _dao) external onlyOwner {
        require(_dao != address(0), "zero");
        dao = _dao;
        emit DaoUpdated(_dao);
    }

    function rescueToken(address token, uint256 amount, address to) external onlyOwner {
        require(to != address(0), "zero");
        require(token != address(lpToken) && token != address(rewardToken), "protected");
        IERC20(token).safeTransfer(to, amount);
        emit Rescued(token, amount, to);
    }

    // ---------------------------- Views ----------------------------

    function positionsLength(address user) external view returns (uint256) {
        return positions[user].length;
    }

    function pending(uint256 idx, address user) external view returns (uint256) {
        Position memory p = positions[user][idx];
        uint256 acc = accRewardPerShare;
        uint256 ts = totalShares;

        // simulate harvest view: add current farm pending as if applied now
        if (ts > 0) {
            uint256 pendingFarm = farm.pendingReward(pid, address(this));
            if (pendingFarm > 0) {
                acc += (pendingFarm * 1e12) / ts;
            }
        }
        uint256 entitled = (p.shares * acc) / 1e12;
        return entitled > p.rewardDebt ? (entitled - p.rewardDebt) : 0;
    }

    // ---------------------------- Internals ----------------------------

    function _harvest() internal {
        uint256 beforeBal = rewardToken.balanceOf(address(this));
        farm.harvest(pid); // farm pays rewards to this vault
        uint256 harvested = rewardToken.balanceOf(address(this)) - beforeBal;

        if (harvested > 0 && totalShares > 0) {
            accRewardPerShare += (harvested * 1e12) / totalShares;
            emit Harvested(harvested);
        }
    }

    function _pendingFor(Position memory p) internal view returns (uint256) {
        uint256 entitled = (p.shares * accRewardPerShare) / 1e12;
        return entitled > p.rewardDebt ? (entitled - p.rewardDebt) : 0;
    }

    function _tier(uint8 tier) internal view returns (uint64 lockDur, uint16 multBips) {
        if (tier == 0) return (lock30, mult30);
        if (tier == 1) return (lock60, mult60);
        if (tier == 2) return (lock90, mult90);
        revert("bad tier");
    }

    function _clearPosition(Position storage p) internal {
        p.amount = 0;
        p.shares = 0;
        p.rewardDebt = 0;
        p.unlockTime = uint64(block.timestamp);
    }
}
