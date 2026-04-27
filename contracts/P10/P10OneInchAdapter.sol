// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

interface I1inchRouterV6 {
    struct SwapDescription {
        IERC20 srcToken;
        IERC20 dstToken;
        address payable srcReceiver;
        address payable dstReceiver;
        uint256 amount;
        uint256 minReturnAmount;
        uint256 flags;
    }

    function swap(
        address executor,
        SwapDescription calldata desc,
        bytes calldata permit,
        bytes calldata data
    ) external payable returns (uint256 returnAmount, uint256 spentAmount);
}

contract P10OneInchAdapter is Ownable2Step, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;

    error ZeroAddress();
    error OnlyAuthorizedCaller();
    error NativeValueNotAccepted();
    error ExecutorNotAllowed();
    error TokenMismatch();
    error AmountMismatch();
    error MinReturnTooLow();
    error BadSrcReceiver();
    error BadDstReceiver();
    error PartialSpendNotAllowed();
    error ReturnAmountTooLow();
    error OutputMismatch();
    error InputNotFullyConsumed();
    error InvalidReceiver();
    error RouterNotSet();

    address public authorizedCaller; // P10Venue1Inch
    address public oneInchRouter;
    mapping(address => bool) public allowedExecutors;

    event AuthorizedCallerUpdated(address indexed caller);
    event RouterUpdated(address indexed router);
    event ExecutorAllowed(address indexed executor, bool allowed);
    event SwapExecuted(
        address indexed tokenIn,
        address indexed tokenOut,
        uint256 amountIn,
        uint256 amountOut,
        uint256 spentAmount,
        address indexed executor,
        address receiver
    );
    event Rescue(address indexed token, address indexed to, uint256 amount);

    constructor(
        address initialOwner,
        address initialAuthorizedCaller,
        address initialRouter
    ) Ownable(initialOwner) {
        if (
            initialOwner == address(0) ||
            initialAuthorizedCaller == address(0) ||
            initialRouter == address(0)
        ) revert ZeroAddress();

        authorizedCaller = initialAuthorizedCaller;
        oneInchRouter = initialRouter;

        emit AuthorizedCallerUpdated(initialAuthorizedCaller);
        emit RouterUpdated(initialRouter);
    }

    function setAuthorizedCaller(address newCaller) external onlyOwner {
        if (newCaller == address(0)) revert ZeroAddress();
        authorizedCaller = newCaller;
        emit AuthorizedCallerUpdated(newCaller);
    }

    function setRouter(address newRouter) external onlyOwner {
        if (newRouter == address(0)) revert ZeroAddress();
        oneInchRouter = newRouter;
        emit RouterUpdated(newRouter);
    }

    function setExecutorAllowed(address executor, bool allowed) external onlyOwner {
        allowedExecutors[executor] = allowed;
        emit ExecutorAllowed(executor, allowed);
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    /// @notice Called only by P10Venue1Inch after it has transferred exact input here.
    function execute(
        address tokenIn,
        uint256 amountIn,
        address tokenOut,
        uint256 minAmountOut,
        I1inchRouterV6.SwapDescription calldata desc,
        bytes calldata permitData,
        bytes calldata oneInchData,
        address executor,
        address receiver
    ) external payable nonReentrant whenNotPaused returns (uint256 actualOut) {
        if (msg.sender != authorizedCaller) revert OnlyAuthorizedCaller();
        if (msg.value != 0) revert NativeValueNotAccepted();
        if (oneInchRouter == address(0)) revert RouterNotSet();
        if (receiver == address(0)) revert InvalidReceiver();

        if (executor != address(0) && !allowedExecutors[executor]) {
            revert ExecutorNotAllowed();
        }

        if (address(desc.srcToken) != tokenIn || address(desc.dstToken) != tokenOut) {
            revert TokenMismatch();
        }
        if (desc.amount != amountIn) revert AmountMismatch();
        if (desc.minReturnAmount < minAmountOut) revert MinReturnTooLow();
        if (desc.srcReceiver != payable(address(this))) revert BadSrcReceiver();
        if (desc.dstReceiver != payable(address(this))) revert BadDstReceiver();

        uint256 tokenInBefore = IERC20(tokenIn).balanceOf(address(this));
        if (tokenInBefore < amountIn) revert AmountMismatch();

        uint256 tokenOutBefore = IERC20(tokenOut).balanceOf(address(this));

        IERC20(tokenIn).forceApprove(oneInchRouter, amountIn);

        (uint256 returnAmount, uint256 spentAmount) = I1inchRouterV6(oneInchRouter).swap(
            executor,
            desc,
            permitData,
            oneInchData
        );

        IERC20(tokenIn).forceApprove(oneInchRouter, 0);

        if (spentAmount != amountIn) revert PartialSpendNotAllowed();

        uint256 tokenInAfter = IERC20(tokenIn).balanceOf(address(this));
        if (tokenInAfter != tokenInBefore - amountIn) revert InputNotFullyConsumed();

        if (returnAmount < minAmountOut) revert ReturnAmountTooLow();

        actualOut = IERC20(tokenOut).balanceOf(address(this)) - tokenOutBefore;
        if (actualOut < minAmountOut || actualOut != returnAmount) {
            revert OutputMismatch();
        }

        IERC20(tokenOut).safeTransfer(receiver, actualOut);

        emit SwapExecuted(tokenIn, tokenOut, amountIn, actualOut, spentAmount, executor, receiver);
    }

    function rescue(address token, address to) external onlyOwner nonReentrant {
        if (to == address(0)) revert InvalidReceiver();
        uint256 bal = IERC20(token).balanceOf(address(this));
        IERC20(token).safeTransfer(to, bal);
        emit Rescue(token, to, bal);
    }
}
