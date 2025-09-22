// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IMintable} from "./interfaces/IMintable.sol";

interface IGaugeControllerLite {
    function n_gauges() external view returns (uint256);
    function gaugesAt(uint256 i) external view returns (address);
    function totalWeight() external view returns (uint256);
    function gaugeWeight(address gauge) external view returns (uint256);
}

interface ISimpleGauge {
    function notifyRewardAmount(uint256 amount) external;
    function rewardToken() external view returns (address);
}

contract EmissionsMinter is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 public constant WEEK = 7 days;

    IERC20 public immutable token;              // XPGN
    IGaugeControllerLite public controller;

    address public treasury;                    // optional funding source (pull mode)
    bool    public useMinting = true;           // true => mint; false => transferFrom(treasury)

    uint256 public weeklyEmission;              // amount per week
    uint256 public lastPushedWeek;              // week timestamp of last push

    event SetWeeklyEmission(uint256 amount);
    event Pushed(uint256 weekTs, uint256 total, uint256 gauges);
    event SetFundingMode(bool useMint, address treasury);
    event ControllerSet(address controller);

    constructor(address _token, address _controller, address initialOwner) Ownable(initialOwner) {
        require(_token != address(0) && _controller != address(0), "Minter: zero");
        token = IERC20(_token);
        controller = IGaugeControllerLite(_controller);
    }

    function setWeeklyEmission(uint256 amount) external onlyOwner {
        weeklyEmission = amount;
        emit SetWeeklyEmission(amount);
    }

    function setFundingMode(bool _useMinting, address _treasury) external onlyOwner {
        useMinting = _useMinting;
        treasury = _treasury;
        emit SetFundingMode(_useMinting, _treasury);
    }

    function setController(address c) external onlyOwner {
        require(c != address(0), "Minter: zero");
        controller = IGaugeControllerLite(c);
        emit ControllerSet(c);
    }

    /// @notice Push this week's emission to all gauges, pro-rata by gauge weight.
    function kick() external nonReentrant {
        require(weeklyEmission > 0, "emission=0");

        uint256 weekTs = _roundDownWeek(block.timestamp);
        require(weekTs > lastPushedWeek, "already pushed");

        uint256 n = controller.n_gauges();
        require(n > 0, "no gauges");

        uint256 tw = controller.totalWeight();
        require(tw > 0, "no weight");

        // Effects first (reentrancy safety): mark week as pushed
        lastPushedWeek = weekTs;

        // Fund this minter
        if (useMinting) {
            IMintable(address(token)).mint(address(this), weeklyEmission);
        } else {
            require(treasury != address(0), "treasury=0");
            token.safeTransferFrom(treasury, address(this), weeklyEmission);
        }

        // Distribute by weights (integer division leaves harmless dust in the minter)
        for (uint256 i = 0; i < n; i++) {
            address g = controller.gaugesAt(i);
            uint256 gw = controller.gaugeWeight(g);
            if (gw == 0) continue;

            uint256 amt = (weeklyEmission * gw) / tw;
            if (amt == 0) continue;

            // Approve gauge to pull just this amount; forceApprove handles non-standard ERC-20s
            token.forceApprove(g, amt);

            // External call: gauge pulls `amt` via transferFrom (per SimpleGauge pattern)
            ISimpleGauge(g).notifyRewardAmount(amt);
        }

        emit Pushed(weekTs, weeklyEmission, n);
    }

    function _roundDownWeek(uint256 t) internal pure returns (uint256) {
        return (t / WEEK) * WEEK;
    }
}
