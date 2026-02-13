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
    // PAD-23
    function rewardToken() external view returns (address);
    // PAD-36 hardening (optional but recommended)
    function minDripAmount() external view returns (uint256);
    function dripCooldownSecs() external view returns (uint64);
    function lastDripAt() external view returns (uint64);
}

/**
 * @title ParagonFarmController - Final Production Release (November 2025) - Audit fixes applied
 * @notice High-performance MasterChef-style farm with full safety when rewardToken is used as LP token
 * @dev Design choice: LP tokens must be standard ERC20 (no fee-on-transfer / rebasing). This matches Pancake/Sushi
 *      MasterChef assumptions and avoids accounting ambiguity (PAD-07).
 */
contract ParagonFarmController is Ownable, AccessControlEnumerable, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;

    bytes32 public constant GUARDIAN_ROLE = keccak256("GUARDIAN_ROLE");
    bytes32 public constant AUTOYIELD_CALLER_ROLE = keccak256("AUTOYIELD_CALLER_ROLE");

    uint256 public constant PRECISION_FACTOR = 1e30;

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
        uint256 accRewardPerShare; // × PRECISION_FACTOR
        uint256 harvestDelay;      // Seconds before rewards are claimable
        uint256 totalStaked;       // Total LP staked
        uint256 rewardTokenStaked; // Only used if lpToken == rewardToken
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
    uint64 public dripCooldownSecs = 900; // 15 min
    uint64 public lastDripAt;
    uint256 public minDripAmount;

    uint16 public constant MAX_PERF_FEE_BIPS = 500; // 5.00%
    address public feeRecipient;
    uint16 public performanceFeeBips;

    PoolInfo[] public poolInfo;
    mapping(uint256 pid => mapping(address user => UserInfo)) public userInfo;

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
    event AutoYieldCallerUpdated(address indexed caller, bool allowed);

    // ────────────────────────────── Ownership + Admin Role Sync (PAD-51 FIX) ──────────────────────────────
    event OwnershipAndAdminTransferred(address indexed previousOwner, address indexed newOwner);
    // Per-admin revoke visibility (monitoring/audit trail)
    event ExtraAdminRevoked(address indexed revokedAdmin);

    constructor(
        address initialOwner,
        IERC20 _rewardToken,
        uint256 _rewardPerBlock,
        uint256 _startBlock
    ) Ownable(initialOwner) {
        require(initialOwner != address(0), "zero owner");
        require(address(_rewardToken) != address(0), "zero reward token");

        rewardToken = _rewardToken;
        rewardPerBlock = _rewardPerBlock;
        startBlock = _startBlock;
        feeRecipient = initialOwner;

        // PAD-20: Dynamic minDripAmount ≈ 1000 full tokens
        try IERC20Metadata(address(_rewardToken)).decimals() returns (uint8 dec) {
            minDripAmount = 1000 * (10 ** uint256(dec));
        } catch {
            minDripAmount = 1000 * 1e18;
        }

        _grantRole(DEFAULT_ADMIN_ROLE, initialOwner);
    }

    // ────────────────────────────── Ownership Override (PAD-51) ──────────────────────────────

    /**
     * @dev Enforce strict coupling: after any ownership transfer, only the new owner holds DEFAULT_ADMIN_ROLE.
     *      This prevents privilege fragmentation even if extra admins were previously granted manually.
     */
    function transferOwnership(address newOwner) public virtual override onlyOwner {
        require(newOwner != address(0), "Ownable: new owner is the zero address");
        address oldOwner = owner();

        // Perform the standard ownership transfer
        super.transferOwnership(newOwner);

        // Grant DEFAULT_ADMIN_ROLE to newOwner if not already held
        if (!hasRole(DEFAULT_ADMIN_ROLE, newOwner)) {
            _grantRole(DEFAULT_ADMIN_ROLE, newOwner);
        }

        // Revoke DEFAULT_ADMIN_ROLE from all other holders (safe snapshot pattern)
        uint256 count = getRoleMemberCount(DEFAULT_ADMIN_ROLE);
        address[] memory revokeList = new address[](count);

        // Snapshot current members (excluding newOwner)
        for (uint256 i = 0; i < count; i++) {
            address member = getRoleMember(DEFAULT_ADMIN_ROLE, i);
            if (member != newOwner) {
                revokeList[i] = member;
            }
        }

        // Revoke from snapshot
        for (uint256 i = 0; i < count; i++) {
            address member = revokeList[i];
            if (member != address(0) && member != newOwner) { // extra safety
                _revokeRole(DEFAULT_ADMIN_ROLE, member);
                emit ExtraAdminRevoked(member);
            }
        }

        emit OwnershipAndAdminTransferred(oldOwner, newOwner);
    }

    // Prevent accidental renounce (recommended for governance contracts)
    function renounceOwnership() public virtual override onlyOwner {
        revert("Renounce ownership disabled for safety");
    }

    // ────────────────────────────── Guardian / Pause ──────────────────────────────

    function pause() external onlyRole(GUARDIAN_ROLE) {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    // ────────────────────────────── Admin Functions ──────────────────────────────

    function setReferralManager(address _ref) external onlyOwner {
        require(_ref != address(0), "zero ref");
        referralManager = IReferralManager(_ref);
    }

    function setAutoYieldCaller(address caller, bool allowed) external onlyOwner {
        require(caller != address(0), "zero caller");
        if (allowed) {
            _grantRole(AUTOYIELD_CALLER_ROLE, caller);
        } else {
            _revokeRole(AUTOYIELD_CALLER_ROLE, caller);
        }
        emit AutoYieldCallerUpdated(caller, allowed);
    }

    function setRewardPerBlock(uint256 _rpb) external onlyOwner {
        massUpdateAllPools();
        emit RewardPerBlockUpdated(rewardPerBlock, _rpb);
        rewardPerBlock = _rpb;
    }

    function setEmissionsPaused(bool _paused) external onlyOwner {
        if (_paused == emissionsPaused) return;

        if (_paused) {
            massUpdateAllPools();
            emissionsPaused = true;
            emit EmissionsPaused(true);
            return;
        }

        massUpdateAllPools();
        emissionsPaused = false;
        emit EmissionsPaused(false);
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
        require(_min > 0, "min=0");

        if (_dripper != address(0)) {
            IRewardDripper newDripper = IRewardDripper(_dripper);
            require(newDripper.rewardToken() == address(rewardToken), "reward token mismatch");
            dripper = newDripper;
        } else {
            dripper = IRewardDripper(address(0));
        }

        lowWaterDays = _days;
        dripCooldownSecs = _cooldown;
        minDripAmount = _min;

        emit DripperConfigUpdated(_dripper, _days, _cooldown, _min);
    }

    // ────────────────────────────── Pool Management ──────────────────────────────

    function addPool(uint256 _allocPoint, IERC20 _lpToken, uint256 _harvestDelay) external onlyOwner {
        require(address(_lpToken) != address(0), "zero lpToken");
        require(poolInfo.length < 300, "Maximum number of pools reached");

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

        try dripper.pendingAccrued() returns (uint256 p) {
            if (p >= minDripAmount) {
                try dripper.drip() returns (uint256 sent) {
                    if (sent > 0) {
                        lastDripAt = uint64(block.timestamp);
                    }
                    emit DripperPoked(sent, _availableRewards());
                } catch {}
            }
        } catch {}
    }

    function pokeDripper() external {
        _maybeTopUpFromDripper();
    }

    // ────────────────────────────── Core Functions ──────────────────────────────

    function massUpdateAllPools() public {
        uint256 len = poolInfo.length;
        for (uint256 i = 0; i < len; ++i) {
            updatePool(i);
        }
    }

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
            pool.accRewardPerShare += (reward * PRECISION_FACTOR) / lpSupply;
        }

        pool.lastRewardBlock = block.number;
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
            require(received == _amount, "Fee-on-transfer/deflationary tokens not supported");

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

        uint256 pending = (user.amount * pool.accRewardPerShare) / PRECISION_FACTOR - user.rewardDebt;
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

        user.rewardDebt = (user.amount * pool.accRewardPerShare) / PRECISION_FACTOR;
    }

    function emergencyWithdraw(uint256 _pid) external nonReentrant {
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
            acc += (reward * PRECISION_FACTOR) / lpSupply;
        }

        return user.unpaid + ((user.amount * acc) / PRECISION_FACTOR - user.rewardDebt);
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