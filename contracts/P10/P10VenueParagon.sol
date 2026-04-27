// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {IP10VenueAdapter} from "./interfaces/IP10VenueAdapter.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

interface IParagonRouterLike {
    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline,
        uint8 autoYieldPercent
    ) external returns (uint256 amountOut);

    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline,
        uint8 autoYieldPercent
    ) external returns (uint256[] memory amounts);

    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts);
}

contract P10VenueParagon is IP10VenueAdapter, Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    error NotExecutionManager();
    error ZeroAddress();
    error InvalidLeg();
    error InputAmountMismatch();
    error UnsupportedVenueData();
    error WrongReceiver();
    error ZeroMinOutput();
    error EmptyLegs();
    error InvalidPath();
    error InvalidDeadline();
    error RouterSwapFailed();
    error InsufficientVenueBalance();
    error SameTokenMinOutTooHigh();
    error VenueBalanceDeltaMismatch();

    struct PathSwapData {
        address[] path;
        uint256 amountIn;
        uint256 minOut;
        bool supportFeeOnTransfer;
    }

    struct BuyVenueData {
        uint256 deadline;
        PathSwapData[] swaps;
    }

    struct SellVenueData {
        uint256 deadline;
        PathSwapData[] swaps;
    }

    IParagonRouterLike public immutable router;
    address public executionManager;

    event ExecutionManagerUpdated(address indexed oldExec, address indexed newExec);

    constructor(
        address initialOwner,
        address _router,
        address _executionManager
    ) Ownable(initialOwner) {
        if (_router == address(0) || _executionManager == address(0)) revert ZeroAddress();
        router = IParagonRouterLike(_router);
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
        if (vd.deadline < block.timestamp) revert InvalidDeadline();

        uint256 beforeInputBal = IERC20(inputToken).balanceOf(address(this));
        actualAcquired = new uint256[](legs.length);

        uint256 totalInputUsed = 0;

        for (uint256 i = 0; i < legs.length; i++) {
            if (legs[i].targetAmount == 0) {
                if (vd.swaps[i].amountIn != 0) revert InputAmountMismatch();
                if (vd.swaps[i].minOut != 0) revert InputAmountMismatch();
                if (vd.swaps[i].path.length != 0) revert InvalidPath();
                continue;
            }

            if (legs[i].token == address(0)) revert InvalidLeg();

            uint256 legAmountIn = vd.swaps[i].amountIn;
            if (legAmountIn == 0) revert InvalidLeg();

            totalInputUsed += legAmountIn;

            if (IERC20(inputToken).balanceOf(address(this)) < legAmountIn) {
                revert InsufficientVenueBalance();
            }

            // Same-token leg: direct transfer to receiver (vault), no router swap.
            if (legs[i].token == inputToken) {
                if (legAmountIn != legs[i].targetAmount) revert InputAmountMismatch();
                if (vd.swaps[i].minOut > legAmountIn) revert SameTokenMinOutTooHigh();

                IERC20(inputToken).safeTransfer(receiver, legAmountIn);
                actualAcquired[i] = legAmountIn;
                continue;
            }

            _validateBuyPath(vd.swaps[i].path, inputToken, legs[i].token);

            uint256 beforeOut = IERC20(legs[i].token).balanceOf(receiver);

            _routerSwapExactIn(
                inputToken,
                legAmountIn,
                vd.swaps[i].minOut,
                vd.swaps[i].path,
                receiver,
                vd.deadline,
                vd.swaps[i].supportFeeOnTransfer
            );

            uint256 afterOut = IERC20(legs[i].token).balanceOf(receiver);
            actualAcquired[i] = afterOut - beforeOut;

            if (actualAcquired[i] < vd.swaps[i].minOut) revert ZeroMinOutput();
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
        if (vd.deadline < block.timestamp) revert InvalidDeadline();

        uint256[] memory beforeLegBalances = new uint256[](legs.length);
        for (uint256 i = 0; i < legs.length; i++) {
            if (legs[i].targetAmount == 0) {
                beforeLegBalances[i] = 0;
                if (vd.swaps[i].amountIn != 0) revert InputAmountMismatch();
                if (vd.swaps[i].minOut != 0) revert InputAmountMismatch();
                if (vd.swaps[i].path.length != 0) revert InvalidPath();
                continue;
            }

            if (legs[i].token == address(0)) revert InvalidLeg();
            beforeLegBalances[i] = IERC20(legs[i].token).balanceOf(address(this));
        }

        uint256 totalOut = 0;

        for (uint256 i = 0; i < legs.length; i++) {
            if (legs[i].targetAmount == 0) continue;

            uint256 legAmountIn = vd.swaps[i].amountIn;
            if (legAmountIn != legs[i].targetAmount) revert InputAmountMismatch();

            if (IERC20(legs[i].token).balanceOf(address(this)) < legAmountIn) {
                revert InsufficientVenueBalance();
            }

            // Same-token leg: direct transfer to recipient.
            if (legs[i].token == outputToken) {
                if (vd.swaps[i].minOut > legAmountIn) revert SameTokenMinOutTooHigh();

                uint256 beforeOutSame = IERC20(outputToken).balanceOf(recipient);
                IERC20(outputToken).safeTransfer(recipient, legAmountIn);
                uint256 afterOutSame = IERC20(outputToken).balanceOf(recipient);

                totalOut += (afterOutSame - beforeOutSame);
                continue;
            }

            _validateSellPath(vd.swaps[i].path, legs[i].token, outputToken);

            uint256 beforeOut = IERC20(outputToken).balanceOf(recipient);

            _routerSwapExactIn(
                legs[i].token,
                legAmountIn,
                vd.swaps[i].minOut,
                vd.swaps[i].path,
                recipient,
                vd.deadline,
                vd.swaps[i].supportFeeOnTransfer
            );

            uint256 afterOut = IERC20(outputToken).balanceOf(recipient);
            uint256 legOut = afterOut - beforeOut;

            if (legOut < vd.swaps[i].minOut) revert ZeroMinOutput();
            totalOut += legOut;
        }

        for (uint256 i = 0; i < legs.length; i++) {
            if (legs[i].targetAmount == 0) continue;

            uint256 expectedAfter = beforeLegBalances[i] - legs[i].targetAmount;
            uint256 actualAfter = IERC20(legs[i].token).balanceOf(address(this));
            if (actualAfter != expectedAfter) revert VenueBalanceDeltaMismatch();
        }

        if (totalOut < minOutput) revert ZeroMinOutput();
        return totalOut;
    }

    function name() external pure override returns (string memory) {
        return "Paragon";
    }

    function _validateBuyPath(
        address[] memory path,
        address tokenIn,
        address tokenOut
    ) internal pure {
        if (path.length < 2) revert InvalidPath();
        if (path[0] != tokenIn) revert InvalidPath();
        if (path[path.length - 1] != tokenOut) revert InvalidPath();

        for (uint256 i = 0; i < path.length; i++) {
            if (path[i] == address(0)) revert InvalidPath();
            if (i + 1 < path.length && path[i] == path[i + 1]) revert InvalidPath();
        }
    }

    function _validateSellPath(
        address[] memory path,
        address tokenIn,
        address tokenOut
    ) internal pure {
        if (path.length < 2) revert InvalidPath();
        if (path[0] != tokenIn) revert InvalidPath();
        if (path[path.length - 1] != tokenOut) revert InvalidPath();

        for (uint256 i = 0; i < path.length; i++) {
            if (path[i] == address(0)) revert InvalidPath();
            if (i + 1 < path.length && path[i] == path[i + 1]) revert InvalidPath();
        }
    }

    function _routerSwapExactIn(
        address tokenIn,
        uint256 amountIn,
        uint256 amountOutMin,
        address[] memory path,
        address to,
        uint256 deadline,
        bool supportFeeOnTransfer
    ) internal {
        IERC20(tokenIn).forceApprove(address(router), 0);
        IERC20(tokenIn).forceApprove(address(router), amountIn);

        bool ok;

        if (supportFeeOnTransfer) {
            (ok,) = address(router).call(
                abi.encodeWithSelector(
                    bytes4(
                        keccak256(
                            "swapExactTokensForTokensSupportingFeeOnTransferTokens(uint256,uint256,address[],address,uint256,uint8)"
                        )
                    ),
                    amountIn,
                    amountOutMin,
                    path,
                    to,
                    deadline,
                    uint8(0)
                )
            );
            IERC20(tokenIn).forceApprove(address(router), 0);
            if (!ok) revert RouterSwapFailed();
            return;
        }

        (ok,) = address(router).call(
            abi.encodeWithSelector(
                bytes4(
                    keccak256(
                        "swapExactTokensForTokens(uint256,uint256,address[],address,uint256,uint8)"
                    )
                ),
                amountIn,
                amountOutMin,
                path,
                to,
                deadline,
                uint8(0)
            )
        );

        if (!ok) {
            (ok,) = address(router).call(
                abi.encodeWithSelector(
                    bytes4(
                        keccak256(
                            "swapExactTokensForTokens(uint256,uint256,address[],address,uint256)"
                        )
                    ),
                    amountIn,
                    amountOutMin,
                    path,
                    to,
                    deadline
                )
            );
        }

        IERC20(tokenIn).forceApprove(address(router), 0);

        if (!ok) revert RouterSwapFailed();
    }
}
