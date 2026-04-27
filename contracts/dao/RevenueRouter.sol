// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.25;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

interface IFeeDistributorNotify {
    function notifyRewardAmount(uint256 amount) external;
    function reward() external view returns (IERC20);
}

interface ITraderRewardsNotify {
    function notifyRewardAmount(uint256 epoch, uint256 amount) external;
    function XPGN() external view returns (IERC20);
}

contract RevenueRouter is Ownable, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint16 public constant BPS_DENOM = 10_000;

    enum SinkMode {
        TRANSFER,
        FEE_DISTRIBUTOR_NOTIFY,
        TRADER_REWARDS_NOTIFY
    }

    address public feeDistributorSink;
    address public treasurySink;
    address public traderRewardsSink;

    SinkMode public feeDistributorMode;
    SinkMode public traderRewardsMode;

    uint16 public feeDistributorBps;
    uint16 public treasuryBps;
    uint16 public traderRewardsBps;

    event SinksUpdated(
        address indexed feeDistributorSink,
        address indexed treasurySink,
        address indexed traderRewardsSink
    );
    event SinkModesUpdated(SinkMode feeDistributorMode, SinkMode traderRewardsMode);
    event SplitUpdated(uint16 feeDistributorBps, uint16 treasuryBps, uint16 traderRewardsBps);
    event Distributed(
        address indexed token,
        uint256 totalAmount,
        uint256 toFeeDistributor,
        uint256 toTreasury,
        uint256 toTraderRewards
    );
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

        feeDistributorMode = SinkMode.FEE_DISTRIBUTOR_NOTIFY;
        traderRewardsMode = SinkMode.TRADER_REWARDS_NOTIFY;

        emit SinkModesUpdated(feeDistributorMode, traderRewardsMode);
    }

    function _setSinks(address feeSink, address treasury, address traderSink) internal {
        require(feeSink != address(0), "feeSink=0");
        require(treasury != address(0), "treasury=0");
        require(traderSink != address(0), "traderSink=0");

        feeDistributorSink = feeSink;
        treasurySink = treasury;
        traderRewardsSink = traderSink;

        emit SinksUpdated(feeSink, treasury, traderSink);
    }

    function _setSplit(uint16 feeBps, uint16 treasuryBps_, uint16 traderBps) internal {
        require(uint256(feeBps) + uint256(treasuryBps_) + uint256(traderBps) == BPS_DENOM, "bad split");

        feeDistributorBps = feeBps;
        treasuryBps = treasuryBps_;
        traderRewardsBps = traderBps;

        emit SplitUpdated(feeBps, treasuryBps_, traderBps);
    }

    function setSinks(address feeSink, address treasury, address traderSink) external onlyOwner {
        _setSinks(feeSink, treasury, traderSink);
    }

    function setSinkModes(SinkMode feeMode, SinkMode traderMode) external onlyOwner {
        require(
            feeMode == SinkMode.TRANSFER || feeMode == SinkMode.FEE_DISTRIBUTOR_NOTIFY,
            "bad fee mode"
        );
        require(
            traderMode == SinkMode.TRANSFER || traderMode == SinkMode.TRADER_REWARDS_NOTIFY,
            "bad trader mode"
        );

        feeDistributorMode = feeMode;
        traderRewardsMode = traderMode;

        emit SinkModesUpdated(feeMode, traderMode);
    }

    function setSplit(uint16 feeBps, uint16 treasuryBps_, uint16 traderBps) external onlyOwner {
        _setSplit(feeBps, treasuryBps_, traderBps);
    }

    function distribute(address token) external onlyOwner whenNotPaused nonReentrant {
        _distribute(token, 0, false);
    }

    function distribute(address token, uint256 traderEpoch) external onlyOwner whenNotPaused nonReentrant {
        _distribute(token, traderEpoch, true);
    }

    function _distribute(address token, uint256 traderEpoch, bool hasTraderEpoch) internal {
        require(token != address(0), "token=0");

        IERC20 rewardToken = IERC20(token);
        uint256 totalAmount = rewardToken.balanceOf(address(this));
        require(totalAmount > 0, "no balance");

        uint256 toFeeDistributor = (totalAmount * feeDistributorBps) / BPS_DENOM;
        uint256 toTreasury = (totalAmount * treasuryBps) / BPS_DENOM;
        uint256 toTraderRewards = totalAmount - toFeeDistributor - toTreasury;

        if (toFeeDistributor > 0) {
            if (feeDistributorMode == SinkMode.TRANSFER) {
                rewardToken.safeTransfer(feeDistributorSink, toFeeDistributor);
            } else {
                require(
                    address(IFeeDistributorNotify(feeDistributorSink).reward()) == token,
                    "fee sink token mismatch"
                );
                rewardToken.forceApprove(feeDistributorSink, 0);
                rewardToken.forceApprove(feeDistributorSink, toFeeDistributor);
                IFeeDistributorNotify(feeDistributorSink).notifyRewardAmount(toFeeDistributor);
                rewardToken.forceApprove(feeDistributorSink, 0);
            }
        }

        if (toTreasury > 0) {
            rewardToken.safeTransfer(treasurySink, toTreasury);
        }

        if (toTraderRewards > 0) {
            if (traderRewardsMode == SinkMode.TRANSFER) {
                rewardToken.safeTransfer(traderRewardsSink, toTraderRewards);
            } else {
                require(hasTraderEpoch, "trader epoch required");
                require(
                    address(ITraderRewardsNotify(traderRewardsSink).XPGN()) == token,
                    "trader sink token mismatch"
                );
                rewardToken.forceApprove(traderRewardsSink, 0);
                rewardToken.forceApprove(traderRewardsSink, toTraderRewards);
                ITraderRewardsNotify(traderRewardsSink).notifyRewardAmount(traderEpoch, toTraderRewards);
                rewardToken.forceApprove(traderRewardsSink, 0);
            }
        }

        emit Distributed(token, totalAmount, toFeeDistributor, toTreasury, toTraderRewards);
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    function sweep(address token, address to) external onlyOwner nonReentrant {
        require(to != address(0), "to=0");

        uint256 bal = IERC20(token).balanceOf(address(this));
        if (bal > 0) {
            IERC20(token).safeTransfer(to, bal);
        }

        emit Swept(token, to, bal);
    }
}
