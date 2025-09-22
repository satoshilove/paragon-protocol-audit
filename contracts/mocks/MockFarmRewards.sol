// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract MockFarmRewards {
    using SafeERC20 for IERC20;

    struct Pool { IERC20 lp; }
    IERC20 public immutable rewardToken; // XPGN
    mapping(uint256 => Pool) public poolInfo;
    mapping(uint256 => mapping(address => uint256)) public userStaked;
    mapping(uint256 => mapping(address => uint256)) public pending; // manual oracle for tests

    constructor(address _reward) { rewardToken = IERC20(_reward); }

    function addPool(uint256 pid, address lpToken) external {
        poolInfo[pid] = Pool({ lp: IERC20(lpToken) });
    }

    function poolLpToken(uint256 pid) external view returns (address) {
        return address(poolInfo[pid].lp);
    }

    function setPending(uint256 pid, address user, uint256 amount) external {
        pending[pid][user] = amount;
    }

    function pendingReward(uint256 pid, address user) external view returns (uint256) {
        return pending[pid][user];
    }

    function depositFor(uint256 pid, uint256 amount, address user, address /*referrer*/) external {
        IERC20 lp = poolInfo[pid].lp;
        require(address(lp) != address(0), "no pool");
        lp.safeTransferFrom(msg.sender, address(this), amount);
        userStaked[pid][user] += amount;
    }

    function withdraw(uint256 pid, uint256 amount) external {
        IERC20 lp = poolInfo[pid].lp;
        require(address(lp) != address(0), "no pool");
        require(userStaked[pid][msg.sender] >= amount, "insufficient");
        userStaked[pid][msg.sender] -= amount;
        lp.safeTransfer(msg.sender, amount);
    }

    function harvest(uint256 pid) external {
        uint256 amt = pending[pid][msg.sender];
        if (amt > 0) {
            pending[pid][msg.sender] = 0;
            rewardToken.safeTransfer(msg.sender, amt);
        }
    }
}
