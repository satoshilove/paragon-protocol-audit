// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

interface IReferralManager {
    function getReferrer(address user) external view returns (address);
    function recordReferral(address user, address referrer) external;
    function addReferralPoints(address user, uint256 points) external;
}

interface IRewardDripper {
    function drip() external returns (uint256 sent);
    function pendingAccrued() external view returns (uint256);
}

interface IParagonOracle {
    function getAmountsOutUsingTwap(uint amountIn, address[] memory path, uint32 timeWindow)
        external view returns (uint[] memory amounts);
}

interface IParagonPair {
    function token0() external view returns (address);
    function token1() external view returns (address);
    function getReserves() external view returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast);
}

contract ParagonFarmController is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // -----------------------------------------------------------------------
    // Types
    // -----------------------------------------------------------------------
    struct UserInfo {
        uint256 amount;
        uint256 rewardDebt;
        uint256 lastDepositTime;
        uint256 unpaid; // accrued rewards that weren’t claimable or payable yet
    }
    struct PoolInfo {
        IERC20 lpToken;
        uint256 allocPoint;
        uint256 lastRewardBlock;
        uint256 accRewardPerShare;
        uint256 harvestDelay;
        uint256 totalStaked;
    }

    // -----------------------------------------------------------------------
    // Core config
    // -----------------------------------------------------------------------
    IERC20 public rewardToken;
    uint256 public rewardPerBlock;
    uint256 public totalAllocPoint;
    uint256 public startBlock;
    IReferralManager public referralManager;
    PoolInfo[] public poolInfo;
    mapping(uint256 => mapping(address => UserInfo)) public userInfo;
    uint256 public rewardTokenStakedTotal;
    address public autoYieldRouter;
    mapping(uint256 => mapping(address => uint256)) public autoYieldDeposited;
    bool public emissionsPaused;

    // -----------------------------------------------------------------------
    // Dynamic emissions config
    // -----------------------------------------------------------------------
    bool public dynamicEmissions;
    uint16 public targetAPRBips; // e.g., 1000 = 10% APR
    address public baseToken;
    IParagonOracle public priceOracle;

    // -----------------------------------------------------------------------
    // Reward dripper automation (low-water top-ups)
    // -----------------------------------------------------------------------
    IRewardDripper public dripper;
    uint256 public lowWaterDays = 3; // runway target in days (~0.75s blocks)
    uint64 public dripCooldownSecs = 900; // 15 min
    uint64 public lastDripAt; // last successful drip timestamp
    uint256 public minDripAmount = 1e18; // tune per token decimals

    // -----------------------------------------------------------------------
    // Performance fee on rewards
    // -----------------------------------------------------------------------
    uint16 public constant MAX_PERF_FEE_BIPS = 500; // 5.00% hard cap
    address public feeRecipient; // typically DAO multisig
    uint16 public performanceFeeBips; // e.g., 200 = 2.00%

    // -----------------------------------------------------------------------
    // BSC ~0.75s/block helpers + defaults
    // -----------------------------------------------------------------------
    function _blocksPerDay075() internal pure returns (uint256) { return 115200; }

    // -----------------------------------------------------------------------
    // Events
    // -----------------------------------------------------------------------
    event Deposit(address indexed user, uint256 indexed pid, uint256 amount);
    event Withdraw(address indexed user, uint256 indexed pid, uint256 amount);
    event Harvest(address indexed user, uint256 indexed pid, uint256 netAmount);
    event EmergencyWithdraw(address indexed user, uint256 indexed pid, uint256 amount);
    event PoolAdded(uint256 pid, address lpToken, uint256 allocPoint);
    event PoolUpdated(uint256 pid, uint256 allocPoint, uint256 harvestDelay);
    event AllocPointsBatchSet(uint256 count);
    event AutoYieldDeposit(address indexed user, uint256 indexed pid, uint256 amount, address indexed router);
    event AutoYieldRouterUpdated(address indexed router);
    event RewardPerBlockUpdated(uint256 newRate);
    event EmissionsPaused(bool paused);
    event MassPoolUpdate(uint256 count);
    event PerformanceFeeUpdated(address indexed recipient, uint16 feeBips);
    event HarvestFeeTaken(address indexed user, uint256 indexed pid, uint256 feeAmount);
    event DripperUpdated(address indexed dripper);
    event LowWaterDaysUpdated(uint256 days_);
    event DripperPoked(uint256 sent, uint256 availableAfter);
    event DripperCooldownUpdated(uint64 secs);
    event MinDripAmountUpdated(uint256 amount);
    event DynamicEmissionsUpdated(bool enabled);
    event TargetAPRUpdated(uint16 bips);
    event BaseTokenUpdated(address base);
    event PriceOracleUpdated(address oracle);

    // -----------------------------------------------------------------------
    // Constructor
    // -----------------------------------------------------------------------
    constructor(
        address initialOwner,
        IERC20 _rewardToken,
        uint256 _rewardPerBlock,
        uint256 _startBlock
    ) Ownable(initialOwner) {
        require(address(_rewardToken) != address(0), "Farm: reward token = zero");
        rewardToken = _rewardToken;
        rewardPerBlock = _rewardPerBlock;
        startBlock = _startBlock;
        emissionsPaused = false;
        feeRecipient = initialOwner;
        performanceFeeBips = 0;
        dynamicEmissions = false;
        targetAPRBips = 0;
    }

    // -----------------------------------------------------------------------
    // Admin setters
    // -----------------------------------------------------------------------
    function setReferralManager(address _referral) external onlyOwner { referralManager = IReferralManager(_referral); }
    function setAutoYieldRouter(address _router) external onlyOwner { autoYieldRouter = _router; emit AutoYieldRouterUpdated(_router); }
    function setRewardPerBlock(uint256 _rewardPerBlock) external onlyOwner {
        rewardPerBlock = _rewardPerBlock;
        emit RewardPerBlockUpdated(_rewardPerBlock);
    }
    function setEmissionsPaused(bool _paused) external onlyOwner { emissionsPaused = _paused; emit EmissionsPaused(_paused); }
    function setPerformanceFee(address _recipient, uint16 _bips) external onlyOwner {
        require(_recipient != address(0), "fee: recipient = zero");
        require(_bips <= MAX_PERF_FEE_BIPS, "fee: too high");
        feeRecipient = _recipient;
        performanceFeeBips = _bips;
        emit PerformanceFeeUpdated(_recipient, _bips);
    }
    function setDripper(address d) external onlyOwner { dripper = IRewardDripper(d); emit DripperUpdated(d); }
    function setLowWaterDays(uint256 d) external onlyOwner { require(d > 0 && d <= 60, "bad days"); lowWaterDays = d; emit LowWaterDaysUpdated(d); }
    function setDripCooldownSecs(uint64 secs) external onlyOwner { require(secs <= 1 days, "cooldown too large"); dripCooldownSecs = secs; emit DripperCooldownUpdated(secs); }
    function setMinDripAmount(uint256 amt) external onlyOwner { minDripAmount = amt; emit MinDripAmountUpdated(amt); }
    function setDynamicEmissions(bool _enabled) external onlyOwner {
        dynamicEmissions = _enabled;
        emit DynamicEmissionsUpdated(_enabled);
    }
    function setTargetAPRBips(uint16 _bips) external onlyOwner {
        targetAPRBips = _bips;
        emit TargetAPRUpdated(_bips);
    }
    function setBaseToken(address _base) external onlyOwner {
        require(_base != address(0), "Farm: base zero");
        baseToken = _base;
        emit BaseTokenUpdated(_base);
    }
    function setPriceOracle(address _oracle) external onlyOwner {
        require(_oracle != address(0), "Farm: oracle zero");
        priceOracle = IParagonOracle(_oracle);
        emit PriceOracleUpdated(_oracle);
    }

    // -----------------------------------------------------------------------
    // Pool management
    // -----------------------------------------------------------------------
    function poolLength() external view returns (uint256) { return poolInfo.length; }
    function poolLpToken(uint256 pid) external view returns (address) { return address(poolInfo[pid].lpToken); }
    function addPool(
        uint256 _allocPoint,
        IERC20 _lpToken,
        uint256 _harvestDelay
    ) external onlyOwner {
        require(address(_lpToken) != address(0), "Farm: lp = zero");
        totalAllocPoint += _allocPoint;
        poolInfo.push(
            PoolInfo({
                lpToken: _lpToken,
                allocPoint: _allocPoint,
                lastRewardBlock: block.number > startBlock ? block.number : startBlock,
                accRewardPerShare: 0,
                harvestDelay: _harvestDelay,
                totalStaked: 0
            })
        );
        emit PoolAdded(poolInfo.length - 1, address(_lpToken), _allocPoint);
    }
    function setPool(
        uint256 _pid,
        uint256 _allocPoint,
        uint256 _harvestDelay
    ) external onlyOwner {
        totalAllocPoint = totalAllocPoint - poolInfo[_pid].allocPoint + _allocPoint;
        PoolInfo storage pool = poolInfo[_pid];
        pool.allocPoint = _allocPoint;
        pool.harvestDelay = _harvestDelay;
        emit PoolUpdated(_pid, _allocPoint, _harvestDelay);
    }
    function setAllocPointsBatch(uint256[] calldata pids, uint256[] calldata allocs) external onlyOwner {
        require(pids.length == allocs.length, "batch: length mismatch");
        for (uint256 i = 0; i < pids.length; i++) {
            uint256 pid = pids[i];
            uint256 newAlloc = allocs[i];
            totalAllocPoint = totalAllocPoint - poolInfo[pid].allocPoint + newAlloc;
            poolInfo[pid].allocPoint = newAlloc;
            emit PoolUpdated(pid, newAlloc, poolInfo[pid].harvestDelay);
        }
        emit AllocPointsBatchSet(pids.length);
    }

    // -----------------------------------------------------------------------
    // Dynamic emissions internals
    // -----------------------------------------------------------------------
    function updateEmissionRate() external {
        require(dynamicEmissions, "Farm: not dynamic");
        rewardPerBlock = _calculateCurrentRPB();
        emit RewardPerBlockUpdated(rewardPerBlock);
        _maybeTopUpFromDripper();
    }

    function getEffectiveRPB() public view returns (uint256) {
        return dynamicEmissions ? _calculateCurrentRPB() : rewardPerBlock;
    }

    function _calculateCurrentRPB() internal view returns (uint256) {
        if (address(priceOracle) == address(0) || baseToken == address(0) || targetAPRBips == 0) return 0;
        uint256 tvl = _getGlobalTVL();
        if (tvl == 0) return 0;

        address[] memory path = _pathFor(address(rewardToken), baseToken);
        uint[] memory amounts = priceOracle.getAmountsOutUsingTwap(1e18, path, 0);
        uint256 rewardPrice = amounts[amounts.length - 1];
        if (rewardPrice == 0) return 0;

        uint256 annualRewards = (tvl * targetAPRBips / 10000) * 1e18 / rewardPrice;
        uint256 blocksPerYear = 365 * _blocksPerDay075();
        return annualRewards / blocksPerYear;
    }

    function _getGlobalTVL() internal view returns (uint256 tvl) {
        for (uint256 i = 0; i < poolInfo.length; i++) {
            PoolInfo storage p = poolInfo[i];
            address lp = address(p.lpToken);
            uint256 price = _getLPPrice(lp);
            tvl += p.totalStaked * price / 1e18; // assume 18 decimals
        }
    }

    function _getLPPrice(address lp) internal view returns (uint256 price) {
        if (lp == baseToken) return 1e18;
        // Assume lp is a pair; revert if not
        address t0 = IParagonPair(lp).token0();
        address t1 = IParagonPair(lp).token1();
        (uint112 r0, uint112 r1, ) = IParagonPair(lp).getReserves();
        uint256 totalSupply = IERC20(lp).totalSupply();
        if (totalSupply == 0) return 0;

        uint256 unit0 = uint256(r0) * 1e18 / totalSupply;
        uint256 unit1 = uint256(r1) * 1e18 / totalSupply;

        {
            address[] memory p0 = _pathFor(t0, baseToken);
            uint[] memory a0 = priceOracle.getAmountsOutUsingTwap(unit0, p0, 0);
            uint256 v0 = a0[a0.length - 1];

            address[] memory p1 = _pathFor(t1, baseToken);
            uint[] memory a1 = priceOracle.getAmountsOutUsingTwap(unit1, p1, 0);
            uint256 v1 = a1[a1.length - 1];

            price = v0 + v1;
        }
    }

    function _pathFor(address from, address to) internal pure returns (address[] memory path) {
        path = new address[](2);
        path[0] = from;
        path[1] = to;
    }

    // -----------------------------------------------------------------------
    // Emissions accounting
    // -----------------------------------------------------------------------
    function _maybeTopUpFromDripper() internal {
        if (address(dripper) == address(0) || emissionsPaused) return;
        uint256 effectiveRPB = getEffectiveRPB();
        if (effectiveRPB == 0) return;
        if (msg.sender == address(dripper)) return;
        if (block.timestamp < lastDripAt + dripCooldownSecs) return;
        uint256 need = effectiveRPB * _blocksPerDay075() * lowWaterDays;
        uint256 avail = _availableRewards();
        if (avail >= need) return;
        uint256 acc;
        try dripper.pendingAccrued() returns (uint256 p) { acc = p; } catch {}
        if (acc < minDripAmount) return;
        try dripper.drip() returns (uint256 sent) {
            lastDripAt = uint64(block.timestamp);
            emit DripperPoked(sent, _availableRewards());
        } catch {}
    }

    function pokeDripper() external { _maybeTopUpFromDripper(); }

    function updatePool(uint256 _pid) public {
        _maybeTopUpFromDripper();
        PoolInfo storage pool = poolInfo[_pid];
        if (block.number <= pool.lastRewardBlock) return;
        uint256 lpSupply = pool.totalStaked;
        if (lpSupply == 0 || emissionsPaused || totalAllocPoint == 0) {
            pool.lastRewardBlock = block.number;
            return;
        }
        uint256 reward = 0;
        uint256 blocks = block.number - pool.lastRewardBlock;
        if (!emissionsPaused) {
            uint256 effectiveRPB = getEffectiveRPB();
            if (effectiveRPB != 0) {
                reward = (blocks * effectiveRPB * pool.allocPoint) / totalAllocPoint;
            }
        }
        if (reward != 0) {
            pool.accRewardPerShare += (reward * 1e12) / lpSupply;
        }
        pool.lastRewardBlock = block.number;
    }

    function massUpdatePools(uint256[] calldata pids) external {
        for (uint256 i = 0; i < pids.length; i++) {
            updatePool(pids[i]);
        }
        emit MassPoolUpdate(pids.length);
    }

    // -----------------------------------------------------------------------
    // Core flows
    // -----------------------------------------------------------------------
    function depositFor(uint256 _pid, uint256 _amount, address _user, address _referrer) external nonReentrant {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_user];
        updatePool(_pid);

        // 1) Accrue fresh pending into carry BEFORE changing stake
        uint256 fresh = (user.amount * pool.accRewardPerShare) / 1e12 - user.rewardDebt;
        if (fresh > 0) {
            user.unpaid += fresh;
        }

        // 2) Stake mutation
        if (_amount > 0) {
            pool.lpToken.safeTransferFrom(msg.sender, address(this), _amount);
            user.amount += _amount;
            pool.totalStaked += _amount;
            if (address(pool.lpToken) == address(rewardToken)) {
                rewardTokenStakedTotal += _amount;
            }
            bool isAutoYield = (msg.sender == autoYieldRouter);
            if (!isAutoYield) {
                user.lastDepositTime = block.timestamp;
            } else {
                autoYieldDeposited[_pid][_user] += _amount;
                emit AutoYieldDeposit(_user, _pid, _amount, msg.sender);
            }
        }

        // 3) Update debt to the new snapshot
        user.rewardDebt = (user.amount * pool.accRewardPerShare) / 1e12;

        if (address(referralManager) != address(0) && _referrer != address(0)) {
            referralManager.recordReferral(_user, _referrer);
        }
        emit Deposit(_user, _pid, _amount);
    }

    function harvest(uint256 _pid) external nonReentrant {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        updatePool(_pid);

        uint256 fresh = (user.amount * pool.accRewardPerShare) / 1e12 - user.rewardDebt;
        uint256 gross = user.unpaid + fresh;

        // Update debt snapshot first
        user.rewardDebt = (user.amount * pool.accRewardPerShare) / 1e12;

        // Not eligible yet -> keep accumulating
        if (gross == 0 || block.timestamp < user.lastDepositTime + pool.harvestDelay) {
            user.unpaid = gross;
            return;
        }

        // Cap by available and apply perf fee
        uint256 available = _availableRewards();
        uint256 payTotal = gross > available ? available : gross;
        if (payTotal > 0) {
            uint256 feeAmt = 0;
            if (performanceFeeBips > 0 && feeRecipient != address(0)) {
                feeAmt = (payTotal * performanceFeeBips) / 10000;
                if (feeAmt > 0) {
                    rewardToken.safeTransfer(feeRecipient, feeAmt);
                    emit HarvestFeeTaken(msg.sender, _pid, feeAmt);
                }
            }
            uint256 toUser = payTotal - feeAmt;
            if (toUser > 0) rewardToken.safeTransfer(msg.sender, toUser);
            emit Harvest(msg.sender, _pid, toUser);
        }

        // Any unpaid remainder stays in carry
        user.unpaid = (gross > payTotal) ? (gross - payTotal) : 0;
    }

    function withdraw(uint256 _pid, uint256 _amount) external nonReentrant {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        require(user.amount >= _amount, "Farm: insufficient");

        updatePool(_pid);

        uint256 fresh = (user.amount * pool.accRewardPerShare) / 1e12 - user.rewardDebt;
        uint256 gross = user.unpaid + fresh;

        bool canHarvest = (gross > 0) && (block.timestamp >= user.lastDepositTime + pool.harvestDelay);
        if (canHarvest) {
            uint256 available = _availableRewards();
            uint256 payTotal = gross > available ? available : gross;
            if (payTotal > 0) {
                uint256 feeAmt = 0;
                if (performanceFeeBips > 0 && feeRecipient != address(0)) {
                    feeAmt = (payTotal * performanceFeeBips) / 10000;
                    if (feeAmt > 0) {
                        rewardToken.safeTransfer(feeRecipient, feeAmt);
                        emit HarvestFeeTaken(msg.sender, _pid, feeAmt);
                    }
                }
                uint256 toUser = payTotal - feeAmt;
                if (toUser > 0) rewardToken.safeTransfer(msg.sender, toUser);
                emit Harvest(msg.sender, _pid, toUser);
            }
            user.unpaid = (gross > available) ? (gross - available) : 0;
        } else {
            user.unpaid = gross; // keep accruing
        }

        if (_amount > 0) {
            user.amount -= _amount;
            pool.totalStaked -= _amount;
            if (address(pool.lpToken) == address(rewardToken)) {
                rewardTokenStakedTotal -= _amount;
            }
            pool.lpToken.safeTransfer(msg.sender, _amount);
            emit Withdraw(msg.sender, _pid, _amount);
        }

        user.rewardDebt = (user.amount * pool.accRewardPerShare) / 1e12;
    }

    function emergencyWithdraw(uint256 _pid) external nonReentrant {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];

        uint256 amount = user.amount;
        require(amount > 0, "Farm: nothing to withdraw");

        user.amount = 0;
        user.rewardDebt = 0;
        user.unpaid = 0;

        pool.totalStaked -= amount;
        if (address(pool.lpToken) == address(rewardToken)) {
            rewardTokenStakedTotal -= amount;
        }
        pool.lpToken.safeTransfer(msg.sender, amount);
        emit EmergencyWithdraw(msg.sender, _pid, amount);
    }

    // -----------------------------------------------------------------------
    // Views
    // -----------------------------------------------------------------------
    function pendingReward(uint256 _pid, address _user) public view returns (uint256) {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_user];

        uint256 acc = pool.accRewardPerShare;
        uint256 lpSupply = pool.totalStaked;

        if (block.number > pool.lastRewardBlock && lpSupply != 0 && totalAllocPoint != 0) {
            if (!emissionsPaused) {
                uint256 blocks = block.number - pool.lastRewardBlock;
                uint256 effectiveRPB = getEffectiveRPB();
                if (effectiveRPB != 0) {
                    uint256 reward = (blocks * effectiveRPB * pool.allocPoint) / totalAllocPoint;
                    acc += (reward * 1e12) / lpSupply;
                }
            }
        }
        // carry + fresh
        return user.unpaid + ((user.amount * acc) / 1e12 - user.rewardDebt); // gross (pre-fee)
    }

    function pendingRewardAfterFee(uint256 _pid, address _user)
        external
        view
        returns (uint256 net, uint256 gross, uint16 feeBips)
    {
        gross = pendingReward(_pid, _user);
        feeBips = performanceFeeBips;
        if (feeBips > 0 && feeRecipient != address(0)) {
            uint256 feeAmt = (gross * feeBips) / 10000;
            net = gross - feeAmt;
        } else {
            net = gross;
        }
    }

    function getUserOverview(
        uint256 pid,
        address user_
    ) external view returns (uint256 staked, uint256 pending, uint256 autoYieldTotal, uint256 lastDeposit) {
        UserInfo storage u = userInfo[pid][user_];
        staked = u.amount;
        pending = pendingReward(pid, user_);
        autoYieldTotal = autoYieldDeposited[pid][user_];
        lastDeposit = u.lastDepositTime;
    }

    // -----------------------------------------------------------------------
    // Internal
    // -----------------------------------------------------------------------
    function _availableRewards() internal view returns (uint256) {
        uint256 bal = rewardToken.balanceOf(address(this));
        return bal > rewardTokenStakedTotal ? bal - rewardTokenStakedTotal : 0;
    }
}
