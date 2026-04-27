// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.25;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract MockFarm {
    struct Pool {
        address lpToken;
        uint256 allocPoint;
        uint256 lastRewardBlock;
        uint256 accTokenPerShare;
    }

    mapping(uint256 => Pool) public poolInfo;
    mapping(uint256 => mapping(address => uint256)) public userStaked;

    function poolLpToken(uint256 pid) external view returns (address) {
        return poolInfo[pid].lpToken;
    }

    function addPool(uint256 pid, address lpToken, uint256 allocPoint) external {
        poolInfo[pid] = Pool({
            lpToken: lpToken,
            allocPoint: allocPoint,
            lastRewardBlock: block.number,
            accTokenPerShare: 0
        });
    }

    // vault deposits as msg.sender, and passes "user" as address(this)
    function depositFor(uint256 pid, uint256 amount, address user, address /*referrer*/) external {
        address lp = poolInfo[pid].lpToken;
        require(lp != address(0), "no pool");
        IERC20(lp).transferFrom(msg.sender, address(this), amount);
        userStaked[pid][user] += amount;
    }

    function withdraw(uint256 pid, uint256 amount) external {
        address lp = poolInfo[pid].lpToken;
        require(lp != address(0), "no pool");
        uint256 staked = userStaked[pid][msg.sender];
        require(staked >= amount, "insufficient");
        unchecked { userStaked[pid][msg.sender] = staked - amount; }
        IERC20(lp).transfer(msg.sender, amount);
    }

    function harvest(uint256 /*pid*/) external {
        // no-op for these tests
    }

    function pendingReward(uint256 /*pid*/, address /*user*/) external pure returns (uint256) {
        return 0;
    }
}
