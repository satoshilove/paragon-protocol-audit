// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.25;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/security/Pausable.sol";

interface IFactory {
    function getPair(address, address) external view returns (address);
}

// Import for external compatibility (used in Executor)
import { ILPFlowRebates } from "../interfaces/ILPFlowRebates.sol";

/**
 * LPFlowRebates
 * - Governance hardening: Pausable + pause guardian (pause-only).
 * - Paused: stake/withdraw/notify are halted; claim remains available.
 * - Owner is expected to be a TimelockController (48h) governed by a multisig.
 */
contract LPFlowRebates is Ownable, ReentrancyGuard, Pausable, ILPFlowRebates {
    using SafeERC20 for IERC20;

    struct RewardData {
        uint256 rewardPerTokenStored; // 1e18 scale
        uint256 queued;               // rewards queued when no stakers
    }

    IFactory public immutable factory;
    address public notifier; // PayflowExecutorV2

    // lpToken => totalStaked
    mapping(address => uint256) public totalStaked;
    // lpToken => user => balance
    mapping(address => mapping(address => uint256)) public balances;
    // lpToken => rewardToken => RewardData
    mapping(address => mapping(address => RewardData)) public rewardData;
    // lpToken => user => rewardToken => userPaid RPT
    mapping(address => mapping(address => mapping(address => uint256))) public userPaidPerToken;
    // lpToken => user => rewardToken => accrued
    mapping(address => mapping(address => mapping(address => uint256))) public accrued;

    // Allowlist of reward tokens: notify only for active; claim/settle for ever-supported.
    address[] public supportedRewardTokens;
    mapping(address => bool) public isSupportedReward;

    // Track all ever-supported rewards for historical settlement/claiming (prevents loss on removal)
    address[] public allEverSupportedRewards;
    mapping(address => bool) public everSupportedReward;

    // Whitelist for LP tokens (regulates non-standard/deflationary LPs)
    mapping(address => bool) public allowedLp;
    uint8 public constant MAX_SUPPORTED_REWARDS = 20;

    // --- governance / admin errors ---
    error BadArg();
    error InsufficientBalance();
    error MaxRewards();
    error BadIndex();
    error UnsupportedReward();
    error UnsupportedLp();

    // --- events ---
    event NotifierSet(address indexed n);
    event Staked(address indexed user, address indexed lp, uint256 amount);
    event Withdrawn(address indexed user, address indexed lp, uint256 amount);
    event Notified(address indexed lp, address indexed reward, uint256 amount);
    event Claimed(address indexed user, address indexed lp, address indexed reward, uint256 amount);
    event SupportedRewardAdded(address indexed reward);
    event SupportedRewardRemoved(address indexed reward);
    event EmergencySwept(address indexed lp, address indexed reward, address indexed to, uint256 amount);
    event AllowedLpSet(address indexed lp, bool allowed);

    // --- Pause guardian (pause-only) ---
    event GuardianSet(address indexed guardian);
    address public guardian;

    modifier onlyNotifier() {
        if (msg.sender != notifier) revert BadArg();
        _;
    }

    modifier onlyOwnerOrGuardian() {
        require(msg.sender == owner() || msg.sender == guardian, "not owner/guardian");
        _;
    }

    // Renamed param to avoid shadowing Ownable's initialOwner
    constructor(address _factory, address _notifier, address initialOwner) Ownable(initialOwner) {
        if (_factory == address(0)) revert BadArg();
        factory  = IFactory(_factory);
        notifier = _notifier; // can be zero; set later
    }

    // --- pause controls (guardian can pause; owner can unpause) ---
    function setGuardian(address g) external onlyOwner {
        guardian = g;
        emit GuardianSet(g);
    }

    function pause(string calldata /*reason*/) external onlyOwnerOrGuardian {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    // --- admin ---
    function setNotifier(address n) external onlyOwner {
        notifier = n;
        emit NotifierSet(n);
    }

    // Owner sets allowed LP tokens (whitelist for standard/non-deflationary)
    function setAllowedLp(address lp, bool allowed) external onlyOwner {
        require(lp != address(0), "lp=0");
        allowedLp[lp] = allowed;
        emit AllowedLpSet(lp, allowed);
    }

    /**
     * @notice Add a supported reward token to the allowlist.
     * @dev Only standard ERC20 tokens (non-deflationary/rebase/fee-on-transfer) should be added.
     */
    function addSupportedReward(address reward) external onlyOwner {
        if (reward == address(0)) revert BadArg();
        if (supportedRewardTokens.length >= MAX_SUPPORTED_REWARDS) revert MaxRewards();
        if (isSupportedReward[reward]) return; // idempotent
        supportedRewardTokens.push(reward);
        isSupportedReward[reward] = true;
        if (!everSupportedReward[reward]) {
            allEverSupportedRewards.push(reward);
            everSupportedReward[reward] = true;
        }
        emit SupportedRewardAdded(reward);
    }

    function removeSupportedReward(uint256 index) external onlyOwner {
        if (index >= supportedRewardTokens.length) revert BadIndex();
        address reward = supportedRewardTokens[index];
        supportedRewardTokens[index] = supportedRewardTokens[supportedRewardTokens.length - 1];
        supportedRewardTokens.pop();
        isSupportedReward[reward] = false;
        emit SupportedRewardRemoved(reward);
    }

    function getSupportedRewardTokens() external view returns (address[] memory) {
        return supportedRewardTokens;
    }

    // --- helpers ---
    function _pair(address a, address b) internal view returns (address p) {
        p = factory.getPair(a, b);
        if (p == address(0)) p = factory.getPair(b, a);
    }

    function _rewardPerToken(address lp, address reward) internal view returns (uint256) {
        return rewardData[lp][reward].rewardPerTokenStored;
    }

    function earned(address user, address lp, address reward) external view returns (uint256) {
        if (!everSupportedReward[reward]) return 0;  // Block views for never-added
        uint256 rpt  = _rewardPerToken(lp, reward);
        uint256 paid = userPaidPerToken[lp][user][reward];
        uint256 bal  = balances[lp][user];
        return accrued[lp][user][reward] + (bal * (rpt - paid)) / 1e18;
    }

    // --- stake/withdraw ---
    function stake(address lp, uint256 amount) external nonReentrant whenNotPaused {
        if (amount == 0) revert BadArg();
        if (!allowedLp[lp]) revert UnsupportedLp();
        _settleAll(msg.sender, lp);

        uint256 balBefore = IERC20(lp).balanceOf(address(this));
        IERC20(lp).safeTransferFrom(msg.sender, address(this), amount);
        uint256 received = IERC20(lp).balanceOf(address(this)) - balBefore;

        if (received == 0) revert BadArg();
        balances[lp][msg.sender] += received;
        totalStaked[lp] += received;
        emit Staked(msg.sender, lp, received);

        _releaseQueued(lp);
    }

    function withdraw(address lp, uint256 amount) external nonReentrant whenNotPaused {
        if (amount == 0) revert BadArg();
        if (balances[lp][msg.sender] < amount) revert InsufficientBalance();
        _settleAll(msg.sender, lp);
        balances[lp][msg.sender] -= amount;
        totalStaked[lp] -= amount;
        IERC20(lp).safeTransfer(msg.sender, amount);
        emit Withdrawn(msg.sender, lp, amount);
    }

    // NOTE: claim remains available during pause to avoid trapping rewards
    function claim(address lp, address[] calldata rewards) external nonReentrant {
        for (uint i; i < rewards.length; i++) {
            address reward = rewards[i];
            if (!everSupportedReward[reward]) continue;
            _settleOne(msg.sender, lp, reward);
            uint256 a = accrued[lp][msg.sender][reward];
            if (a > 0) {
                accrued[lp][msg.sender][reward] = 0;
                IERC20(reward).safeTransfer(msg.sender, a);
                emit Claimed(msg.sender, lp, reward, a);
            }
        }
    }

    // --- executor hook ---
    // Matches ParagonPayflowExecutorV2: notify(tokenIn, tokenOut, rewardToken, amount)
    function notify(address tokenIn, address tokenOut, address rewardToken, uint256 amount)
        external
        override
        onlyNotifier
        nonReentrant
        whenNotPaused
    {
        if (!isSupportedReward[rewardToken]) revert UnsupportedReward();

        address lp = _pair(tokenIn, tokenOut);
        if (lp == address(0)) revert BadArg();
        if (!allowedLp[lp]) revert UnsupportedLp();

        uint256 balBefore = IERC20(rewardToken).balanceOf(address(this));
        IERC20(rewardToken).safeTransferFrom(msg.sender, address(this), amount);
        uint256 received = IERC20(rewardToken).balanceOf(address(this)) - balBefore;

        if (received == 0) return;

        RewardData storage R = rewardData[lp][rewardToken];
        uint256 ts = totalStaked[lp];
        uint256 scale = 1e18;
        if (ts == 0) {
            R.queued += received;
        } else {
            uint256 addedRPT = (received * scale) / ts;                // floor
            R.rewardPerTokenStored += addedRPT;
            uint256 consumed = (addedRPT * ts) / scale;                // exact amount represented
            uint256 leftover = received - consumed;                    // carry forward dust
            if (leftover > 0) R.queued += leftover;
        }

        emit Notified(lp, rewardToken, received);
    }

    // --- internals ---
    function _releaseQueued(address lp) internal {
        uint256 ts = totalStaked[lp];
        if (ts == 0) return;
        uint256 len = supportedRewardTokens.length;
        uint256 scale = 1e18;
        for (uint i; i < len; i++) {
            address reward = supportedRewardTokens[i];
            RewardData storage R = rewardData[lp][reward];
            uint256 q = R.queued;
            if (q > 0) {
                uint256 addedRPT = (q * scale) / ts;                   // floor
                if (addedRPT > 0) {
                    R.rewardPerTokenStored += addedRPT;
                    uint256 consumed = (addedRPT * ts) / scale;        // amount distributed
                    R.queued = q - consumed;                           // keep remainder
                }
            }
        }
    }

    function _settleAll(address user, address lp) internal {
        uint256 len = allEverSupportedRewards.length;
        for (uint i; i < len; i++) {
            _settleOne(user, lp, allEverSupportedRewards[i]);
        }
    }

    function _settleOne(address user, address lp, address reward) internal {
        uint256 rpt  = _rewardPerToken(lp, reward);
        uint256 paid = userPaidPerToken[lp][user][reward];
        if (rpt == paid) return;
        userPaidPerToken[lp][user][reward] = rpt;
        uint256 bal = balances[lp][user];
        if (bal > 0) {
            accrued[lp][user][reward] += (bal * (rpt - paid)) / 1e18;
        }
    }

    // emergency (owner) for stuck queued funds
    function emergencySweep(address lp, address reward, address to, uint256 amount) external onlyOwner {
        if (to == address(0)) revert BadArg();
        RewardData storage R = rewardData[lp][reward];
        if (amount > R.queued) amount = R.queued;        // cap to available queued
        if (amount == 0) return;
        R.queued -= amount;
        IERC20(reward).safeTransfer(to, amount);
        emit EmergencySwept(lp, reward, to, amount);
    }
}
