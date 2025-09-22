// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

interface IERC20 {
    function transfer(address to, uint256 value) external returns (bool);
    function balanceOf(address a) external view returns (uint256);
}

contract MockRewardDripper {
    IERC20 public token;
    address public farm;
    uint256 public accrued; // pretend "pendingAccrued()"

    event Seeded(uint256 amount);
    event Dripped(uint256 sent);

    constructor(IERC20 _token, address _farm) {
        token = _token;
        farm = _farm;
    }

    function setAccrued(uint256 a) external { accrued = a; }

    function pendingAccrued() external view returns (uint256) {
        return accrued;
    }

    function drip() external returns (uint256 sent) {
        uint256 bal = token.balanceOf(address(this));
        sent = bal < accrued ? bal : accrued;
        if (sent > 0) {
            token.transfer(farm, sent);
            accrued = 0;
            emit Dripped(sent);
        }
    }
}
