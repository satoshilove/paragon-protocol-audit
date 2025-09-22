// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.25;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

interface IFactory {
    function getPair(address, address) external view returns (address);
}

contract LPFlowRebates is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    struct RewardData {
        uint256 rewardPerTokenStored; // 1e18 scale
        uint256 queued;               // rewards queued when no stakers
    }

    IFactory public immutable factory;
    address public notifier; // PayflowExecutorV2

    // lpToken => totalStaked
    mapping(address => uint256) public totalStaked;
    // lpToken => user => balance
    mapping(address => mapping(address => uint256)) public balances;
    // lpToken => rewardToken => RewardData
    mapping(address => mapping(address => RewardData)) public rewardData;
    // lpToken => user => rewardToken => userPaid RPT
    mapping(address => mapping(address => mapping(address => uint256))) public userPaidPerToken;
    // lpToken => user => rewardToken => accrued
    mapping(address => mapping(address => mapping(address => uint256))) public accrued;

    // Optional allowlist of reward tokens so we can iterate and release queued rewards on first stake.
    address[] public supportedRewardTokens;
    uint8 public constant MAX_SUPPORTED_REWARDS = 20;

    error BadArg();
    error InsufficientBalance();
    error MaxRewards();
    error BadIndex();

    event NotifierSet(address indexed n);
    event Staked(address indexed user, address indexed lp, uint256 amount);
    event Withdrawn(address indexed user, address indexed lp, uint256 amount);
    event Notified(address indexed lp, address indexed reward, uint256 amount);
    event Claimed(address indexed user, address indexed lp, address indexed reward, uint256 amount);
    event SupportedRewardAdded(address indexed reward);
    event SupportedRewardRemoved(address indexed reward);

    modifier onlyNotifier() {
        if (msg.sender != notifier) revert BadArg();
        _;
    }

    constructor(address _factory, address _notifier, address _owner) Ownable(_owner) {
        if (_factory == address(0)) revert BadArg();
        factory  = IFactory(_factory);
        notifier = _notifier; // can be zero; set later
    }

    // --- admin ---
    function setNotifier(address n) external onlyOwner {
        notifier = n;
        emit NotifierSet(n);
    }

    function addSupportedReward(address reward) external onlyOwner {
        if (reward == address(0)) revert BadArg();
        if (supportedRewardTokens.length >= MAX_SUPPORTED_REWARDS) revert MaxRewards();
        supportedRewardTokens.push(reward);
        emit SupportedRewardAdded(reward);
    }

    function removeSupportedReward(uint256 index) external onlyOwner {
        if (index >= supportedRewardTokens.length) revert BadIndex();
        address reward = supportedRewardTokens[index];
        supportedRewardTokens[index] = supportedRewardTokens[supportedRewardTokens.length - 1];
        supportedRewardTokens.pop();
        emit SupportedRewardRemoved(reward);
    }

    function getSupportedRewardTokens() external view returns (address[] memory) {
        return supportedRewardTokens;
    }

    // --- helpers ---
    function _pair(address a, address b) internal view returns (address p) {
        p = factory.getPair(a, b);
        if (p == address(0)) p = factory.getPair(b, a);
    }

    function _rewardPerToken(address lp, address reward) internal view returns (uint256) {
        return rewardData[lp][reward].rewardPerTokenStored;
    }

    function earned(address user, address lp, address reward) external view returns (uint256) {
        uint256 rpt  = _rewardPerToken(lp, reward);
        uint256 paid = userPaidPerToken[lp][user][reward];
        uint256 bal  = balances[lp][user];
        return accrued[lp][user][reward] + (bal * (rpt - paid)) / 1e18;
    }

    // --- stake/withdraw ---
    function stake(address lp, uint256 amount) external nonReentrant {
        if (amount == 0) revert BadArg();
        _settleAll(msg.sender, lp);
        balances[lp][msg.sender] += amount;
        totalStaked[lp] += amount;
        IERC20(lp).safeTransferFrom(msg.sender, address(this), amount);
        emit Staked(msg.sender, lp, amount);
        _releaseQueued(lp);
    }

    function withdraw(address lp, uint256 amount) external nonReentrant {
        if (amount == 0) revert BadArg();
        if (balances[lp][msg.sender] < amount) revert InsufficientBalance();
        _settleAll(msg.sender, lp);
        balances[lp][msg.sender] -= amount;
        totalStaked[lp] -= amount;
        IERC20(lp).safeTransfer(msg.sender, amount);
        emit Withdrawn(msg.sender, lp, amount);
    }

    function claim(address lp, address[] calldata rewards) external nonReentrant {
        for (uint i; i < rewards.length; i++) {
            _settleOne(msg.sender, lp, rewards[i]);
            uint256 a = accrued[lp][msg.sender][rewards[i]];
            if (a > 0) {
                accrued[lp][msg.sender][rewards[i]] = 0;
                IERC20(rewards[i]).safeTransfer(msg.sender, a);
                emit Claimed(msg.sender, lp, rewards[i], a);
            }
        }
    }

    // --- executor hook ---
    // Matches ParagonPayflowExecutorV2: notify(tokenIn, tokenOut, rewardToken, amount)
    function notify(address tokenIn, address tokenOut, address rewardToken, uint256 amount)
        external
        onlyNotifier
        nonReentrant
    {
        address lp = _pair(tokenIn, tokenOut);
        if (lp == address(0)) revert BadArg();

        IERC20(rewardToken).safeTransferFrom(msg.sender, address(this), amount);

        RewardData storage R = rewardData[lp][rewardToken];
        uint256 ts = totalStaked[lp];
        if (ts == 0) {
            R.queued += amount;
        } else {
            R.rewardPerTokenStored += (amount * 1e18) / ts;
        }

        emit Notified(lp, rewardToken, amount);
    }

    // --- internals ---
    function _releaseQueued(address lp) internal {
        uint256 ts = totalStaked[lp];
        if (ts == 0) return;
        for (uint i; i < supportedRewardTokens.length; i++) {
            address reward = supportedRewardTokens[i];
            RewardData storage R = rewardData[lp][reward];
            if (R.queued > 0) {
                R.rewardPerTokenStored += (R.queued * 1e18) / ts;
                R.queued = 0;
            }
        }
    }

    function _settleAll(address user, address lp) internal {
        for (uint i; i < supportedRewardTokens.length; i++) {
            _settleOne(user, lp, supportedRewardTokens[i]);
        }
    }

    function _settleOne(address user, address lp, address reward) internal {
        uint256 rpt  = _rewardPerToken(lp, reward);
        uint256 paid = userPaidPerToken[lp][user][reward];
        if (rpt == paid) return;
        userPaidPerToken[lp][user][reward] = rpt;
        uint256 bal = balances[lp][user];
        if (bal > 0) {
            accrued[lp][user][reward] += (bal * (rpt - paid)) / 1e18;
        }
    }

    // emergency (owner) for stuck queued funds
    function emergencySweep(address lp, address reward, address to, uint256 amount) external onlyOwner {
        if (to == address(0)) revert BadArg();
        RewardData storage R = rewardData[lp][reward];
        if (amount > R.queued) amount = R.queued;
        if (amount > 0) {
            R.queued -= amount;
            IERC20(reward).safeTransfer(to, amount);
        }
    }
}
