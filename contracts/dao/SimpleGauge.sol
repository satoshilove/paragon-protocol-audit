// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

contract SimpleGauge is Ownable, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;

    IERC20 public immutable stakingToken; // LP
    IERC20 public immutable rewardToken;  // XPGN
    address public controller;            // GaugeController (optional read)
    address public minter;                // EmissionsMinter (or owner) can notify

    uint256 public periodFinish;
    uint256 public rewardRate;
    uint256 public lastUpdateTime;
    uint256 public rewardPerTokenStored;

    mapping(address => uint256) public userRewardPerTokenPaid;
    mapping(address => uint256) public rewards;

    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;

    uint256 public constant DURATION = 7 days;

    event Notified(uint256 amount, uint256 newRate, uint256 periodFinish);
    event Staked(address indexed user, uint256 amount);
    event Withdrawn(address indexed user, uint256 amount);
    event RewardPaid(address indexed user, uint256 amount);
    event SetMinter(address indexed minter);

    /// @param _lp staking token (LP)
    /// @param _reward reward token (XPGN)
    /// @param _controller optional, can be zero
    /// @param initialOwner OZ v5 Ownable initial owner
    constructor(address _lp, address _reward, address _controller, address initialOwner)
        Ownable(initialOwner)
    {
        require(_lp != address(0) && _reward != address(0), "zero addr");
        stakingToken = IERC20(_lp);
        rewardToken  = IERC20(_reward);
        controller   = _controller; // optional; can be zero
    }

    // ---- views
    function lastTimeRewardApplicable() public view returns (uint256) {
        return block.timestamp < periodFinish ? block.timestamp : periodFinish;
    }

    function rewardPerToken() public view returns (uint256) {
        if (totalSupply == 0) return rewardPerTokenStored;
        return rewardPerTokenStored
            + ((lastTimeRewardApplicable() - lastUpdateTime) * rewardRate * 1e18) / totalSupply;
    }

    function earned(address account) public view returns (uint256) {
        return ((balanceOf[account] * (rewardPerToken() - userRewardPerTokenPaid[account])) / 1e18)
            + rewards[account];
    }

    // ---- modifiers
    modifier updateReward(address account) {
        rewardPerTokenStored = rewardPerToken();
        lastUpdateTime = lastTimeRewardApplicable();
        if (account != address(0)) {
            rewards[account] = earned(account);
            userRewardPerTokenPaid[account] = rewardPerTokenStored;
        }
        _;
    }

    // ---- stake/withdraw
    function stake(uint256 amount) external whenNotPaused nonReentrant updateReward(msg.sender) {
        require(amount > 0, "amount");
        totalSupply += amount;
        balanceOf[msg.sender] += amount;
        stakingToken.safeTransferFrom(msg.sender, address(this), amount);
        emit Staked(msg.sender, amount);
    }

    function withdraw(uint256 amount) external nonReentrant updateReward(msg.sender) {
        require(amount > 0, "amount");
        balanceOf[msg.sender] -= amount;
        totalSupply -= amount;
        stakingToken.safeTransfer(msg.sender, amount);
        emit Withdrawn(msg.sender, amount);
    }

    function getReward() external nonReentrant updateReward(msg.sender) {
        uint256 r = rewards[msg.sender];
        rewards[msg.sender] = 0;
        rewardToken.safeTransfer(msg.sender, r);
        emit RewardPaid(msg.sender, r);
    }

    // ---- notify (minter or owner)
    function setMinter(address m) external onlyOwner {
        // allow zero to disable minter-only, owner can still notify
        minter = m;
        emit SetMinter(m);
    }

    /// @notice Pull-model: gauge pulls `amount` from caller (minter/owner) via transferFrom
    ///         Caller must approve the gauge for `amount` first.
    function notifyRewardAmount(uint256 amount) external nonReentrant updateReward(address(0)) {
        require(msg.sender == minter || msg.sender == owner(), "not minter");
        if (block.timestamp >= periodFinish) {
            rewardRate = amount / DURATION;
        } else {
            uint256 remaining = periodFinish - block.timestamp;
            uint256 leftover = remaining * rewardRate;
            rewardRate = (amount + leftover) / DURATION;
        }
        lastUpdateTime = block.timestamp;
        periodFinish = block.timestamp + DURATION;

        // Pull funds from caller; EmissionsMinter should `forceApprove(gauge, amount)` beforehand
        rewardToken.safeTransferFrom(msg.sender, address(this), amount);

        emit Notified(amount, rewardRate, periodFinish);
    }

    // ---- admin
    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }
}
