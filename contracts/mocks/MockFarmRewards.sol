// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.25;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title MockFarmRewards
 * @notice Minimal "farm-like" contract for unit tests:
 *  - Exposes rewardToken() (address) for RewardDripperEscrow farm token match check.
 *  - Supports depositFor/withdraw/harvest.
 *  - pending is manually set by tests (oracle-style).
 */
contract MockFarmRewards {
    using SafeERC20 for IERC20;

    struct Pool {
        IERC20 lp;
    }

    IERC20 public immutable REWARD_TOKEN; // XPGN (immutable)

    mapping(uint256 => Pool) public poolInfo; // pid => pool
    mapping(uint256 => mapping(address => uint256)) public userStaked; // pid => user => staked
    mapping(uint256 => mapping(address => uint256)) public pending;    // pid => user => pending reward (set by tests)

    event PoolAdded(uint256 indexed pid, address indexed lpToken);
    event PendingSet(uint256 indexed pid, address indexed user, uint256 amount);
    event Deposited(uint256 indexed pid, address indexed payer, address indexed user, uint256 amount);
    event Withdrawn(uint256 indexed pid, address indexed user, uint256 amount);
    event Harvested(uint256 indexed pid, address indexed user, uint256 amount);
    event RewardsFunded(address indexed from, uint256 amount);

    constructor(address _reward) {
        require(_reward != address(0), "zero reward");
        REWARD_TOKEN = IERC20(_reward);
    }

    // ----------------------------------------------------------------
    // Escrow compatibility: MUST match IFarmRewardToken { rewardToken() returns (address) }
    // ----------------------------------------------------------------

    function rewardToken() external view returns (address) {
        return address(REWARD_TOKEN);
    }

    // ----------------------------------------------------------------
    // Pool helpers
    // ----------------------------------------------------------------

    function addPool(uint256 pid, address lpToken) external {
        require(lpToken != address(0), "zero lp");
        poolInfo[pid] = Pool({lp: IERC20(lpToken)});
        emit PoolAdded(pid, lpToken);
    }

    function poolLpToken(uint256 pid) external view returns (address) {
        return address(poolInfo[pid].lp);
    }

    function stakedOf(uint256 pid, address user) external view returns (uint256) {
        return userStaked[pid][user];
    }

    // ----------------------------------------------------------------
    // Pending rewards control (test oracle)
    // ----------------------------------------------------------------

    function setPending(uint256 pid, address user, uint256 amount) external {
        pending[pid][user] = amount;
        emit PendingSet(pid, user, amount);
    }

    function pendingReward(uint256 pid, address user) external view returns (uint256) {
        return pending[pid][user];
    }

    // ----------------------------------------------------------------
    // Core actions
    // ----------------------------------------------------------------

    function depositFor(uint256 pid, uint256 amount, address user, address /*referrer*/) external {
        IERC20 lp = poolInfo[pid].lp;
        require(address(lp) != address(0), "no pool");
        require(user != address(0), "zero user");
        if (amount == 0) return;

        lp.safeTransferFrom(msg.sender, address(this), amount);
        userStaked[pid][user] += amount;

        emit Deposited(pid, msg.sender, user, amount);
    }

    function withdraw(uint256 pid, uint256 amount) external {
        IERC20 lp = poolInfo[pid].lp;
        require(address(lp) != address(0), "no pool");
        require(userStaked[pid][msg.sender] >= amount, "insufficient");
        if (amount == 0) return;

        userStaked[pid][msg.sender] -= amount;
        lp.safeTransfer(msg.sender, amount);

        emit Withdrawn(pid, msg.sender, amount);
    }

    /// @notice Convenience for tests
    function emergencyWithdraw(uint256 pid) external {
        uint256 amt = userStaked[pid][msg.sender];
        if (amt == 0) return;

        IERC20 lp = poolInfo[pid].lp;
        require(address(lp) != address(0), "no pool");

        userStaked[pid][msg.sender] = 0;
        lp.safeTransfer(msg.sender, amt);

        emit Withdrawn(pid, msg.sender, amt);
    }

    function harvest(uint256 pid) external {
        uint256 amt = pending[pid][msg.sender];
        if (amt == 0) {
            emit Harvested(pid, msg.sender, 0);
            return;
        }

        pending[pid][msg.sender] = 0;

        // IMPORTANT: tests must fund this contract with rewards before harvesting,
        // otherwise SafeERC20 will revert due to insufficient balance.
        REWARD_TOKEN.safeTransfer(msg.sender, amt);

        emit Harvested(pid, msg.sender, amt);
    }

    // ----------------------------------------------------------------
    // Test helper: fund the farm with reward tokens so harvest can pay
    // ----------------------------------------------------------------

    function fundRewards(uint256 amount) external {
        if (amount == 0) return;
        REWARD_TOKEN.safeTransferFrom(msg.sender, address(this), amount);
        emit RewardsFunded(msg.sender, amount);
    }
}
