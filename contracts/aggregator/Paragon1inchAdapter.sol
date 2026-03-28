// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.25;

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

contract Paragon1inchAdapter is Ownable2Step, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;

    // -----------------------------------------------------------------------
    // Errors
    // -----------------------------------------------------------------------
    error ZeroAddress();
    error OnlyPayflow();
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

    // -----------------------------------------------------------------------
    // Storage
    // -----------------------------------------------------------------------
    address public payflowExecutor;
    address public oneInchRouter;
    mapping(address => bool) public allowedExecutors;

    // -----------------------------------------------------------------------
    // Events
    // -----------------------------------------------------------------------
    event PayflowExecutorUpdated(address indexed newPayflowExecutor);
    event RouterUpdated(address indexed newRouter);
    event ExecutorAllowed(address indexed executor, bool allowed);
    event SwapExecuted(
        address indexed tokenIn,
        address indexed tokenOut,
        uint256 amountIn,
        uint256 amountOut,
        uint256 spentAmount,
        address indexed executor
    );
    event Rescue(address indexed token, address indexed to, uint256 amount);

    // -----------------------------------------------------------------------
    // Constructor
    // -----------------------------------------------------------------------
    constructor(
        address initialOwner,
        address initialPayflowExecutor,
        address initialRouter
    ) Ownable(initialOwner) {
        if (
            initialOwner == address(0) ||
            initialPayflowExecutor == address(0) ||
            initialRouter == address(0)
        ) revert ZeroAddress();

        payflowExecutor = initialPayflowExecutor;
        oneInchRouter = initialRouter;

        emit PayflowExecutorUpdated(initialPayflowExecutor);
        emit RouterUpdated(initialRouter);
    }

    // -----------------------------------------------------------------------
    // Admin
    // -----------------------------------------------------------------------
    function setPayflowExecutor(address newPayflowExecutor) external onlyOwner {
        if (newPayflowExecutor == address(0)) revert ZeroAddress();
        payflowExecutor = newPayflowExecutor;
        emit PayflowExecutorUpdated(newPayflowExecutor);
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

    // -----------------------------------------------------------------------
    // Core swap entrypoint
    // -----------------------------------------------------------------------
    /// @notice Called only by Payflow after Payflow has already transferred
    ///         `amountIn` of `tokenIn` into this adapter.
    /// @dev v1 is strict exact-in: partial fills are rejected.
    function execute(
        address tokenIn,
        uint256 amountIn,
        address tokenOut,
        uint256 minAmountOut,
        I1inchRouterV6.SwapDescription calldata desc,
        bytes calldata permitData,
        bytes calldata oneInchData,
        address executor
    ) external payable nonReentrant whenNotPaused returns (uint256 actualOut) {
        if (msg.sender != payflowExecutor) revert OnlyPayflow();
        if (msg.value != 0) revert NativeValueNotAccepted();
        if (oneInchRouter == address(0)) revert RouterNotSet();

        // address(0) is allowed for direct router execution; other executors
        // must be explicitly whitelisted.
        if (executor != address(0) && !allowedExecutors[executor]) {
            revert ExecutorNotAllowed();
        }

        // Strict route description validation.
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

        // Approve exact amount to current 1inch router.
        IERC20(tokenIn).forceApprove(oneInchRouter, amountIn);

        (uint256 returnAmount, uint256 spentAmount) = I1inchRouterV6(oneInchRouter).swap(
            executor,
            desc,
            permitData,
            oneInchData
        );

        // Always clear approval after execution.
        IERC20(tokenIn).forceApprove(oneInchRouter, 0);

        // v1 policy: exact-in only, no partial fills.
        if (spentAmount != amountIn) revert PartialSpendNotAllowed();

        // Extra invariant: all expected input must actually be consumed from adapter.
        uint256 tokenInAfter = IERC20(tokenIn).balanceOf(address(this));
        if (tokenInAfter != tokenInBefore - amountIn) revert InputNotFullyConsumed();

        if (returnAmount < minAmountOut) revert ReturnAmountTooLow();

        actualOut = IERC20(tokenOut).balanceOf(address(this)) - tokenOutBefore;

        // Strong sanity: actual observed output must equal router returnAmount.
        if (actualOut < minAmountOut || actualOut != returnAmount) {
            revert OutputMismatch();
        }

        // Forward all output back to Payflow for normal settlement/surplus split.
        IERC20(tokenOut).safeTransfer(payflowExecutor, actualOut);

        emit SwapExecuted(tokenIn, tokenOut, amountIn, actualOut, spentAmount, executor);
    }

    // -----------------------------------------------------------------------
    // Emergency rescue
    // -----------------------------------------------------------------------
    function rescue(address token, address to) external onlyOwner nonReentrant {
        if (to == address(0)) revert InvalidReceiver();
        uint256 bal = IERC20(token).balanceOf(address(this));
        IERC20(token).safeTransfer(to, bal);
        emit Rescue(token, to, bal);
    }
}