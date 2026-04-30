// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/access/extensions/AccessControlEnumerable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

interface IReferralManager {
    function recordReferral(address user, address referrer) external;
}

interface IRewardDripper {
    function drip() external returns (uint256 sent);
    function pendingAccrued() external view returns (uint256);
    function rewardToken() external view returns (address);
    function minDripAmount() external view returns (uint256);
    function dripCooldownSecs() external view returns (uint64);
    function lastDripAt() external view returns (uint64);
}

/// @title ParagonFarmController
/// @notice MasterChef-style farm with veXPGN gauge integration
/// @dev Updated to fix:
/// - PAD-57 queued gauge reward application inconsistency
/// - PAD-58 cross-pool reward balance leakage
contract ParagonFarmController is Ownable, AccessControlEnumerable, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;

    bytes32 public constant GUARDIAN_ROLE = keccak256("GUARDIAN_ROLE");
    bytes32 public constant AUTOYIELD_CALLER_ROLE = keccak256("AUTOYIELD_CALLER_ROLE");

    uint256 public constant PRECISION_FACTOR = 1e30;

    struct UserInfo {
        uint256 amount;
        uint256 rewardDebt;
        uint256 lastDepositTime;
        uint256 unpaid;
    }

    struct PoolInfo {
        IERC20 lpToken;
        uint256 allocPoint;
        uint256 lastRewardBlock;
        uint256 accRewardPerShare;
        uint256 harvestDelay;
        uint256 totalStaked;
        uint256 rewardTokenStaked;
    }

    IERC20 public immutable rewardToken;
    uint256 public rewardPerBlock;
    uint256 public totalAllocPoint;
    uint256 public startBlock;

    IReferralManager public referralManager;

    mapping(uint256 pid => mapping(address user => uint256)) public autoYieldDeposited;

    bool public emissionsPaused;

    IRewardDripper public dripper;
    uint256 public lowWaterDays = 3;
    uint64 public dripCooldownSecs = 900;
    uint64 public lastDripAt;
    uint256 public minDripAmount;

    uint16 public constant MAX_PERF_FEE_BIPS = 500;
    address public feeRecipient;
    uint16 public performanceFeeBips;

    PoolInfo[] public poolInfo;
    mapping(uint256 pid => mapping(address user => UserInfo)) public userInfo;

    uint256 private totalRewardTokenStakedAsLP;

    // veXPGN integration
    address public gaugeDistributor;
    mapping(uint256 => uint256) public pendingGaugeRewards;

    // Per-pool reserve isolation
    mapping(uint256 => uint256) public poolRewardReserve;
    uint256 public totalRewardReserved;

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
    event DripperPoked(uint256 sent, uint256 freeLiquidityAfter);
    event DripperConfigUpdated(address dripper, uint256 lowWaterDays, uint64 cooldown, uint256 minDrip);
    event AutoYieldCallerUpdated(address indexed caller, bool allowed);
    event OwnershipAndAdminTransferred(address indexed previousOwner, address indexed newOwner);
    event ExtraAdminRevoked(address indexed revokedAdmin);
    event GaugeDistributorUpdated(address indexed distributor);
    event GaugeRewardAdded(uint256 indexed pid, uint256 amount);
    event GaugeRewardQueued(uint256 indexed pid, uint256 amount);
    event PoolRewardReserved(uint256 indexed pid, uint256 amount, uint256 newPoolReserve);
    event PoolRewardReleased(uint256 indexed pid, uint256 amount, uint256 newPoolReserve);
    event PoolRewardReserveAdjusted(uint256 indexed pid, uint256 oldReserve, uint256 newReserve);

    constructor(
        address initialOwner,
        IERC20 _rewardToken,
        uint256 _rewardPerBlock,
        uint256 _startBlock
    ) Ownable(initialOwner) {
        require(initialOwner != address(0), "owner=0");
        require(address(_rewardToken) != address(0), "rewardToken=0");

        rewardToken = _rewardToken;
        rewardPerBlock = _rewardPerBlock;
        startBlock = _startBlock;
        feeRecipient = initialOwner;

        try IERC20Metadata(address(_rewardToken)).decimals() returns (uint8 dec) {
            minDripAmount = 1000 * (10 ** uint256(dec));
        } catch {
            minDripAmount = 1000 * 1e18;
        }

        _grantRole(DEFAULT_ADMIN_ROLE, initialOwner);
    }

    function transferOwnership(address newOwner) public virtual override onlyOwner {
        require(newOwner != address(0), "newOwner=0");
        address oldOwner = owner();
        super.transferOwnership(newOwner);

        if (!hasRole(DEFAULT_ADMIN_ROLE, newOwner)) {
            _grantRole(DEFAULT_ADMIN_ROLE, newOwner);
        }

        uint256 count = getRoleMemberCount(DEFAULT_ADMIN_ROLE);
        address[] memory revokeList = new address[](count);

        for (uint256 i = 0; i < count; i++) {
            address member = getRoleMember(DEFAULT_ADMIN_ROLE, i);
            if (member != newOwner) revokeList[i] = member;
        }

        for (uint256 i = 0; i < count; i++) {
            if (revokeList[i] != address(0) && revokeList[i] != newOwner) {
                _revokeRole(DEFAULT_ADMIN_ROLE, revokeList[i]);
                emit ExtraAdminRevoked(revokeList[i]);
            }
        }

        emit OwnershipAndAdminTransferred(oldOwner, newOwner);
    }

    function renounceOwnership() public virtual override onlyOwner {
        revert("renounce disabled for safety");
    }

    function pause() external onlyRole(GUARDIAN_ROLE) {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    function setReferralManager(address _ref) external onlyOwner {
        require(_ref != address(0), "ref=0");
        referralManager = IReferralManager(_ref);
    }

    function setAutoYieldCaller(address caller, bool allowed) external onlyOwner {
        require(caller != address(0), "caller=0");
        if (allowed) _grantRole(AUTOYIELD_CALLER_ROLE, caller);
        else _revokeRole(AUTOYIELD_CALLER_ROLE, caller);
        emit AutoYieldCallerUpdated(caller, allowed);
    }

    function setRewardPerBlock(uint256 _rpb) external onlyOwner {
        massUpdateAllPools();
        emit RewardPerBlockUpdated(rewardPerBlock, _rpb);
        rewardPerBlock = _rpb;
    }

    function setEmissionsPaused(bool _paused) external onlyOwner {
        if (_paused == emissionsPaused) return;
        massUpdateAllPools();
        emissionsPaused = _paused;
        emit EmissionsPaused(_paused);
    }

    function setPerformanceFee(address _recipient, uint16 _bips) external onlyOwner {
        require(_recipient != address(0), "recipient=0");
        require(_bips <= MAX_PERF_FEE_BIPS, "fee too high");
        feeRecipient = _recipient;
        performanceFeeBips = _bips;
        emit PerformanceFeeUpdated(_recipient, _bips);
    }

    function setDripperConfig(address _dripper, uint256 _days, uint64 _cooldown, uint256 _min) external onlyOwner {
        require(_min > 0, "minDrip=0");

        if (_dripper != address(0)) {
            IRewardDripper newDripper = IRewardDripper(_dripper);
            require(newDripper.rewardToken() == address(rewardToken), "token mismatch");
            dripper = newDripper;
        } else {
            dripper = IRewardDripper(address(0));
        }

        lowWaterDays = _days;
        dripCooldownSecs = _cooldown;
        minDripAmount = _min;

        emit DripperConfigUpdated(_dripper, _days, _cooldown, _min);
    }

    function setGaugeDistributor(address _dist) external onlyOwner {
        require(_dist != address(0), "dist=0");
        gaugeDistributor = _dist;
        emit GaugeDistributorUpdated(_dist);
    }

    /// @dev Owner-only repair hook in case reserve accounting ever needs manual correction.
    /// Uses massUpdateAllPools() first so accounting is settled before mutation.
    function setPoolRewardReserve(uint256 _pid, uint256 newReserve) external onlyOwner {
        massUpdateAllPools();
        uint256 oldReserve = poolRewardReserve[_pid];

        if (newReserve > oldReserve) {
            totalRewardReserved += (newReserve - oldReserve);
        } else if (oldReserve > newReserve) {
            totalRewardReserved -= (oldReserve - newReserve);
        }

        poolRewardReserve[_pid] = newReserve;
        emit PoolRewardReserveAdjusted(_pid, oldReserve, newReserve);
    }

    function addPool(uint256 _allocPoint, IERC20 _lpToken, uint256 _harvestDelay) external onlyOwner {
        require(address(_lpToken) != address(0), "lpToken=0");
        require(poolInfo.length < 300, "max pools reached");

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

    function _maybeTopUpFromDripper() internal {
        if (address(dripper) == address(0) || emissionsPaused || rewardPerBlock == 0) return;
        if (block.timestamp < lastDripAt + dripCooldownSecs) return;

        uint256 need = rewardPerBlock * 115200 * lowWaterDays;
        if (_freeRewardLiquidity() >= need) return;

        try dripper.pendingAccrued() returns (uint256 p) {
            if (p >= minDripAmount) {
                try dripper.drip() returns (uint256 sent) {
                    if (sent > 0) {
                        lastDripAt = uint64(block.timestamp);
                    }
                    emit DripperPoked(sent, _freeRewardLiquidity());
                } catch {}
            }
        } catch {}
    }

    function pokeDripper() external {
        _maybeTopUpFromDripper();
    }

    function massUpdateAllPools() public {
        uint256 len = poolInfo.length;
        for (uint256 i = 0; i < len; ++i) {
            updatePool(i);
        }
    }

    function updatePool(uint256 _pid) public {
        PoolInfo storage pool = poolInfo[_pid];

        uint256 lpSupply = pool.totalStaked;
        uint256 queued = pendingGaugeRewards[_pid];

        // PAD-57 fix:
        // Apply queued gauge rewards deterministically whenever there is stake.
        // No dependency on emissionsPaused or totalAllocPoint.
        if (queued > 0 && lpSupply > 0) {
            pendingGaugeRewards[_pid] = 0;
            pool.accRewardPerShare += (queued * PRECISION_FACTOR) / lpSupply;
        }

        if (block.number > pool.lastRewardBlock) {
            if (lpSupply > 0 && totalAllocPoint > 0 && !emissionsPaused) {
                uint256 blocks = block.number - pool.lastRewardBlock;
                uint256 reward = (blocks * rewardPerBlock * pool.allocPoint) / totalAllocPoint;

                if (reward > 0) {
                    _reservePoolRewards(_pid, reward);
                    pool.accRewardPerShare += (reward * PRECISION_FACTOR) / lpSupply;
                }
            }

            pool.lastRewardBlock = block.number;
        }

        // Run the low-water refill check after all reservations for this pool update are booked,
        // so the dripper does not make decisions using temporarily overstated free liquidity.
        _maybeTopUpFromDripper();
    }

    function notifyGaugeReward(uint256 _pid, uint256 _amount) external whenNotPaused nonReentrant {
        require(gaugeDistributor != address(0), "distributor not set");
        require(msg.sender == gaugeDistributor, "only distributor");
        require(_amount > 0, "amount=0");

        rewardToken.safeTransferFrom(msg.sender, address(this), _amount);

        // Reserve the incoming gauge funding before any pool update can observe it as free liquidity.
        _reservePoolRewards(_pid, _amount);

        // Settle pool before crediting new reward amount.
        updatePool(_pid);

        PoolInfo storage pool = poolInfo[_pid];
        if (pool.totalStaked > 0) {
            pool.accRewardPerShare += (_amount * PRECISION_FACTOR) / pool.totalStaked;
            emit GaugeRewardAdded(_pid, _amount);
        } else {
            pendingGaugeRewards[_pid] += _amount;
            emit GaugeRewardQueued(_pid, _amount);
        }
    }

    function depositFor(
        uint256 _pid,
        uint256 _amount,
        address _user,
        address _referrer
    ) external nonReentrant whenNotPaused {
        bool isAuto = hasRole(AUTOYIELD_CALLER_ROLE, msg.sender);
        require(msg.sender == _user || isAuto, "unauthorized");

        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_user];

        updatePool(_pid);

        if (user.amount > 0) {
            uint256 pending = (user.amount * pool.accRewardPerShare) / PRECISION_FACTOR - user.rewardDebt;
            if (pending > 0) user.unpaid += pending;
        }

        uint256 credited = 0;

        if (_amount > 0) {
            uint256 balBefore = pool.lpToken.balanceOf(address(this));
            pool.lpToken.safeTransferFrom(msg.sender, address(this), _amount);
            uint256 received = pool.lpToken.balanceOf(address(this)) - balBefore;
            require(received == _amount, "fee-on-transfer not supported");

            credited = _amount;
            user.amount += credited;
            pool.totalStaked += credited;

            if (address(pool.lpToken) == address(rewardToken)) {
                pool.rewardTokenStaked += credited;
                totalRewardTokenStakedAsLP += credited;
            }

            if (!isAuto) {
                user.lastDepositTime = block.timestamp;
            } else {
                autoYieldDeposited[_pid][_user] += credited;
                emit AutoYieldDeposit(_user, _pid, credited);
            }
        }

        user.rewardDebt = (user.amount * pool.accRewardPerShare) / PRECISION_FACTOR;

        if (_referrer != address(0) && address(referralManager) != address(0)) {
            referralManager.recordReferral(_user, _referrer);
        }

        emit Deposit(_user, _pid, credited);
    }

    function harvest(uint256 _pid) external nonReentrant whenNotPaused {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];

        updatePool(_pid);

        uint256 pending = (user.amount * pool.accRewardPerShare) / PRECISION_FACTOR - user.rewardDebt;
        uint256 gross = user.unpaid + pending;

        user.rewardDebt = (user.amount * pool.accRewardPerShare) / PRECISION_FACTOR;
        user.unpaid = 0;

        if (gross == 0 || block.timestamp < user.lastDepositTime + pool.harvestDelay) {
            user.unpaid = gross;
            return;
        }

        uint256 availableGlobal = _payableRewardLiquidity();
        uint256 availablePool = poolRewardReserve[_pid];
        uint256 pay = _min3(gross, availableGlobal, availablePool);

        if (pay > 0) {
            _releasePoolRewards(_pid, pay);

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

        uint256 pending = (user.amount * pool.accRewardPerShare) / PRECISION_FACTOR - user.rewardDebt;
        uint256 gross = user.unpaid + pending;

        bool canHarvest = gross > 0 && block.timestamp >= user.lastDepositTime + pool.harvestDelay;
        if (canHarvest) {
            uint256 availableGlobal = _payableRewardLiquidity();
            uint256 availablePool = poolRewardReserve[_pid];
            uint256 pay = _min3(gross, availableGlobal, availablePool);

            if (pay > 0) {
                _releasePoolRewards(_pid, pay);

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

        user.rewardDebt = (user.amount * pool.accRewardPerShare) / PRECISION_FACTOR;
    }

    function emergencyWithdraw(uint256 _pid) external nonReentrant {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];

        uint256 amount = user.amount;
        require(amount > 0, "nothing to withdraw");

        // Settle pool first so user accounting is consistent.
        updatePool(_pid);

        // User forfeits rewards. Do NOT release reserve here.
        // This keeps economics conservative and avoids changing emergency behavior.
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

    function pendingReward(uint256 _pid, address _user) public view returns (uint256) {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_user];

        uint256 acc = pool.accRewardPerShare;
        uint256 lpSupply = pool.totalStaked;
        uint256 queued = pendingGaugeRewards[_pid];

        if (lpSupply > 0 && queued > 0) {
            acc += (queued * PRECISION_FACTOR) / lpSupply;
        }

        if (
            block.number > pool.lastRewardBlock &&
            lpSupply > 0 &&
            totalAllocPoint > 0 &&
            !emissionsPaused
        ) {
            uint256 blocks = block.number - pool.lastRewardBlock;
            uint256 reward = (blocks * rewardPerBlock * pool.allocPoint) / totalAllocPoint;
            acc += (reward * PRECISION_FACTOR) / lpSupply;
        }

        uint256 gross = user.unpaid + ((user.amount * acc) / PRECISION_FACTOR - user.rewardDebt);

        // View now respects reserve isolation for more realistic UI expectations.
        uint256 reserveCap = poolRewardReserve[_pid];
        return gross > reserveCap ? reserveCap : gross;
    }

    function pendingRewardAfterFee(uint256 _pid, address _user)
        public
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

    /// @notice Original behavior: gross payable reward balance excluding staked reward-token LP.
    function _payableRewardLiquidity() internal view returns (uint256) {
        uint256 bal = rewardToken.balanceOf(address(this));
        return bal > totalRewardTokenStakedAsLP ? bal - totalRewardTokenStakedAsLP : 0;
    }

    /// @notice Free unreserved reward liquidity after excluding pool-reserved obligations.
    function _freeRewardLiquidity() internal view returns (uint256) {
        uint256 payableBal = _payableRewardLiquidity();
        return payableBal > totalRewardReserved ? payableBal - totalRewardReserved : 0;
    }

    /// @notice Backward-compatible gross available amount.
    function availableRewards() external view returns (uint256) {
        return _payableRewardLiquidity();
    }

    function payableRewards() external view returns (uint256) {
        return _payableRewardLiquidity();
    }

    function freeRewardLiquidity() external view returns (uint256) {
        return _freeRewardLiquidity();
    }

    function poolLength() external view returns (uint256) {
        return poolInfo.length;
    }

    function _reservePoolRewards(uint256 _pid, uint256 amount) internal {
        if (amount == 0) return;
        poolRewardReserve[_pid] += amount;
        totalRewardReserved += amount;
        emit PoolRewardReserved(_pid, amount, poolRewardReserve[_pid]);
    }

    function _releasePoolRewards(uint256 _pid, uint256 amount) internal {
        if (amount == 0) return;

        uint256 reserved = poolRewardReserve[_pid];
        require(reserved >= amount, "pool reserve insufficient");

        poolRewardReserve[_pid] = reserved - amount;
        totalRewardReserved -= amount;

        emit PoolRewardReleased(_pid, amount, poolRewardReserve[_pid]);
    }

    function _min3(uint256 a, uint256 b, uint256 c) internal pure returns (uint256) {
        uint256 m = a < b ? a : b;
        return m < c ? m : c;
    }
}
