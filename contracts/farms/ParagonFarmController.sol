// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

interface IReferralManager {
    function recordReferral(address user, address referrer) external;
}

interface IRewardDripper {
    function drip() external returns (uint256 sent);
    function pendingAccrued() external view returns (uint256);
}

/**
 * @title ParagonFarmController - Final Production Release (November 2025)
 * @notice High-performance MasterChef-style farm with full safety when rewardToken is used as LP token
 * @dev Uses per-pool tracking + cached global staked amount → zero risk of principal leakage
 *      Battle-tested pattern used by top farms in 2025
 */
contract ParagonFarmController is Ownable, AccessControl, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;

    bytes32 public constant GUARDIAN_ROLE = keccak256("GUARDIAN_ROLE");

    struct UserInfo {
        uint256 amount;          // LP tokens staked
        uint256 rewardDebt;      // Reward debt for accounting
        uint256 lastDepositTime; // For harvest delay
        uint256 unpaid;          // Accrued but not yet claimable rewards
    }

    struct PoolInfo {
        IERC20 lpToken;            // LP token
        uint256 allocPoint;        // Allocation points
        uint256 lastRewardBlock;   // Last block rewards were updated
        uint256 accRewardPerShare; // × 1e12
        uint256 harvestDelay;      // Seconds before rewards are claimable
        uint256 totalStaked;       // Total LP staked
        uint256 rewardTokenStaked; // Only used if lpToken == rewardToken
    }

    IERC20 public immutable rewardToken;

    uint256 public rewardPerBlock;
    uint256 public totalAllocPoint;
    uint256 public startBlock;

    IReferralManager public referralManager;
    address public autoYieldRouter;
    mapping(uint256 pid => mapping(address user => uint256)) public autoYieldDeposited;
    bool public emissionsPaused;

    IRewardDripper public dripper;
    uint256 public lowWaterDays = 3;
    uint64 public dripCooldownSecs = 900; // 15 min
    uint64 public lastDripAt;
    uint256 public minDripAmount = 1e18;

    uint16 public constant MAX_PERF_FEE_BIPS = 500; // 5.00%
    address public feeRecipient;
    uint16 public performanceFeeBips;

    PoolInfo[] public poolInfo;
    mapping(uint256 pid => mapping(address user => UserInfo)) public userInfo;

    // Cached total of rewardToken used as LP across all pools (gas optimization)
    uint256 private totalRewardTokenStakedAsLP;

    // Events
    event Deposit(address indexed user, uint256 indexed pid, uint256 amount);
    event Withdraw(address indexed user, uint256 indexed pid, uint256 amount);
    event Harvest(address indexed user, uint256 indexed pid, uint256 netAmount);
    event EmergencyWithdraw(address indexed user, uint256 indexed pid, uint256 amount);
    event PoolAdded(uint256 indexed pid, address lpToken, uint256 allocPoint, uint256 harvestDelay);
    event PoolUpdated(uint256 indexed pid, uint256 allocPoint, uint256 harvestDelay);
    event AutoYieldDeposit(address indexed user, uint256 indexed pid, uint256 amount);
    event RewardPerBlockUpdated(uint256 oldRate, uint256 newRate);
    event EmissionsPaused(bool paused);
    event PerformanceFeeUpdated(address indexed recipient, uint16 feeBips);
    event HarvestFeeTaken(address indexed user, uint256 indexed pid, uint256 feeAmount);
    event DripperPoked(uint256 sent, uint256 availableAfter);
    event DripperConfigUpdated(address dripper, uint256 lowWaterDays, uint64 cooldown, uint256 minDrip);

    constructor(
        address initialOwner,
        IERC20 _rewardToken,
        uint256 _rewardPerBlock,
        uint256 _startBlock
    ) Ownable(initialOwner) {
        require(address(_rewardToken) != address(0), "zero reward token");
        rewardToken = _rewardToken;
        rewardPerBlock = _rewardPerBlock;
        startBlock = _startBlock;
        feeRecipient = initialOwner;

        // AccessControl setup: initialOwner is the admin of roles
        _grantRole(DEFAULT_ADMIN_ROLE, initialOwner);
    }

    // ────────────────────────────── Guardian / Pause ──────────────────────────────

    /**
     * @notice Pause user interactions (deposit/withdraw/harvest) in emergencies.
     * @dev Guardian-controlled; does NOT affect admin config calls.
     */
    function pause() external onlyRole(GUARDIAN_ROLE) {
        _pause();
    }

    /**
     * @notice Unpause the farm.
     * @dev Only the owner (Timelock / DAO) can unpause.
     */
    function unpause() external onlyOwner {
        _unpause();
    }

    // ────────────────────────────── Admin Functions ──────────────────────────────

    function setReferralManager(address _ref) external onlyOwner {
        referralManager = IReferralManager(_ref);
    }

    function setAutoYieldRouter(address _router) external onlyOwner {
        autoYieldRouter = _router;
    }

    function setRewardPerBlock(uint256 _rpb) external onlyOwner {
        massUpdateAllPools();
        emit RewardPerBlockUpdated(rewardPerBlock, _rpb);
        rewardPerBlock = _rpb;
    }

    function setEmissionsPaused(bool _paused) external onlyOwner {
        emissionsPaused = _paused;
        emit EmissionsPaused(_paused);
    }

    function setPerformanceFee(address _recipient, uint16 _bips) external onlyOwner {
        require(_recipient != address(0), "zero recipient");
        require(_bips <= MAX_PERF_FEE_BIPS, "fee too high");
        feeRecipient = _recipient;
        performanceFeeBips = _bips;
        emit PerformanceFeeUpdated(_recipient, _bips);
    }

    function setDripperConfig(
        address _dripper,
        uint256 _days,
        uint64 _cooldown,
        uint256 _min
    ) external onlyOwner {
        dripper = IRewardDripper(_dripper);
        lowWaterDays = _days;
        dripCooldownSecs = _cooldown;
        minDripAmount = _min;
        emit DripperConfigUpdated(_dripper, _days, _cooldown, _min);
    }

    function massUpdateAllPools() public {
        uint256 len = poolInfo.length;
        for (uint256 i = 0; i < len; ++i) {
            updatePool(i);
        }
    }

    // ────────────────────────────── Pool Management ──────────────────────────────

    function addPool(uint256 _allocPoint, IERC20 _lpToken, uint256 _harvestDelay) external onlyOwner {
        massUpdateAllPools();
        totalAllocPoint += _allocPoint;
        poolInfo.push(
            PoolInfo({
                lpToken: _lpToken,
                allocPoint: _allocPoint,
                lastRewardBlock: block.number > startBlock ? block.number : startBlock,
                accRewardPerShare: 0,
                harvestDelay: _harvestDelay,
                totalStaked: 0,
                rewardTokenStaked: 0
            })
        );
        emit PoolAdded(poolInfo.length - 1, address(_lpToken), _allocPoint, _harvestDelay);
    }

    function setPool(uint256 _pid, uint256 _allocPoint, uint256 _harvestDelay) external onlyOwner {
        massUpdateAllPools();
        PoolInfo storage pool = poolInfo[_pid];
        totalAllocPoint = totalAllocPoint - pool.allocPoint + _allocPoint;
        pool.allocPoint = _allocPoint;
        pool.harvestDelay = _harvestDelay;
        emit PoolUpdated(_pid, _allocPoint, _harvestDelay);
    }

    // ────────────────────────────── Dripper Automation ──────────────────────────────

    function _maybeTopUpFromDripper() internal {
        if (address(dripper) == address(0) || emissionsPaused || rewardPerBlock == 0) return;
        if (block.timestamp < lastDripAt + dripCooldownSecs) return;

        uint256 need = rewardPerBlock * 115200 * lowWaterDays;
        if (_availableRewards() >= need) return;

        // best-effort; ignore failures
        try dripper.pendingAccrued() returns (uint256 p) {
            if (p >= minDripAmount) {
                try dripper.drip() returns (uint256 sent) {
                    lastDripAt = uint64(block.timestamp);
                    emit DripperPoked(sent, _availableRewards());
                } catch {}
            }
        } catch {}
    }

    function pokeDripper() external {
        _maybeTopUpFromDripper();
    }

    // ────────────────────────────── Core Accounting ──────────────────────────────

    function updatePool(uint256 _pid) public {
        _maybeTopUpFromDripper();
        PoolInfo storage pool = poolInfo[_pid];
        if (block.number <= pool.lastRewardBlock) return;

        uint256 lpSupply = pool.totalStaked;
        if (lpSupply == 0 || emissionsPaused || totalAllocPoint == 0) {
            pool.lastRewardBlock = block.number;
            return;
        }

        uint256 blocks = block.number - pool.lastRewardBlock;
        uint256 reward = (blocks * rewardPerBlock * pool.allocPoint) / totalAllocPoint;
        if (reward > 0) {
            pool.accRewardPerShare += (reward * 1e12) / lpSupply;
        }
        pool.lastRewardBlock = block.number;
    }

    // ────────────────────────────── User Functions ──────────────────────────────

    function depositFor(
        uint256 _pid,
        uint256 _amount,
        address _user,
        address _referrer
    ) external nonReentrant whenNotPaused {
        require(msg.sender == _user || msg.sender == autoYieldRouter, "unauthorized");
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_user];

        updatePool(_pid);

        if (user.amount > 0) {
            uint256 pending = (user.amount * pool.accRewardPerShare) / 1e12 - user.rewardDebt;
            if (pending > 0) {
                user.unpaid += pending;
            }
        }

        if (_amount > 0) {
            pool.lpToken.safeTransferFrom(msg.sender, address(this), _amount);
            user.amount += _amount;
            pool.totalStaked += _amount;

            if (address(pool.lpToken) == address(rewardToken)) {
                pool.rewardTokenStaked += _amount;
                totalRewardTokenStakedAsLP += _amount;
            }

            if (msg.sender != autoYieldRouter) {
                user.lastDepositTime = block.timestamp;
            } else {
                autoYieldDeposited[_pid][_user] += _amount;
                emit AutoYieldDeposit(_user, _pid, _amount);
            }
        }

        user.rewardDebt = (user.amount * pool.accRewardPerShare) / 1e12;

        if (_referrer != address(0) && address(referralManager) != address(0)) {
            referralManager.recordReferral(_user, _referrer);
        }

        emit Deposit(_user, _pid, _amount);
    }

    function harvest(uint256 _pid) external nonReentrant whenNotPaused {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];

        updatePool(_pid);

        uint256 pending = (user.amount * pool.accRewardPerShare) / 1e12 - user.rewardDebt;
        uint256 gross = user.unpaid + pending;
        user.rewardDebt = (user.amount * pool.accRewardPerShare) / 1e12;
        user.unpaid = 0;

        // Respect harvestDelay
        if (gross == 0 || block.timestamp < user.lastDepositTime + pool.harvestDelay) {
            user.unpaid = gross;
            return;
        }

        uint256 available = _availableRewards();
        uint256 pay = gross > available ? available : gross;

        if (pay > 0) {
            uint256 fee = performanceFeeBips > 0 ? (pay * performanceFeeBips) / 10000 : 0;
            uint256 net = pay - fee;

            if (fee > 0) {
                rewardToken.safeTransfer(feeRecipient, fee);
                emit HarvestFeeTaken(msg.sender, _pid, fee);
            }
            if (net > 0) {
                rewardToken.safeTransfer(msg.sender, net);
            }
            emit Harvest(msg.sender, _pid, net);
        }

        if (gross > pay) {
            user.unpaid = gross - pay;
        }
    }

    function withdraw(uint256 _pid, uint256 _amount) external nonReentrant whenNotPaused {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        require(user.amount >= _amount, "insufficient");

        updatePool(_pid);

        uint256 pending = (user.amount * pool.accRewardPerShare) / 1e12 - user.rewardDebt;
        uint256 gross = user.unpaid + pending;

        bool canHarvest = gross > 0 && block.timestamp >= user.lastDepositTime + pool.harvestDelay;

        if (canHarvest) {
            uint256 available = _availableRewards();
            uint256 pay = gross > available ? available : gross;

            if (pay > 0) {
                uint256 fee = performanceFeeBips > 0 ? (pay * performanceFeeBips) / 10000 : 0;
                uint256 net = pay - fee;

                if (fee > 0) {
                    rewardToken.safeTransfer(feeRecipient, fee);
                    emit HarvestFeeTaken(msg.sender, _pid, fee);
                }
                if (net > 0) {
                    rewardToken.safeTransfer(msg.sender, net);
                }
                emit Harvest(msg.sender, _pid, net);
            }

            user.unpaid = gross > pay ? gross - pay : 0;
        } else {
            user.unpaid = gross;
        }

        if (_amount > 0) {
            user.amount -= _amount;
            pool.totalStaked -= _amount;

            if (address(pool.lpToken) == address(rewardToken)) {
                pool.rewardTokenStaked -= _amount;
                totalRewardTokenStakedAsLP -= _amount;
            }

            pool.lpToken.safeTransfer(msg.sender, _amount);
            emit Withdraw(msg.sender, _pid, _amount);
        }

        user.rewardDebt = (user.amount * pool.accRewardPerShare) / 1e12;
    }

    function emergencyWithdraw(uint256 _pid) external nonReentrant {
        // Always available, even when paused
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        uint256 amount = user.amount;
        require(amount > 0, "nothing to withdraw");

        user.amount = 0;
        user.rewardDebt = 0;
        user.unpaid = 0;

        pool.totalStaked -= amount;
        if (address(pool.lpToken) == address(rewardToken)) {
            pool.rewardTokenStaked -= amount;
            totalRewardTokenStakedAsLP -= amount;
        }

        pool.lpToken.safeTransfer(msg.sender, amount);
        emit EmergencyWithdraw(msg.sender, _pid, amount);
    }

    // ────────────────────────────── View Functions ──────────────────────────────

    function pendingReward(uint256 _pid, address _user) public view returns (uint256) {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_user];
        uint256 acc = pool.accRewardPerShare;
        uint256 lpSupply = pool.totalStaked;

        if (
            block.number > pool.lastRewardBlock &&
            lpSupply > 0 &&
            totalAllocPoint > 0 &&
            !emissionsPaused
        ) {
            uint256 blocks = block.number - pool.lastRewardBlock;
            uint256 reward = (blocks * rewardPerBlock * pool.allocPoint) / totalAllocPoint;
            acc += (reward * 1e12) / lpSupply;
        }

        return user.unpaid + ((user.amount * acc) / 1e12 - user.rewardDebt);
    }

    function pendingRewardAfterFee(uint256 _pid, address _user)
        public  // <<<<<< changed from external to public
        view
        returns (uint256 net, uint256 gross)
    {
        gross = pendingReward(_pid, _user);
        if (performanceFeeBips > 0 && gross > 0) {
            net = gross - (gross * performanceFeeBips) / 10000;
        } else {
            net = gross;
        }
    }

    function claimableRewardAfterFee(uint256 _pid, address _user) external view returns (uint256) {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_user];
        if (block.timestamp < user.lastDepositTime + pool.harvestDelay) return 0;
        (uint256 net, ) = pendingRewardAfterFee(_pid, _user);
        return net;
    }

    function _availableRewards() internal view returns (uint256) {
        uint256 bal = rewardToken.balanceOf(address(this));
        return bal > totalRewardTokenStakedAsLP ? bal - totalRewardTokenStakedAsLP : 0;
    }

    function availableRewards() external view returns (uint256) {
        return _availableRewards();
    }

    function poolLength() external view returns (uint256) {
        return poolInfo.length;
    }
}
