// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

contract SimpleGauge is Ownable, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    IERC20 public immutable stakingToken;
    IERC20 public immutable rewardToken;

    address public controller;
    address public minter;

    uint256 public constant DURATION = 7 days;

    uint256 public periodFinish;
    uint256 public rewardRate;
    uint256 public lastUpdateTime;
    uint256 public rewardPerTokenStored;

    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;

    mapping(address => uint256) public userRewardPerTokenPaid;
    mapping(address => uint256) public rewards;

    event Notified(uint256 amount, uint256 newRate, uint256 periodFinish);
    event Staked(address indexed user, uint256 amount);
    event Withdrawn(address indexed user, uint256 amount);
    event RewardPaid(address indexed user, uint256 amount);
    event SetMinter(address indexed minter);

    constructor(
        address _lp,
        address _reward,
        address _controller,
        address initialOwner
    ) Ownable(initialOwner) {
        require(_lp != address(0) && _reward != address(0), "zero addr");
        stakingToken = IERC20(_lp);
        rewardToken = IERC20(_reward);
        controller = _controller;
    }

    modifier updateReward(address account) {
        rewardPerTokenStored = rewardPerToken();
        lastUpdateTime = lastTimeRewardApplicable();

        if (account != address(0)) {
            rewards[account] = earned(account);
            userRewardPerTokenPaid[account] = rewardPerTokenStored;
        }
        _;
    }

    function lastTimeRewardApplicable() public view returns (uint256) {
        return block.timestamp < periodFinish ? block.timestamp : periodFinish;
    }

    function rewardPerToken() public view returns (uint256) {
        if (totalSupply == 0) return rewardPerTokenStored;

        return rewardPerTokenStored
            + ((lastTimeRewardApplicable() - lastUpdateTime) * rewardRate * 1e18) / totalSupply;
    }

    function earned(address account) public view returns (uint256) {
        return
            ((balanceOf[account] * (rewardPerToken() - userRewardPerTokenPaid[account])) / 1e18)
            + rewards[account];
    }

    function stake(uint256 amount) external whenNotPaused nonReentrant updateReward(msg.sender) {
        require(amount > 0, "amount=0");

        totalSupply += amount;
        balanceOf[msg.sender] += amount;

        stakingToken.safeTransferFrom(msg.sender, address(this), amount);
        emit Staked(msg.sender, amount);
    }

    function withdraw(uint256 amount) public nonReentrant updateReward(msg.sender) {
        require(amount > 0, "amount=0");
        require(balanceOf[msg.sender] >= amount, "insufficient");

        balanceOf[msg.sender] -= amount;
        totalSupply -= amount;

        stakingToken.safeTransfer(msg.sender, amount);
        emit Withdrawn(msg.sender, amount);
    }

    function getReward() public nonReentrant updateReward(msg.sender) {
        uint256 r = rewards[msg.sender];
        rewards[msg.sender] = 0;

        if (r > 0) {
            rewardToken.safeTransfer(msg.sender, r);
            emit RewardPaid(msg.sender, r);
        }
    }

    function exit() external {
        uint256 bal = balanceOf[msg.sender];
        if (bal > 0) {
            withdraw(bal);
        }
        getReward();
    }

    function setMinter(address m) external onlyOwner {
        minter = m;
        emit SetMinter(m);
    }

    function notifyRewardAmount(uint256 amount)
        external
        nonReentrant
        updateReward(address(0))
    {
        require(msg.sender == minter || msg.sender == owner(), "not minter");
        require(amount > 0, "amount=0");

        rewardToken.safeTransferFrom(msg.sender, address(this), amount);

        if (block.timestamp >= periodFinish) {
            rewardRate = amount / DURATION;
        } else {
            uint256 remaining = periodFinish - block.timestamp;
            uint256 leftover = remaining * rewardRate;
            rewardRate = (amount + leftover) / DURATION;
        }

        require(rewardRate > 0, "rate=0");
        require(rewardRate <= rewardToken.balanceOf(address(this)) / DURATION, "reward too high");

        lastUpdateTime = block.timestamp;
        periodFinish = block.timestamp + DURATION;

        emit Notified(amount, rewardRate, periodFinish);
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }
}