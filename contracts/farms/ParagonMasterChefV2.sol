// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

interface IParagonRewardDripper {
    function drip() external returns (uint256 sent);
    function pendingAccrued() external view returns (uint256);
    function rewardToken() external view returns (address);
}

/// @title ParagonMasterChefV2
/// @notice Dripper-funded MasterChef with separate regular/special pool emissions and optional boost shares.
/// @dev Rewards are not minted by this contract. Fund through RewardDripperEscrow or direct reward deposits.
contract ParagonMasterChefV2 is Ownable2Step, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 public constant ACC_REWARD_PRECISION = 1e30;
    uint16 public constant BIPS = 10_000;
    uint16 public constant MIN_BOOST_BIPS = 10_000;
    uint16 public constant MAX_BOOST_BIPS = 20_000;
    uint16 public constant MAX_DEV_FEE_BIPS = 1_000;
    uint256 public constant MAX_POOLS = 20;

    struct UserInfo {
        uint256 amount;
        uint256 boostedAmount;
        uint256 rewardDebt;
        uint256 unpaidRewards;
        uint16 boostBips;
    }

    struct PoolInfo {
        IERC20 lpToken;
        uint256 allocPoint;
        uint256 lastRewardBlock;
        uint256 accRewardPerShare;
        uint256 totalStaked;
        uint256 totalBoostedShare;
        bool isRegular;
        bool depositsRestricted;
    }

    IERC20 public immutable rewardToken;
    IParagonRewardDripper public dripper;
    address public devAddress;

    uint256 public rewardPerBlock;
    uint256 public startBlock;
    uint256 public endBlock;

    uint256 public totalRegularAllocPoint;
    uint256 public totalSpecialAllocPoint;
    uint16 public regularRewardBips = BIPS;
    uint16 public devFeeBips;
    uint256 public maxRewardPerBlock = type(uint256).max;

    uint256 public totalRewardTokenStakedAsLP;
    uint256 public rewardLiability;
    uint256 public lowWaterBlocks = 115_200;
    uint64 public dripCooldownSecs = 900;
    uint64 public lastDripAt;
    uint256 public minDripAmount;

    PoolInfo[] public poolInfo;
    mapping(uint256 pid => mapping(address user => UserInfo)) public userInfo;
    mapping(address lpToken => bool) public lpTokenAdded;
    mapping(address account => bool) public specialDepositor;

    event Deposit(address indexed user, uint256 indexed pid, uint256 amount, address indexed receiver);
    event Withdraw(address indexed user, uint256 indexed pid, uint256 amount);
    event Harvest(address indexed user, uint256 indexed pid, uint256 amount, uint256 unpaid);
    event EmergencyWithdraw(address indexed user, uint256 indexed pid, uint256 amount);
    event PoolAdded(uint256 indexed pid, address indexed lpToken, uint256 allocPoint, bool isRegular, bool restricted);
    event PoolUpdated(
        uint256 indexed pid,
        uint256 oldAllocPoint,
        uint256 newAllocPoint,
        bool oldIsRegular,
        bool newIsRegular,
        bool restricted
    );
    event RewardPerBlockUpdated(uint256 oldRate, uint256 newRate);
    event MaxRewardPerBlockUpdated(uint256 oldMax, uint256 newMax);
    event RewardEndBlockUpdated(uint256 oldEndBlock, uint256 newEndBlock);
    event RewardSplitUpdated(uint16 regularRewardBips, uint16 specialRewardBips);
    event DevAddressUpdated(address indexed oldAddress, address indexed newAddress);
    event DevFeeUpdated(uint16 oldFeeBips, uint16 newFeeBips);
    event DripperConfigUpdated(address indexed dripper, uint256 lowWaterBlocks, uint64 cooldown, uint256 minDrip);
    event DripperPoked(uint256 sent, uint256 freeRewardBalanceAfter);
    event RewardsFunded(address indexed funder, uint256 amount);
    event BoostUpdated(uint256 indexed pid, address indexed user, uint16 boostBips, uint256 boostedAmount);
    event SpecialDepositorUpdated(address indexed account, bool allowed);
    event RewardTokensRecovered(address indexed to, uint256 amount);
    event NonRewardTokensRecovered(address indexed token, address indexed to, uint256 amount);

    constructor(
        IERC20 _rewardToken,
        address _devAddress,
        uint256 _rewardPerBlock,
        uint256 _startBlock,
        uint256 _endBlock
    ) Ownable(msg.sender) {
        require(address(_rewardToken) != address(0), "reward=0");
        require(_devAddress != address(0), "dev=0");
        require(_endBlock == 0 || _endBlock > _startBlock, "bad end");
        rewardToken = _rewardToken;
        devAddress = _devAddress;
        rewardPerBlock = _rewardPerBlock;
        startBlock = _startBlock;
        endBlock = _endBlock;
    }

    function poolLength() external view returns (uint256) { return poolInfo.length; }

    function addPool(
        uint256 _allocPoint,
        IERC20 _lpToken,
        bool _isRegular,
        bool _depositsRestricted,
        bool _withUpdate
    ) external onlyOwner nonReentrant {
        require(address(_lpToken) != address(0), "lp=0");
        require(!lpTokenAdded[address(_lpToken)], "lp exists");
        require(poolInfo.length < MAX_POOLS, "max pools");
        _withUpdate;
        _massUpdatePools();
        uint256 lastRewardBlock = block.number > startBlock ? block.number : startBlock;
        lpTokenAdded[address(_lpToken)] = true;
        _increaseAlloc(_isRegular, _allocPoint);
        poolInfo.push(PoolInfo({
            lpToken: _lpToken, allocPoint: _allocPoint, lastRewardBlock: lastRewardBlock,
            accRewardPerShare: 0, totalStaked: 0, totalBoostedShare: 0,
            isRegular: _isRegular, depositsRestricted: _depositsRestricted
        }));
        emit PoolAdded(poolInfo.length - 1, address(_lpToken), _allocPoint, _isRegular, _depositsRestricted);
    }

    /// @dev `_withUpdate` is deprecated and ignored. This function always settles all pools first
    /// to avoid retroactive mis-accounting when allocation points or pool category change.
    function setPool(
        uint256 _pid,
        uint256 _allocPoint,
        bool _isRegular,
        bool _depositsRestricted,
        bool _withUpdate
    ) external onlyOwner nonReentrant {
        _withUpdate;
        _massUpdatePools();

        PoolInfo storage pool = poolInfo[_pid];
        uint256 oldAllocPoint = pool.allocPoint;
        bool oldIsRegular = pool.isRegular;

        _decreaseAlloc(pool.isRegular, oldAllocPoint);
        _increaseAlloc(_isRegular, _allocPoint);

        pool.allocPoint = _allocPoint;
        pool.isRegular = _isRegular;
        pool.depositsRestricted = _depositsRestricted;

        emit PoolUpdated(_pid, oldAllocPoint, _allocPoint, oldIsRegular, _isRegular, _depositsRestricted);
    }

    function setRewardPerBlock(uint256 _rewardPerBlock) external onlyOwner nonReentrant {
        require(_rewardPerBlock <= maxRewardPerBlock, "rate too high");
        _massUpdatePools();
        emit RewardPerBlockUpdated(rewardPerBlock, _rewardPerBlock);
        rewardPerBlock = _rewardPerBlock;
    }

    function setMaxRewardPerBlock(uint256 _maxRewardPerBlock) external onlyOwner {
        require(rewardPerBlock <= _maxRewardPerBlock, "below current rate");
        emit MaxRewardPerBlockUpdated(maxRewardPerBlock, _maxRewardPerBlock);
        maxRewardPerBlock = _maxRewardPerBlock;
    }

    function setEndBlock(uint256 _endBlock) external onlyOwner nonReentrant {
        require(_endBlock == 0 || _endBlock > block.number, "bad end");
        _massUpdatePools();
        emit RewardEndBlockUpdated(endBlock, _endBlock);
        endBlock = _endBlock;
    }

    function setRewardSplit(uint16 _regularRewardBips) external onlyOwner nonReentrant {
        require(_regularRewardBips <= BIPS, "split too high");
        _massUpdatePools();
        regularRewardBips = _regularRewardBips;
        emit RewardSplitUpdated(_regularRewardBips, BIPS - _regularRewardBips);
    }

    function setDripperConfig(
        address _dripper,
        uint256 _lowWaterBlocks,
        uint64 _cooldown,
        uint256 _minDrip
    ) external onlyOwner nonReentrant {
        if (_dripper != address(0)) {
            IParagonRewardDripper newDripper = IParagonRewardDripper(_dripper);
            require(newDripper.rewardToken() == address(rewardToken), "token mismatch");
            dripper = newDripper;
        } else {
            dripper = IParagonRewardDripper(address(0));
        }
        lowWaterBlocks = _lowWaterBlocks;
        dripCooldownSecs = _cooldown;
        minDripAmount = _minDrip;
        emit DripperConfigUpdated(_dripper, _lowWaterBlocks, _cooldown, _minDrip);
    }

    function setDevAddress(address _devAddress) external onlyOwner {
        require(_devAddress != address(0), "dev=0");
        emit DevAddressUpdated(devAddress, _devAddress);
        devAddress = _devAddress;
    }

    function setDevFeeBips(uint16 _devFeeBips) external onlyOwner nonReentrant {
        require(_devFeeBips <= MAX_DEV_FEE_BIPS, "fee too high");
        _massUpdatePools();
        emit DevFeeUpdated(devFeeBips, _devFeeBips);
        devFeeBips = _devFeeBips;
    }

    function setSpecialDepositor(address _account, bool _allowed) external onlyOwner {
        require(_account != address(0), "account=0");
        specialDepositor[_account] = _allowed;
        emit SpecialDepositorUpdated(_account, _allowed);
    }

    function setUserBoost(uint256 _pid, address _user, uint16 _boostBips) external onlyOwner nonReentrant {
        require(_user != address(0), "user=0");
        require(_boostBips >= MIN_BOOST_BIPS && _boostBips <= MAX_BOOST_BIPS, "bad boost");
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_user];
        _updatePool(_pid);
        _harvest(_pid, _user, pool, user);
        pool.totalBoostedShare = pool.totalBoostedShare - user.boostedAmount;
        user.boostBips = _boostBips;
        user.boostedAmount = _boosted(user.amount, _boostBips);
        pool.totalBoostedShare += user.boostedAmount;
        user.rewardDebt = (user.boostedAmount * pool.accRewardPerShare) / ACC_REWARD_PRECISION;
        emit BoostUpdated(_pid, _user, _boostBips, user.boostedAmount);
    }

    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }

    function renounceOwnership() public view override onlyOwner { revert("renounce disabled"); }

    function pendingXPGN(uint256 _pid, address _user) external view returns (uint256) {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_user];
        uint256 accRewardPerShare = pool.accRewardPerShare;
        if (pool.totalBoostedShare > 0) {
            uint256 reward = _poolReward(pool, pool.lastRewardBlock, _effectiveBlock(block.number));
            uint256 netReward = reward - _devReward(reward);
            accRewardPerShare += (netReward * ACC_REWARD_PRECISION) / pool.totalBoostedShare;
        }
        return ((user.boostedAmount * accRewardPerShare) / ACC_REWARD_PRECISION) - user.rewardDebt + user.unpaidRewards;
    }

    function availableRewardBalance() public view returns (uint256) {
        uint256 balance = rewardToken.balanceOf(address(this));
        return balance > totalRewardTokenStakedAsLP ? balance - totalRewardTokenStakedAsLP : 0;
    }

    function unreservedRewardBalance() public view returns (uint256) {
        uint256 available = availableRewardBalance();
        return available > rewardLiability ? available - rewardLiability : 0;
    }

    function massUpdatePools() external nonReentrant {
        _massUpdatePools();
    }

    function updatePool(uint256 _pid) external nonReentrant {
        _updatePool(_pid);
    }

    function _massUpdatePools() private {
        uint256 length = poolInfo.length;
        for (uint256 pid = 0; pid < length; ++pid) { _updatePool(pid, false); }
        _maybeTopUpFromDripper();
    }

    function _updatePool(uint256 _pid) private {
        _updatePool(_pid, true);
    }

    function _updatePool(uint256 _pid, bool _topUpAfter) private {
        PoolInfo storage pool = poolInfo[_pid];
        uint256 toBlock = _effectiveBlock(block.number);
        if (toBlock <= pool.lastRewardBlock) return;
        if (pool.totalBoostedShare == 0 || pool.allocPoint == 0) {
            pool.lastRewardBlock = toBlock;
            return;
        }
        uint256 reward = _poolReward(pool, pool.lastRewardBlock, toBlock);
        uint256 devReward = _devReward(reward);
        uint256 netReward = reward - devReward;

        // FIX F-01: CEI - update state before any external token transfer.
        pool.lastRewardBlock = toBlock;
        if (netReward > 0) {
            pool.accRewardPerShare += (netReward * ACC_REWARD_PRECISION) / pool.totalBoostedShare;
            rewardLiability += netReward;
        }
        if (devReward > 0) {
            _safeRewardTransfer(devAddress, devReward);
        }
        if (_topUpAfter) _maybeTopUpFromDripper();
    }

    function deposit(uint256 _pid, uint256 _amount) external nonReentrant whenNotPaused {
        _deposit(_pid, _amount, msg.sender, msg.sender);
    }

    function depositFor(uint256 _pid, uint256 _amount, address _receiver) external nonReentrant whenNotPaused {
        _deposit(_pid, _amount, msg.sender, _receiver);
    }

    function withdraw(uint256 _pid, uint256 _amount) external nonReentrant {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        require(user.amount >= _amount, "withdraw too much");
        _updatePool(_pid);
        if (paused()) _accrueUnpaid(pool, user);
        else _harvest(_pid, msg.sender, pool, user);
        if (_amount > 0) {
            uint256 oldBoosted = user.boostedAmount;
            user.amount -= _amount;
            user.boostedAmount = _boosted(user.amount, _userBoostBips(user));
            pool.totalStaked -= _amount;
            pool.totalBoostedShare = pool.totalBoostedShare - oldBoosted + user.boostedAmount;
            if (address(pool.lpToken) == address(rewardToken)) totalRewardTokenStakedAsLP -= _amount;
            pool.lpToken.safeTransfer(msg.sender, _amount);
        }
        user.rewardDebt = (user.boostedAmount * pool.accRewardPerShare) / ACC_REWARD_PRECISION;
        emit Withdraw(msg.sender, _pid, _amount);
    }

    function harvest(uint256 _pid) external nonReentrant whenNotPaused {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        _updatePool(_pid);
        _harvest(_pid, msg.sender, pool, user);
        user.rewardDebt = (user.boostedAmount * pool.accRewardPerShare) / ACC_REWARD_PRECISION;
    }

    /// @notice Withdraws staked tokens immediately and forfeits all pending and unpaid rewards for this pool.
    function emergencyWithdraw(uint256 _pid) external nonReentrant {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        _updatePool(_pid);

        uint256 amount = user.amount;
        uint256 boostedAmount = user.boostedAmount;
        uint256 forfeited = _pending(pool, user);
        if (forfeited > 0) _releaseLiability(forfeited);

        user.amount = 0;
        user.boostedAmount = 0;
        user.rewardDebt = 0;
        user.unpaidRewards = 0;
        pool.totalStaked -= amount;
        pool.totalBoostedShare -= boostedAmount;
        if (address(pool.lpToken) == address(rewardToken)) totalRewardTokenStakedAsLP -= amount;
        pool.lpToken.safeTransfer(msg.sender, amount);
        emit EmergencyWithdraw(msg.sender, _pid, amount);
    }

    function fundRewards(uint256 _amount) external nonReentrant {
        require(_amount > 0, "amount=0");
        rewardToken.safeTransferFrom(msg.sender, address(this), _amount);
        emit RewardsFunded(msg.sender, _amount);
    }

    function pokeDripper() external nonReentrant { _maybeTopUpFromDripper(); }

    function recoverRewardTokens(address _to, uint256 _amount) external onlyOwner nonReentrant {
        require(_to != address(0), "to=0");
        require(_amount <= unreservedRewardBalance(), "exceeds rewards");
        rewardToken.safeTransfer(_to, _amount);
        emit RewardTokensRecovered(_to, _amount);
    }

    function recoverNonRewardTokens(IERC20 _token, address _to, uint256 _amount) external onlyOwner nonReentrant {
        require(address(_token) != address(0), "token=0");
        require(address(_token) != address(rewardToken), "use reward recovery");
        require(!lpTokenAdded[address(_token)], "lp token");
        require(_to != address(0), "to=0");
        _token.safeTransfer(_to, _amount);
        emit NonRewardTokensRecovered(address(_token), _to, _amount);
    }

    function _deposit(uint256 _pid, uint256 _amount, address _from, address _receiver) private {
        require(_receiver != address(0), "receiver=0");
        require(_amount > 0 || _from == _receiver, "zero depositFor");
        PoolInfo storage pool = poolInfo[_pid];
        require(!pool.depositsRestricted || specialDepositor[_from] || _from == owner(), "restricted");
        UserInfo storage user = userInfo[_pid][_receiver];
        _updatePool(_pid);
        _harvest(_pid, _receiver, pool, user);
        if (_amount > 0) {
            uint256 balanceBefore = pool.lpToken.balanceOf(address(this));
            pool.lpToken.safeTransferFrom(_from, address(this), _amount);
            uint256 received = pool.lpToken.balanceOf(address(this)) - balanceBefore;
            require(received > 0, "received=0");
            uint256 oldBoosted = user.boostedAmount;
            user.amount += received;
            user.boostedAmount = _boosted(user.amount, _userBoostBips(user));
            pool.totalStaked += received;
            pool.totalBoostedShare = pool.totalBoostedShare - oldBoosted + user.boostedAmount;
            if (address(pool.lpToken) == address(rewardToken)) totalRewardTokenStakedAsLP += received;
        }
        user.rewardDebt = (user.boostedAmount * pool.accRewardPerShare) / ACC_REWARD_PRECISION;
        emit Deposit(_from, _pid, _amount, _receiver);
    }

    function _harvest(uint256 _pid, address _to, PoolInfo storage _pool, UserInfo storage _user) private {
        uint256 pending = _pending(_pool, _user);
        if (pending == 0) return;
        uint256 paid = _safeRewardTransfer(_to, pending);
        _user.unpaidRewards = pending - paid;
        _releaseLiability(paid);
        emit Harvest(_to, _pid, paid, _user.unpaidRewards);
    }

    function _accrueUnpaid(PoolInfo storage _pool, UserInfo storage _user) private {
        _user.unpaidRewards = _pending(_pool, _user);
    }

    function _safeRewardTransfer(address _to, uint256 _amount) private returns (uint256 paid) {
        uint256 available = availableRewardBalance();
        paid = _amount > available ? available : _amount;
        if (paid > 0) {
            uint256 beforeBalance = rewardToken.balanceOf(_to);
            rewardToken.safeTransfer(_to, paid);
            paid = rewardToken.balanceOf(_to) - beforeBalance;
        }
    }

    function _maybeTopUpFromDripper() private {
        if (address(dripper) == address(0)) return;
        if (block.timestamp < lastDripAt + dripCooldownSecs) return;
        uint256 need = rewardPerBlock * lowWaterBlocks;
        if (unreservedRewardBalance() >= need && availableRewardBalance() >= rewardLiability) return;
        try dripper.pendingAccrued() returns (uint256 pending) {
            if (pending >= minDripAmount) {
                try dripper.drip() returns (uint256 sent) {
                    if (sent > 0 && unreservedRewardBalance() >= need && availableRewardBalance() >= rewardLiability) {
                        lastDripAt = uint64(block.timestamp);
                    }
                    emit DripperPoked(sent, availableRewardBalance());
                } catch {}
            }
        } catch {}
    }

    function _poolReward(PoolInfo storage _pool, uint256 _from, uint256 _to) private view returns (uint256) {
        if (_to <= _from || rewardPerBlock == 0) return 0;
        uint256 totalAlloc = _pool.isRegular ? totalRegularAllocPoint : totalSpecialAllocPoint;
        if (totalAlloc == 0) return 0;
        uint256 categoryBips = _pool.isRegular ? regularRewardBips : BIPS - regularRewardBips;
        if (categoryBips == 0) return 0;
        // FIX F-02: multiply all numerators before dividing to prevent intermediate precision loss
        return ((_to - _from) * rewardPerBlock * categoryBips * _pool.allocPoint) / (uint256(BIPS) * totalAlloc);
    }

    function _effectiveBlock(uint256 _blockNumber) private view returns (uint256) {
        if (_blockNumber < startBlock) return startBlock;
        if (endBlock != 0 && _blockNumber > endBlock) return endBlock;
        return _blockNumber;
    }

    function _userBoostBips(UserInfo storage _user) private view returns (uint16) {
        return _user.boostBips == 0 ? MIN_BOOST_BIPS : _user.boostBips;
    }

    function _boosted(uint256 _amount, uint16 _boostBips) private pure returns (uint256) {
        return (_amount * _boostBips) / BIPS;
    }

    function _devReward(uint256 _reward) private view returns (uint256) {
        return (_reward * devFeeBips) / BIPS;
    }

    function _pending(PoolInfo storage _pool, UserInfo storage _user) private view returns (uint256) {
        uint256 accumulated = (_user.boostedAmount * _pool.accRewardPerShare) / ACC_REWARD_PRECISION;
        return accumulated - _user.rewardDebt + _user.unpaidRewards;
    }

    function _releaseLiability(uint256 _amount) private {
        rewardLiability = _amount > rewardLiability ? 0 : rewardLiability - _amount;
    }

    function _increaseAlloc(bool _isRegular, uint256 _allocPoint) private {
        if (_isRegular) totalRegularAllocPoint += _allocPoint;
        else totalSpecialAllocPoint += _allocPoint;
    }

    function _decreaseAlloc(bool _isRegular, uint256 _allocPoint) private {
        if (_isRegular) totalRegularAllocPoint -= _allocPoint;
        else totalSpecialAllocPoint -= _allocPoint;
    }
}
