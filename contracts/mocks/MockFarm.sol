// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract MockFarm {
    struct Pool {
        address lpToken;
        uint256 allocPoint;
        uint256 lastRewardBlock;
        uint256 accTokenPerShare;
    }

    // pid => pool
    mapping(uint256 => Pool) public poolInfo;
    // convenience view used by zap
    function poolLpToken(uint256 pid) external view returns (address) {
        return poolInfo[pid].lpToken;
    }

    // pid => user => staked
    mapping(uint256 => mapping(address => uint256)) public userStaked;

    function addPool(uint256 pid, address lpToken, uint256 allocPoint) external {
        poolInfo[pid] = Pool({
            lpToken: lpToken,
            allocPoint: allocPoint,
            lastRewardBlock: block.number,
            accTokenPerShare: 0
        });
    }

    // matches ParagonZapV2’s interface
    function depositFor(uint256 pid, uint256 amount, address user, address /*referrer*/) external {
        address lp = poolInfo[pid].lpToken;
        require(lp != address(0), "no pool");
        IERC20(lp).transferFrom(msg.sender, address(this), amount);
        userStaked[pid][user] += amount;
    }
}
