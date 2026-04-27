// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {IP10VenueAdapter} from "./interfaces/IP10VenueAdapter.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

interface IP10OneInchAdapter {
    struct SwapDescription {
        IERC20 srcToken;
        IERC20 dstToken;
        address payable srcReceiver;
        address payable dstReceiver;
        uint256 amount;
        uint256 minReturnAmount;
        uint256 flags;
    }

    function execute(
        address tokenIn,
        uint256 amountIn,
        address tokenOut,
        uint256 minAmountOut,
        SwapDescription calldata desc,
        bytes calldata permitData,
        bytes calldata oneInchData,
        address executor,
        address receiver
    ) external returns (uint256 actualOut);
}

contract P10Venue1Inch is IP10VenueAdapter, Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    error NotExecutionManager();
    error ZeroAddress();
    error InvalidLeg();
    error InputAmountMismatch();
    error UnsupportedVenueData();
    error WrongReceiver();
    error ZeroMinOutput();
    error EmptyLegs();
    error InsufficientVenueBalance();
    error SameTokenMinOutTooHigh();
    error VenueBalanceDeltaMismatch();

    struct LegSwapData {
        address executor;
        bytes oneInchData;
        uint256 amountIn;
        uint256 minOut;
    }

    struct BuyVenueData {
        LegSwapData[] swaps;
    }

    struct SellVenueData {
        LegSwapData[] swaps;
    }

    IP10OneInchAdapter public immutable adapter;
    address public executionManager;

    event ExecutionManagerUpdated(address indexed oldExec, address indexed newExec);

    constructor(
        address initialOwner,
        address _adapter,
        address _executionManager
    ) Ownable(initialOwner) {
        if (_adapter == address(0) || _executionManager == address(0)) revert ZeroAddress();
        adapter = IP10OneInchAdapter(_adapter);
        executionManager = _executionManager;
        emit ExecutionManagerUpdated(address(0), _executionManager);
    }

    modifier onlyExecutionManager() {
        if (msg.sender != executionManager) revert NotExecutionManager();
        _;
    }

    function setExecutionManager(address _executionManager) external onlyOwner {
        if (_executionManager == address(0)) revert ZeroAddress();
        emit ExecutionManagerUpdated(executionManager, _executionManager);
        executionManager = _executionManager;
    }

    function buyBasketSingleToken(
        address inputToken,
        uint256 inputAmount,
        BasketLeg[] calldata legs,
        address receiver,
        bytes calldata venueData
    ) external override onlyExecutionManager nonReentrant returns (uint256[] memory actualAcquired) {
        if (receiver == address(0)) revert WrongReceiver();
        if (inputToken == address(0) || inputAmount == 0) revert InvalidLeg();
        if (legs.length == 0) revert EmptyLegs();

        BuyVenueData memory vd = abi.decode(venueData, (BuyVenueData));
        if (vd.swaps.length != legs.length) revert UnsupportedVenueData();

        uint256 beforeInputBal = IERC20(inputToken).balanceOf(address(this));

        actualAcquired = new uint256[](legs.length);
        uint256 totalInputUsed = 0;

        for (uint256 i = 0; i < legs.length; i++) {
            if (legs[i].targetAmount == 0) {
                if (vd.swaps[i].amountIn != 0) revert InputAmountMismatch();
                if (vd.swaps[i].minOut != 0) revert InputAmountMismatch();
                continue;
            }

            if (legs[i].token == address(0)) revert InvalidLeg();

            uint256 legAmountIn = vd.swaps[i].amountIn;
            if (legAmountIn == 0) revert InvalidLeg();

            totalInputUsed += legAmountIn;

            if (IERC20(inputToken).balanceOf(address(this)) < legAmountIn) {
                revert InsufficientVenueBalance();
            }

            // Same-token leg: no 1inch swap, transfer directly to receiver (vault).
            if (legs[i].token == inputToken) {
                if (legAmountIn != legs[i].targetAmount) revert InputAmountMismatch();
                if (vd.swaps[i].minOut > legAmountIn) revert SameTokenMinOutTooHigh();

                IERC20(inputToken).safeTransfer(receiver, legAmountIn);
                actualAcquired[i] = legAmountIn;
                continue;
            }

            if (vd.swaps[i].minOut == 0) revert ZeroMinOutput();

            IERC20(inputToken).safeTransfer(address(adapter), legAmountIn);

            IP10OneInchAdapter.SwapDescription memory desc = IP10OneInchAdapter.SwapDescription({
                srcToken: IERC20(inputToken),
                dstToken: IERC20(legs[i].token),
                srcReceiver: payable(address(adapter)),
                dstReceiver: payable(address(adapter)),
                amount: legAmountIn,
                minReturnAmount: vd.swaps[i].minOut,
                flags: 0
            });

            actualAcquired[i] = adapter.execute(
                inputToken,
                legAmountIn,
                legs[i].token,
                vd.swaps[i].minOut,
                desc,
                "",
                vd.swaps[i].oneInchData,
                vd.swaps[i].executor,
                receiver
            );
        }

        if (totalInputUsed != inputAmount) revert InputAmountMismatch();

        uint256 afterInputBal = IERC20(inputToken).balanceOf(address(this));
        if (afterInputBal != beforeInputBal - totalInputUsed) {
            revert VenueBalanceDeltaMismatch();
        }
    }

    function sellBasketToSingleToken(
        BasketLeg[] calldata legs,
        address outputToken,
        uint256 minOutput,
        address recipient,
        bytes calldata venueData
    ) external override onlyExecutionManager nonReentrant returns (uint256 actualOutput) {
        if (recipient == address(0)) revert WrongReceiver();
        if (outputToken == address(0)) revert ZeroAddress();
        if (minOutput == 0) revert ZeroMinOutput();
        if (legs.length == 0) revert EmptyLegs();

        SellVenueData memory vd = abi.decode(venueData, (SellVenueData));
        if (vd.swaps.length != legs.length) revert UnsupportedVenueData();

        uint256[] memory beforeLegBalances = new uint256[](legs.length);
        for (uint256 i = 0; i < legs.length; i++) {
            if (legs[i].targetAmount == 0) {
                beforeLegBalances[i] = 0;
                continue;
            }

            if (legs[i].token == address(0)) revert InvalidLeg();
            beforeLegBalances[i] = IERC20(legs[i].token).balanceOf(address(this));
        }

        uint256 totalOut = 0;

        for (uint256 i = 0; i < legs.length; i++) {
            if (legs[i].targetAmount == 0) {
                if (vd.swaps[i].amountIn != 0) revert InputAmountMismatch();
                if (vd.swaps[i].minOut != 0) revert InputAmountMismatch();
                continue;
            }

            if (legs[i].token == address(0)) revert InvalidLeg();

            uint256 legAmountIn = vd.swaps[i].amountIn;
            if (legAmountIn != legs[i].targetAmount) revert InputAmountMismatch();

            if (IERC20(legs[i].token).balanceOf(address(this)) < legAmountIn) {
                revert InsufficientVenueBalance();
            }

            if (legs[i].token == outputToken) {
                IERC20(outputToken).safeTransfer(recipient, legAmountIn);
                totalOut += legAmountIn;
                continue;
            }

            if (vd.swaps[i].minOut == 0) revert ZeroMinOutput();

            IERC20(legs[i].token).safeTransfer(address(adapter), legAmountIn);

            IP10OneInchAdapter.SwapDescription memory desc = IP10OneInchAdapter.SwapDescription({
                srcToken: IERC20(legs[i].token),
                dstToken: IERC20(outputToken),
                srcReceiver: payable(address(adapter)),
                dstReceiver: payable(address(adapter)),
                amount: legAmountIn,
                minReturnAmount: vd.swaps[i].minOut,
                flags: 0
            });

            uint256 out = adapter.execute(
                legs[i].token,
                legAmountIn,
                outputToken,
                vd.swaps[i].minOut,
                desc,
                "",
                vd.swaps[i].oneInchData,
                vd.swaps[i].executor,
                recipient
            );

            totalOut += out;
        }

        for (uint256 i = 0; i < legs.length; i++) {
            if (legs[i].targetAmount == 0) continue;

            uint256 expectedAfter = beforeLegBalances[i] - legs[i].targetAmount;
            uint256 actualAfter = IERC20(legs[i].token).balanceOf(address(this));
            if (actualAfter != expectedAfter) revert VenueBalanceDeltaMismatch();
        }

        require(totalOut >= minOutput, "P10Venue1Inch: slippage");
        return totalOut;
    }

    function name() external pure override returns (string memory) {
        return "1inch";
    }
}
