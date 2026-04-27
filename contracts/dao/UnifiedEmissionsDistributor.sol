// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.25;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IMintable} from "./interfaces/IMintable.sol";

interface IGaugeControllerFinal {
    function n_gauges() external view returns (uint256);
    function gaugesAt(uint256 i) external view returns (address);
    function totalWeightFinal(uint256 ep) external view returns (uint256);
    function gaugeWeightFinal(uint256 ep, address gauge) external view returns (uint256);
    function epoch() external view returns (uint256);
    function epochFinalized(uint256 ep) external view returns (bool);
}

interface ISimpleGauge {
    function notifyRewardAmount(uint256 amount) external;
}

interface IFarmGaugeNotify {
    function notifyGaugeReward(uint256 pid, uint256 amount) external;
}

contract UnifiedEmissionsDistributor is Ownable, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 public constant WEEK = 7 days;

    IERC20 public immutable token;
    IGaugeControllerFinal public controller;
    address public farm;

    bool public useMinting = true;
    address public treasury;

    uint256 public weeklyEmission;
    uint256 public lastPushedWeek;

    mapping(address => bool) public isSimpleGauge;
    mapping(address => bool) public isFarmGauge;
    mapping(address => uint256) public gaugeToPid;

    event WeeklyEmissionUpdated(uint256 amount);
    event FundingModeUpdated(bool useMinting, address treasury);
    event FarmUpdated(address indexed farm);
    event ControllerUpdated(address indexed controller);
    event GaugeMapped(address indexed gauge, uint256 pid, bool isSimple);
    event EmissionsPushed(
        uint256 indexed weekTs,
        uint256 indexed sourceEpoch,
        uint256 totalAllocated,
        uint256 gaugesUsed,
        uint256 dustRemainder
    );
    event EmergencyWithdraw(address indexed tokenAddr, address indexed to, uint256 amount);

    constructor(address _token, address _controller, address _farm, address initialOwner)
        Ownable(initialOwner)
    {
        require(_token != address(0) && _controller != address(0) && _farm != address(0), "zero address");
        token = IERC20(_token);
        controller = IGaugeControllerFinal(_controller);
        farm = _farm;
    }

    function setWeeklyEmission(uint256 amount) external onlyOwner {
        weeklyEmission = amount;
        emit WeeklyEmissionUpdated(amount);
    }

    function setFundingMode(bool _useMinting, address _treasury) external onlyOwner {
        if (!_useMinting) require(_treasury != address(0), "treasury=0");
        useMinting = _useMinting;
        treasury = _treasury;
        emit FundingModeUpdated(_useMinting, _treasury);
    }

    function setFarm(address _farm) external onlyOwner {
        require(_farm != address(0), "farm=0");
        farm = _farm;
        emit FarmUpdated(_farm);
    }

    function setController(address _controller) external onlyOwner {
        require(_controller != address(0), "controller=0");
        controller = IGaugeControllerFinal(_controller);
        emit ControllerUpdated(_controller);
    }

    function mapGauge(address gauge, uint256 pid, bool simple) external onlyOwner {
        if (simple) {
            isSimpleGauge[gauge] = true;
            isFarmGauge[gauge] = false;
            gaugeToPid[gauge] = 0;
        } else {
            require(farm != address(0), "farm=0");
            isSimpleGauge[gauge] = false;
            isFarmGauge[gauge] = true;
            gaugeToPid[gauge] = pid;
        }

        emit GaugeMapped(gauge, pid, simple);
    }

    function kick() external whenNotPaused nonReentrant {
        require(weeklyEmission > 0, "weekly emission not set");

        uint256 weekTs = _roundDownWeek(block.timestamp);
        require(weekTs > lastPushedWeek, "already pushed this week");

        uint256 currentEp = controller.epoch();
        require(currentEp > 0, "no closed epoch yet");

        uint256 sourceEp = currentEp - 1;
        require(controller.epochFinalized(sourceEp), "previous epoch not finalized");

        uint256 tw = controller.totalWeightFinal(sourceEp);
        require(tw > 0, "no total weight");

        uint256 n = controller.n_gauges();
        require(n > 0, "no gauges known");

        address[] memory targets = new address[](n);
        uint256[] memory amts = new uint256[](n);

        uint256 realCount;
        uint256 allocated;
        uint256 farmTotal;

        for (uint256 i = 0; i < n; ++i) {
            address g = controller.gaugesAt(i);
            uint256 gw = controller.gaugeWeightFinal(sourceEp, g);
            if (gw == 0) continue;

            bool simple = isSimpleGauge[g];
            bool farmGauge = isFarmGauge[g];
            require(simple || farmGauge, "unmapped weighted gauge");

            uint256 amt = (weeklyEmission * gw) / tw;
            if (amt == 0) continue;

            targets[realCount] = g;
            amts[realCount] = amt;
            allocated += amt;

            if (farmGauge) {
                farmTotal += amt;
            }

            realCount++;
        }

        require(realCount > 0, "nothing to allocate");
        require(allocated > 0, "allocated=0");

        lastPushedWeek = weekTs;

        if (useMinting) {
            IMintable(address(token)).mint(address(this), allocated);
        } else {
            uint256 balBefore = token.balanceOf(address(this));
            token.safeTransferFrom(treasury, address(this), allocated);
            uint256 received = token.balanceOf(address(this)) - balBefore;
            require(received == allocated, "bad treasury funding");
        }

        if (farmTotal > 0) {
            require(farm != address(0), "farm=0");
            token.forceApprove(farm, 0);
            token.forceApprove(farm, farmTotal);
        }

        for (uint256 i = 0; i < realCount; ++i) {
            address g = targets[i];
            uint256 amt = amts[i];

            if (isSimpleGauge[g]) {
                token.forceApprove(g, 0);
                token.forceApprove(g, amt);
                ISimpleGauge(g).notifyRewardAmount(amt);
                token.forceApprove(g, 0);
            } else {
                IFarmGaugeNotify(farm).notifyGaugeReward(gaugeToPid[g], amt);
            }
        }

        if (farmTotal > 0) {
            token.forceApprove(farm, 0);
        }

        emit EmissionsPushed(
            weekTs,
            sourceEp,
            allocated,
            realCount,
            weeklyEmission - allocated
        );
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    function emergencyWithdraw(address tokenAddr, address to, uint256 amount) external onlyOwner {
        require(to != address(0), "recipient=0");
        IERC20(tokenAddr).safeTransfer(to, amount);
        emit EmergencyWithdraw(tokenAddr, to, amount);
    }

    function _roundDownWeek(uint256 t) internal pure returns (uint256) {
        return (t / WEEK) * WEEK;
    }
}
