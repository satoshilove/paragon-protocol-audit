// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title Paragon Router Interface for BSC (+ fee views)
interface IParagonRouter {
    function factory() external view returns (address);
    function WNative() external view returns (address);
    function getAmountsOut(uint amountIn, address[] calldata path) external view returns (uint[] memory amounts);
    function swapExactTokensForTokens(
        uint amountIn,
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external returns (uint[] memory amounts);
    function swapExactTokensForTokens(
        uint amountIn,
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline,
        uint8 autoYieldPercent
    ) external returns (uint[] memory amounts);
    function addLiquidity(
        address tokenA,
        address tokenB,
        uint amountADesired,
        uint amountBDesired,
        uint amountAMin,
        uint amountBMin,
        address to,
        uint deadline
    ) external returns (uint amountA, uint amountB, uint liquidity);
    function protocolFeeBps() external view returns (uint256);
    function feeRecipient() external view returns (address);
}

/// @title Paragon Factory Interface for BSC
interface IParagonFactory {
    function getPair(address tokenA, address tokenB) external view returns (address pair);
}

/// @title Paragon Pair Interface for BSC
interface IParagonPair is IERC20 {
    function token0() external view returns (address);
    function token1() external view returns (address);
    function getReserves() external view returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast);
}

/// @title Farming Contract Interface
interface IParagonFarm {
    function depositFor(uint256 pid, uint256 amount, address user, address referrer) external;
    function poolLpToken(uint256 pid) external view returns (address);
    function poolInfo(uint256 pid) external view returns (address lpToken, uint256 allocPoint, uint256 lastRewardBlock, uint256 accTokenPerShare);
}

/// @title Wrapped Native Interface for BSC
interface IWrappedNative is IERC20 {
    function deposit() external payable;
    function withdraw(uint256) external;
}

