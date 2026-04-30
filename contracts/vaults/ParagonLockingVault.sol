// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.25;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

interface IParagonFarm {
    function depositFor(uint256 pid, uint256 amount, address user, address referrer) external;
    function withdraw(uint256 pid, uint256 amount) external;
    function emergencyWithdraw(uint256 pid) external;
    function harvest(uint256 pid) external;
    function poolLpToken(uint256 pid) external view returns (address);
    function pendingReward(uint256 pid, address user) external view returns (uint256);
    function poolInfo(uint256 pid)
        external
        view
        returns (
            IERC20 lpToken,
            uint256 allocPoint,
            uint256 lastRewardBlock,
            uint256 accRewardPerShare,
            uint256 harvestDelay,
            uint256 totalStaked,
            uint256 rewardTokenStaked
        );
}

contract ParagonLockingVault is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    struct Position {
        uint256 amount;      // LP principal
        uint64  unlockTime;  // unlock timestamp
        uint16  tier;        // 0=30d, 1=60d, 2=90d
        uint16  penaltyBips; // early-unlock penalty snapshot
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
    bool    public farmEmergencyExited;

    // Reward accounting
    uint256 public accRewardPerShare; // scaled by 1e12
    uint256 public totalShares;
    uint256 public unallocatedRewards;
    mapping(address => uint256) public activePositionsCount;
    mapping(address => uint256) public activePrincipal;

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
    event SurplusRewardsRescued(uint256 amount, address to);
    event FarmEmergencyExited(uint256 amount);
    event PositionIndexChanged(address indexed user, uint256 indexed fromIdx, uint256 indexed toIdx);

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
        (, , , , uint256 harvestDelay, , ) = IParagonFarm(_farm).poolInfo(_pid);
        require(harvestDelay == 0, "pool harvest delay unsupported");

        // pre-approve farm with max to avoid repeated approvals
        lpToken.forceApprove(_farm, type(uint256).max);
    }

    // ---------------------------- User API ----------------------------

    modifier whenNotEmergency() {
        require(!emergencyMode, "emergency");
        _;
    }

    function deposit(uint256 amount, uint8 tier, address /*referrer*/ ) external nonReentrant whenNotEmergency {
        require(amount > 0, "amount=0");
        require(!farmEmergencyExited, "farm exited");
        (uint64 duration, uint16 mult) = _tier(tier);
        uint64 unlockAt = uint64(block.timestamp) + duration;

        _harvest(); // update accRewardPerShare

        uint256 shares = (amount * mult) / 10000;
        totalShares += shares;
        activePositionsCount[msg.sender] += 1;
        activePrincipal[msg.sender] += amount;

        // Pull LP into vault, then stake from vault into farm
        lpToken.safeTransferFrom(msg.sender, address(this), amount);
        farm.depositFor(pid, amount, address(this), address(0));

        Position memory p = Position({
            amount: amount,
            unlockTime: unlockAt,
            tier: uint16(tier),
            penaltyBips: earlyPenaltyBips,
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
        require(p.amount > 0, "no pos");
        require(emergencyMode || farmEmergencyExited || block.timestamp >= p.unlockTime, "locked");

        // withdraw principal from farm and send to user
        uint256 amount = p.amount;
        if (amount > 0) {
            if (!farmEmergencyExited) {
                uint256 beforeBal = rewardToken.balanceOf(address(this));
                farm.withdraw(pid, amount);
                _indexExternalRewards(rewardToken.balanceOf(address(this)) - beforeBal);
            }
            lpToken.safeTransfer(msg.sender, amount);
        }

        // pay rewards after indexing any tokens that arrived during farm.withdraw
        uint256 pendingAmt = _pendingFor(p);
        if (pendingAmt > 0 && !emergencyMode && !farmEmergencyExited) {
            rewardToken.safeTransfer(msg.sender, pendingAmt);
        }

        totalShares -= p.shares;
        activePositionsCount[msg.sender] -= 1;
        activePrincipal[msg.sender] -= amount;
        _removePosition(msg.sender, idx);

        emit Unlocked(msg.sender, idx, amount);
    }

    function unlockEarly(uint256 idx) external nonReentrant {
        _harvest();
        Position storage p = positions[msg.sender][idx];
        require(p.amount > 0, "no pos");

        // withdraw principal and apply penalty
        uint256 amount = p.amount;
        if (!farmEmergencyExited) {
            uint256 beforeBal = rewardToken.balanceOf(address(this));
            farm.withdraw(pid, amount);
            _indexExternalRewards(rewardToken.balanceOf(address(this)) - beforeBal);
        }

        // pay rewards after indexing any tokens that arrived during farm.withdraw
        uint256 pendingAmt = _pendingFor(p);
        if (pendingAmt > 0 && !emergencyMode && !farmEmergencyExited) {
            rewardToken.safeTransfer(msg.sender, pendingAmt);
        }

        uint256 penalty = (amount * p.penaltyBips) / 10000;
        uint256 userAmt = amount - penalty;

        if (penalty > 0) lpToken.safeTransfer(dao, penalty);
        lpToken.safeTransfer(msg.sender, userAmt);

        totalShares -= p.shares;
        activePositionsCount[msg.sender] -= 1;
        activePrincipal[msg.sender] -= amount;
        _removePosition(msg.sender, idx);

        emit EarlyUnlocked(msg.sender, idx, userAmt, penalty);
    }

    // ---------------------------- Admin ----------------------------

    function harvest() external nonReentrant {
        _harvest();
    }

    function triggerFarmEmergencyExit() external onlyOwner nonReentrant {
        require(emergencyMode, "emergency");
        require(!farmEmergencyExited, "already exited");
        require(totalShares > 0, "no active positions");

        // Best-effort reward settlement before the farm position is force-unwound.
        uint256 beforeRewards = rewardToken.balanceOf(address(this));
        try farm.harvest(pid) {
            uint256 harvested = rewardToken.balanceOf(address(this)) - beforeRewards;
            if (harvested > 0) {
                accRewardPerShare += (harvested * 1e12) / totalShares;
                emit Harvested(harvested);
            }
        } catch {}

        uint256 beforeBal = lpToken.balanceOf(address(this));
        farm.emergencyWithdraw(pid);
        uint256 received = lpToken.balanceOf(address(this)) - beforeBal;

        farmEmergencyExited = true;
        emit FarmEmergencyExited(received);
    }

    function setParams(
        uint64 _lock30, uint64 _lock60, uint64 _lock90,
        uint16 _mult30, uint16 _mult60, uint16 _mult90
    ) external onlyOwner {
        require(_lock30 > 0 && _lock60 > 0 && _lock90 > 0, "lock=0");
        require(_lock30 < _lock60 && _lock60 < _lock90, "bad lock order");
        require(_mult30 > 0 && _mult60 > 0 && _mult90 > 0, "mult=0");
        require(_mult30 < _mult60 && _mult60 < _mult90, "bad mult order");
        lock30 = _lock30; lock60 = _lock60; lock90 = _lock90;
        mult30 = _mult30; mult60 = _mult60; mult90 = _mult90;
        emit ParamsUpdated(_lock30, _lock60, _lock90, _mult30, _mult60, _mult90);
    }

    function setEarlyPenaltyBips(uint16 bips) external onlyOwner {
        require(bips <= 3000, "bips>3000");
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

    function rescueSurplusRewards(uint256 amount, address to) external onlyOwner {
        require(to != address(0), "zero");
        require(amount <= unallocatedRewards, "amount too high");
        unallocatedRewards -= amount;
        rewardToken.safeTransfer(to, amount);
        emit SurplusRewardsRescued(amount, to);
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
        if (ts > 0 && !farmEmergencyExited) {
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
        if (farmEmergencyExited) return;

        uint256 beforeBal = rewardToken.balanceOf(address(this));
        farm.harvest(pid); // farm pays rewards to this vault
        _indexExternalRewards(rewardToken.balanceOf(address(this)) - beforeBal);
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

    function _indexExternalRewards(uint256 harvested) internal {
        if (harvested == 0) return;

        if (totalShares == 0) {
            unallocatedRewards += harvested;
            return;
        }

        accRewardPerShare += (harvested * 1e12) / totalShares;
        emit Harvested(harvested);
    }

    function _removePosition(address user, uint256 idx) internal {
        Position[] storage arr = positions[user];
        uint256 last = arr.length - 1;

        if (idx != last) {
            arr[idx] = arr[last];
            emit PositionIndexChanged(user, last, idx);
        }

        arr.pop();
    }
}
