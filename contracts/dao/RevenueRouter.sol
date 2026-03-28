// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract RevenueRouter is Ownable, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint16 public constant BPS_DENOM = 10_000;

    address public feeDistributorSink;
    address public treasurySink;
    address public traderRewardsSink;

    uint16 public feeDistributorBps;
    uint16 public treasuryBps;
    uint16 public traderRewardsBps;

    event SinksUpdated(
        address indexed feeDistributorSink,
        address indexed treasurySink,
        address indexed traderRewardsSink
    );
    event SplitUpdated(uint16 feeDistributorBps, uint16 treasuryBps, uint16 traderRewardsBps);
    event Distributed(address indexed token, uint256 amount, uint256 toFeeDistributor, uint256 toTreasury, uint256 toTraderRewards);
    event Swept(address indexed token, address indexed to, uint256 amount);

    constructor(
        address initialOwner,
        address _feeDistributorSink,
        address _treasurySink,
        address _traderRewardsSink,
        uint16 _feeDistributorBps,
        uint16 _treasuryBps,
        uint16 _traderRewardsBps
    ) Ownable(initialOwner) {
        _setSinks(_feeDistributorSink, _treasurySink, _traderRewardsSink);
        _setSplit(_feeDistributorBps, _treasuryBps, _traderRewardsBps);
    }

    function _setSinks(address a, address b, address c) internal {
        require(a != address(0), "feeSink=0");
        require(b != address(0), "treasury=0");
        require(c != address(0), "traderSink=0");
        feeDistributorSink = a;
        treasurySink = b;
        traderRewardsSink = c;
        emit SinksUpdated(a, b, c);
    }

    function _setSplit(uint16 a, uint16 b, uint16 c) internal {
        require(uint256(a) + uint256(b) + uint256(c) == BPS_DENOM, "bad split");
        feeDistributorBps = a;
        treasuryBps = b;
        traderRewardsBps = c;
        emit SplitUpdated(a, b, c);
    }

    function setSinks(address a, address b, address c) external onlyOwner {
        _setSinks(a, b, c);
    }

    function setSplit(uint16 a, uint16 b, uint16 c) external onlyOwner {
        _setSplit(a, b, c);
    }

    function distribute(address token) external onlyOwner nonReentrant whenNotPaused {
        require(token != address(0), "token=0");

        uint256 bal = IERC20(token).balanceOf(address(this));
        require(bal > 0, "no balance");

        uint256 toFee = (bal * feeDistributorBps) / BPS_DENOM;
        uint256 toTreasury = (bal * treasuryBps) / BPS_DENOM;
        uint256 toTrader = bal - toFee - toTreasury;

        if (toFee > 0) IERC20(token).safeTransfer(feeDistributorSink, toFee);
        if (toTreasury > 0) IERC20(token).safeTransfer(treasurySink, toTreasury);
        if (toTrader > 0) IERC20(token).safeTransfer(traderRewardsSink, toTrader);

        emit Distributed(token, bal, toFee, toTreasury, toTrader);
    }

    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }

    function sweep(address token, address to) external onlyOwner {
        require(to != address(0), "to=0");
        uint256 bal = IERC20(token).balanceOf(address(this));
        if (bal > 0) IERC20(token).safeTransfer(to, bal);
        emit Swept(token, to, bal);
    }
}