/// @title ParagonZapV2 - Router fee-synced zap
/// @notice Zaps tokens/native into LPs and optionally stakes; FOT tokens not supported
/// @dev FOT (fee-on-transfer) tokens are NOT supported and will revert
contract ParagonZapV2 is Ownable, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;

    // Errors
    error ZeroAmount();
    error InvalidPair();
    error Deadline();
    error SlippageTooHigh();
    error InvalidPath();
    error FarmNotActive();
    error FeeTooHigh();
    error InsufficientOutput();
    error MEVProtectionActive();
    error FOTNotSupported();
    error InvalidFeeRecipient();
    error TokenNotRescuable();

    // Zap parameters
    struct ZapParams {
        uint256 pid; // target farm pool
        address tokenIn; // address(0) for native BNB
        uint256 amountIn; // ignored when tokenIn == address(0); uses msg.value
        address[] pathToTokenA; // tokenInNorm -> token0
        address[] pathToTokenB; // tokenInNorm -> token1
        uint256 minLpOut; // LP slippage guard
        uint256 slippageBps; // 0..1000 (10%)
        address recipient; // end LP owner / farm depositor
        address referrer; // optional referrer
        uint256 deadline; // unix deadline
        bool autoStake; // deposit LP into farm
        bytes32 salt; // MEV protection (optional salt for commit-reveal)
    }

    // Protocol configuration
    struct ProtocolConfig {
        uint256 platformFeeBps; // used only if router doesn’t expose protocolFeeBps()
        uint256 referralFeeBps; // slice from platform fee; clamped to platform fee
        address feeRecipient; // used only if router doesn’t expose feeRecipient()
        uint256 maxSlippageBps; // user param guard
        uint256 maxPathLength; // path length guard
    }

    // Events
    event ZapExecuted(
        address indexed user,
        uint256 indexed pid,
        address tokenIn,
        uint256 amountIn,
        uint256 amountA,
        uint256 amountB,
        uint256 lpMinted,
        bool autoStaked,
        address referrer
    );
    event FeeCollected(address indexed token, uint256 amount, address recipient);
    event ReferralReward(address indexed referrer, address indexed token, uint256 amount);
    event ProtocolConfigUpdated(ProtocolConfig config);
    event EmergencyWithdraw(address indexed token, uint256 amount);
    event AutoStakeFallback(address indexed user, uint256 indexed pid, uint256 lpAmount);

    // Core
    IParagonRouter public immutable router;
    IParagonFactory public immutable factory;
    IParagonFarm public immutable farm;
    address public immutable WNATIVE;
    ProtocolConfig public config;

    // MEV commit mapping
    mapping(bytes32 => uint256) public commitments; // commitment -> blockNumber

    // Referral accounting
    mapping(address => uint256) public referralEarnings;

    // Constants
    uint256 private constant BPS_DENOM = 10_000;
    uint256 private constant MAX_PLATFORM_FEE = 50; // 0.5% fallback cap
    uint256 private constant MAX_REFERRAL_FEE = 20; // 0.2% cap (slice of platform fee)
    uint256 private constant MEV_DELAY = 2; // >= 2 blocks for BSC

    /// @notice Constructor to initialize contract with router, farm, and fee recipient
    /// @param _router Address of the Paragon router
    /// @param _farm Address of the farming contract
    /// @param _feeRecipient Address to receive protocol fees
    constructor(address _router, address _farm, address _feeRecipient) Ownable(msg.sender) {
        router = IParagonRouter(_router);
        factory = IParagonFactory(router.factory());
        WNATIVE = router.WNative();
        farm = IParagonFarm(_farm);
        if (_feeRecipient == address(0) || _feeRecipient.code.length > 0) revert InvalidFeeRecipient();
        config = ProtocolConfig({
            platformFeeBps: 25,
            referralFeeBps: 10,
            feeRecipient: _feeRecipient,
            maxSlippageBps: 1000,
            maxPathLength: 4
        });
    }

    receive() external payable {}

    /// @notice Get the active fee and recipient from router or config
    /// @return feeBps The active platform fee in basis points
    /// @return recipient The active fee recipient address
    function getActiveFee() external view returns (uint256 feeBps, address recipient) {
        try router.protocolFeeBps() returns (uint256 rBps) {
            feeBps = rBps;
        } catch {
            feeBps = config.platformFeeBps;
        }
        try router.feeRecipient() returns (address rf) {
            recipient = rf;
        } catch {
            recipient = config.feeRecipient;
        }
        if (recipient == address(0)) revert InvalidFeeRecipient();
    }

    /// @notice Main function to zap tokens or BNB into LP tokens and optionally stake
    /// @param p Zap parameters
    /// @return lpMinted Amount of LP tokens minted
    function zapInAndStake(ZapParams calldata p)
        external
        payable
        nonReentrant
        whenNotPaused
        returns (uint256 lpMinted)
    {
        if (block.timestamp > p.deadline) revert Deadline();
        if (p.tokenIn != address(0) && p.amountIn == 0) revert ZeroAmount();
        if (p.slippageBps > config.maxSlippageBps) revert SlippageTooHigh();

        // Cache core contracts (gas)
        IParagonRouter _router = router;
        IParagonFarm _farm = farm;

        // Optional MEV commit-reveal
        if (p.salt != bytes32(0)) {
            bytes32 paramsHash = keccak256(
                abi.encode(
                    p.pid,
                    p.tokenIn,
                    p.amountIn,
                    p.pathToTokenA,
                    p.pathToTokenB,
                    p.minLpOut,
                    p.slippageBps,
                    p.recipient,
                    p.referrer,
                    p.deadline,
                    p.autoStake,
                    p.salt
                )
            );
            bytes32 commitment = keccak256(abi.encode(paramsHash, msg.sender));
            uint256 committedAt = commitments[commitment];
            if (committedAt == 0 || block.number <= committedAt + MEV_DELAY) revert MEVProtectionActive();
            delete commitments[commitment];
        }

        // Validate farm & pair
        (address lpToken, uint256 allocPoint, , ) = _farm.poolInfo(p.pid);
        if (lpToken == address(0)) revert InvalidPair();
        if (allocPoint == 0) revert FarmNotActive();
        IParagonPair pair = IParagonPair(lpToken);
        (address token0, address token1) = (pair.token0(), pair.token1());

        // Ingest funds
        uint256 rawAmountIn;
        if (p.tokenIn == address(0)) {
            rawAmountIn = msg.value;
            if (rawAmountIn == 0) revert ZeroAmount();
        } else {
            rawAmountIn = _pullTokenReturnAmount(p.tokenIn, msg.sender, p.amountIn);
        }

        // Fees (sync with router)
        uint256 platformFeeBps = _activeRouterFeeBps();
        address routerFeeSink = _activeFeeRecipient();
        if (platformFeeBps > MAX_PLATFORM_FEE) revert FeeTooHigh();

        uint256 feeAmount = (rawAmountIn * platformFeeBps) / BPS_DENOM;
        uint256 refBps = config.referralFeeBps > platformFeeBps ? platformFeeBps : config.referralFeeBps;
        uint256 refAmount = (rawAmountIn * refBps) / BPS_DENOM;
        uint256 protocolFeeNet = feeAmount - refAmount;

        // Pay referral (from fee)
        if (refAmount > 0 && p.referrer != address(0) && p.referrer != p.recipient) {
            if (p.referrer.code.length > 0) revert InvalidFeeRecipient();
            _pay(p.referrer, p.tokenIn, refAmount);
            referralEarnings[p.referrer] += refAmount;
            emit ReferralReward(p.referrer, p.tokenIn, refAmount);
        }

        // Pay protocol fee remainder
        if (protocolFeeNet > 0) _collectFee(p.tokenIn, protocolFeeNet, routerFeeSink);

        // Amount to zap
        uint256 zapAmount = rawAmountIn - feeAmount;

        // Normalize input to WNative for internal flow
        address tokenInNorm = p.tokenIn == address(0) ? WNATIVE : p.tokenIn;
        if (p.tokenIn == address(0)) {
            IWrappedNative(WNATIVE).deposit{value: zapAmount}();
        }

        // Validate paths with normalized input
        _validatePaths(p.pathToTokenA, p.pathToTokenB, token0, token1, tokenInNorm);

        // Build liquidity amounts
        (uint256 amountA, uint256 amountB) = _prepareLiquidity(
            pair,
            tokenInNorm,
            zapAmount,
            token0,
            token1,
            p.pathToTokenA,
            p.pathToTokenB,
            p.deadline,
            p.slippageBps
        );

        // Add liquidity (ERC-20 only)
        SafeERC20.forceApprove(IERC20(token0), address(_router), amountA);
        SafeERC20.forceApprove(IERC20(token1), address(_router), amountB);
        (,, lpMinted) = _router.addLiquidity(
            token0,
            token1,
            amountA,
            amountB,
            _applySlippage(amountA, p.slippageBps),
            _applySlippage(amountB, p.slippageBps),
            address(this),
            p.deadline
        );
        if (lpMinted < p.minLpOut) revert InsufficientOutput();

        // Stake or transfer LP
        if (p.autoStake) {
            SafeERC20.forceApprove(IERC20(lpToken), address(_farm), lpMinted);
            try _farm.depositFor(p.pid, lpMinted, p.recipient, p.referrer) {
                // Success
            } catch {
                SafeERC20.forceApprove(IERC20(lpToken), address(_farm), 0);
                emit AutoStakeFallback(p.recipient, p.pid, lpMinted);
                IERC20(lpToken).safeTransfer(p.recipient, lpMinted);
            }
        } else {
            IERC20(lpToken).safeTransfer(p.recipient, lpMinted);
        }

        // Return dust (token0/token1)
        _returnDust(token0, token1, p.recipient);

        // If user paid native, unwrap WNative and refund as BNB (if recipient is EOA)
        if (p.tokenIn == address(0)) {
            uint256 wBal = IERC20(WNATIVE).balanceOf(address(this));
            if (wBal > 0) {
                if (p.recipient.code.length == 0) {
                    IWrappedNative(WNATIVE).withdraw(wBal);
                    (bool ok,) = p.recipient.call{value: wBal}("");
                    require(ok, "native refund");
                } else {
                    IERC20(WNATIVE).safeTransfer(p.recipient, wBal);
                }
            }
        }

        emit ZapExecuted(
            msg.sender,
            p.pid,
            p.tokenIn,
            rawAmountIn,
            amountA,
            amountB,
            lpMinted,
            p.autoStake,
            p.referrer
        );
    }

    /// @notice Commit a zap transaction for MEV protection
    /// @param paramsHash Hash of the ZapParams to commit
    function commitZap(bytes32 paramsHash) external {
        bytes32 commitment = keccak256(abi.encode(paramsHash, msg.sender));
        commitments[commitment] = block.number;
    }

    /// @notice Get the active fee from router or config
    /// @return feeBps The active platform fee in basis points
    function _activeRouterFeeBps() internal view returns (uint256 feeBps) {
        try router.protocolFeeBps() returns (uint256 rBps) {
            feeBps = rBps;
        } catch {
            feeBps = config.platformFeeBps;
        }
    }

    /// @notice Get the active fee recipient from router or config
    /// @return recipient The active fee recipient address
    function _activeFeeRecipient() internal view returns (address recipient) {
        try router.feeRecipient() returns (address rf) {
            recipient = rf;
        } catch {
            recipient = config.feeRecipient;
        }
        if (recipient == address(0)) revert InvalidFeeRecipient();
    }

    /// @notice Validate swap paths for correctness
    /// @param pathA Path to token0
    /// @param pathB Path to token1
    /// @param token0 Address of pair's token0
    /// @param token1 Address of pair's token1
    /// @param tokenInNorm Normalized input token (WNative for native)
    function _validatePaths(
        address[] calldata pathA,
        address[] calldata pathB,
        address token0,
        address token1,
        address tokenInNorm
    ) internal view {
        if (pathA.length > config.maxPathLength || pathB.length > config.maxPathLength) revert InvalidPath();
        if (pathA.length > 0 && pathA[pathA.length - 1] != token0) revert InvalidPath();
        if (pathB.length > 0 && pathB[pathB.length - 1] != token1) revert InvalidPath();
        if (pathA.length > 0 && pathA[0] != tokenInNorm) revert InvalidPath();
        if (pathB.length > 0 && pathB[0] != tokenInNorm) revert InvalidPath();
        bool inputIsSide = (tokenInNorm == token0 || tokenInNorm == token1);
        if (!inputIsSide && (pathA.length == 0 || pathB.length == 0)) revert InvalidPath();
        if (inputIsSide && (pathA.length > 0 || pathB.length > 0)) revert InvalidPath();
    }

    /// @notice Prepare liquidity amounts for single-sided or dual-sided zaps
    function _prepareLiquidity(
        IParagonPair pair,
        address tokenInNorm,
        uint256 amountIn,
        address token0,
        address token1,
        address[] calldata pathToA,
        address[] calldata pathToB,
        uint256 deadline,
        uint256 slippageBps
    ) internal returns (uint256 amountA, uint256 amountB) {
        (uint112 r0, uint112 r1,) = pair.getReserves();
        if (tokenInNorm == token0 || tokenInNorm == token1) {
            return _singleSidedZap(tokenInNorm, amountIn, token0, token1, r0, r1, deadline, slippageBps);
        }
        return _dualSidedZap(tokenInNorm, amountIn, pathToA, pathToB, deadline, slippageBps);
    }

    /// @notice Handle single-sided zap (input is one of the pair tokens)
    function _singleSidedZap(
        address tokenInNorm,
        uint256 amountIn,
        address token0,
        address token1,
        uint112 r0,
        uint112 r1,
        uint256 deadline,
        uint256 slippageBps
    ) internal returns (uint256 amountA, uint256 amountB) {
        bool inIs0 = (tokenInNorm == token0);
        address[] memory path = new address[](2);
        path[0] = tokenInNorm;
        path[1] = inIs0 ? token1 : token0;
        uint256 swapPortion = _optimalSwapPortion(amountIn, inIs0 ? r0 : r1, inIs0 ? r1 : r0, path);
        uint256 outB = _swapExact(tokenInNorm, swapPortion, path, address(this), deadline, slippageBps);
        uint256 remainA = amountIn - swapPortion;
        if (inIs0) { amountA = remainA; amountB = outB; }
        else { amountA = outB; amountB = remainA; }
    }

    /// @notice Handle dual-sided zap (input is swapped to both pair tokens)
    function _dualSidedZap(
        address tokenInNorm,
        uint256 amountIn,
        address[] calldata pathToA,
        address[] calldata pathToB,
        uint256 deadline,
        uint256 slippageBps
    ) internal returns (uint256 amountA, uint256 amountB) {
        uint256 half = amountIn / 2;
        amountA = pathToA.length > 0 ? _swapExact(tokenInNorm, half, pathToA, address(this), deadline, slippageBps) : half;
        amountB = pathToB.length > 0 ? _swapExact(tokenInNorm, amountIn - half, pathToB, address(this), deadline, slippageBps) : (amountIn - half);
    }

    /// @notice Calculate optimal swap portion for single-sided zap
    function _optimalSwapPortion(
        uint256 amountIn,
        uint256 reserveIn,
        uint256 reserveOut,
        address[] memory path
    ) internal view returns (uint256 swapPortion) {
        uint256 lo = 0;
        uint256 hi = amountIn;
        uint256 mid;
        uint256 outMid;
        for (uint256 i = 0; i < 18; i++) {
            mid = (lo + hi) / 2;
            try router.getAmountsOut(mid, path) returns (uint[] memory am) {
                outMid = am[am.length - 1];
                uint256 lhs = (amountIn - mid) * reserveOut;
                uint256 rhs = outMid * reserveIn;
                if (lhs > rhs) { lo = mid + 1; } else { hi = mid; }
            } catch {
                return (amountIn * 4990) / 10_000; // ~49.9% fallback
            }
        }
        swapPortion = hi;
    }

    /// @notice Perform a token swap with slippage protection
    function _swapExact(
        address tokenFrom,
        uint256 amountIn,
        address[] memory path,
        address to,
        uint256 deadline,
        uint256 slippageBps
    ) internal returns (uint256 amountOut) {
        if (amountIn == 0) return 0;
        if (path.length < 2) return amountIn;
        IParagonRouter _router = router;
        uint[] memory expectedAmts = _router.getAmountsOut(amountIn, path);
        uint256 expectedOut = expectedAmts[expectedAmts.length - 1];
        uint256 amountOutMin = _applySlippage(expectedOut, slippageBps);
        SafeERC20.forceApprove(IERC20(tokenFrom), address(_router), 0);
        SafeERC20.forceApprove(IERC20(tokenFrom), address(_router), amountIn);
        try _router.swapExactTokensForTokens(amountIn, amountOutMin, path, to, deadline, 0) returns (uint[] memory amts) {
            amountOut = amts[amts.length - 1];
        } catch {
            uint[] memory amts = _router.swapExactTokensForTokens(amountIn, amountOutMin, path, to, deadline);
            amountOut = amts[amts.length - 1];
        }
    }

    /// @notice Pull tokens from user and revert on FOT
    function _pullTokenReturnAmount(address token, address from, uint256 amount)
        internal
        returns (uint256 received)
    {
        uint256 b0 = IERC20(token).balanceOf(address(this));
        IERC20(token).safeTransferFrom(from, address(this), amount);
        received = IERC20(token).balanceOf(address(this)) - b0;
        if (received != amount) revert FOTNotSupported();
    }

    /// @notice Pay tokens or BNB to an address
    function _pay(address to, address token, uint256 amount) internal {
        if (amount == 0) return;
        if (token == address(0)) {
            (bool ok,) = to.call{value: amount}("");
            require(ok, "pay fail");
        } else {
            uint256 b0 = IERC20(token).balanceOf(to);
            IERC20(token).safeTransfer(to, amount);
            if (IERC20(token).balanceOf(to) - b0 != amount) revert FOTNotSupported();
        }
    }

    /// @notice Collect protocol fees
    function _collectFee(address token, uint256 amount, address recipient) internal {
        if (amount == 0) return;
        _pay(recipient, token, amount);
        emit FeeCollected(token, amount, recipient);
    }

    /// @notice Return leftover tokens to user
    function _returnDust(address token0, address token1, address to) internal {
        uint256 b0 = IERC20(token0).balanceOf(address(this));
        uint256 b1 = IERC20(token1).balanceOf(address(this));
        if (b0 > 0) IERC20(token0).safeTransfer(to, b0);
        if (b1 > 0) IERC20(token1).safeTransfer(to, b1);
    }

    /// @notice Apply slippage to an amount
    function _applySlippage(uint256 amount, uint256 slippageBps) internal pure returns (uint256) {
        if (slippageBps == 0) return amount;
        if (slippageBps > 1000) slippageBps = 1000;
        return (amount * (BPS_DENOM - slippageBps)) / BPS_DENOM;
    }

    // ========= Admin =========
    /// @notice Update protocol configuration
    /// @param newConfig New protocol configuration
    function updateProtocolConfig(ProtocolConfig calldata newConfig) external onlyOwner {
        if (newConfig.platformFeeBps > MAX_PLATFORM_FEE) revert FeeTooHigh();
        if (newConfig.referralFeeBps > MAX_REFERRAL_FEE) revert FeeTooHigh();
        if (newConfig.feeRecipient == address(0) || newConfig.feeRecipient.code.length > 0) revert InvalidFeeRecipient();
        config = newConfig;
        emit ProtocolConfigUpdated(newConfig);
    }

    /// @notice Pause the contract
    function pause() external onlyOwner {
        _pause();
    }

    /// @notice Unpause the contract
    function unpause() external onlyOwner {
        _unpause();
    }

    /// @notice Emergency withdraw tokens or BNB (restricted to non-LP/pair tokens)
    /// @param token Token to withdraw (address(0) for BNB)
    /// @param amount Amount to withdraw
    function emergencyWithdraw(address token, uint256 amount) external onlyOwner {
        // Check if token is an LP token or pair asset
        for (uint256 pid = 0; pid < 100; pid++) {
            address lpToken = farm.poolLpToken(pid);
            if (lpToken == address(0)) break; // End of valid PIDs
            if (token == lpToken) revert TokenNotRescuable();
            IParagonPair pair = IParagonPair(lpToken);
            if (token == pair.token0() || token == pair.token1()) revert TokenNotRescuable();
        }
        if (token == WNATIVE) revert TokenNotRescuable();
        if (token == address(0)) {
            (bool ok,) = owner().call{value: amount}("");
            require(ok, "transfer fail");
        } else {
            IERC20(token).safeTransfer(owner(), amount);
        }
        emit EmergencyWithdraw(token, amount);
    }

    // ========= Views =========
    /// @notice Get optimal swap amount for a pair
    /// @param amountIn Input amount
    /// @param pairAddr Address of the pair
    /// @return swapAmount Optimal amount to swap
    function getOptimalSwapAmount(uint256 amountIn, address pairAddr) external view returns (uint256 swapAmount) {
        IParagonPair pair = IParagonPair(pairAddr);
        (uint112 r0, uint112 r1,) = pair.getReserves();
        address[] memory path = new address[](2);
        path[0] = pair.token0();
        path[1] = pair.token1();
        return _optimalSwapPortion(amountIn, r0, r1, path);
    }
}