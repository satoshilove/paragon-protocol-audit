// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.25;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title ParagonMultiTokenFaucet
 * @notice Testnet faucet for Paragon mock assets.
 * @dev
 * - Supports many tokens in one contract
 * - Optional whitelist-only launch window
 * - Per-token:
 *   - enabled/disabled
 *   - amount per claim
 *   - cooldown
 *   - max per wallet per day
 * - Two separate optional bundle claims
 * - Admin can batch whitelist users and update configs live
 * - Seed by simply transferring tokens into this contract
 */
contract ParagonMultiTokenFaucet is Ownable, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 public constant DAY = 1 days;
    uint256 public constant MAX_BUNDLE_TOKENS = 32;

    uint8 public constant BUNDLE_NONE = 0;
    uint8 public constant BUNDLE_A = 1;
    uint8 public constant BUNDLE_B = 2;

    struct TokenConfig {
        bool supported;
        bool enabled;
        uint256 amountPerClaim;
        uint256 cooldown;
        uint256 maxPerWalletPerDay;
    }

    // token => config
    mapping(address => TokenConfig) public tokenConfigs;

    // supported token registry
    address[] public supportedTokens;
    mapping(address => bool) public isSupportedToken;

    // whitelist
    bool public whitelistEnabled;
    uint256 public whitelistEndsAt;
    mapping(address => bool) public whitelist;

    // -------------------------
    // Bundle A
    // -------------------------
    bool public bundleAEnabled = true;
    address[] public bundleATokens;
    mapping(address => bool) public isBundleAToken;

    mapping(address => uint256) public lastBundleAClaimAt;
    mapping(address => uint256) public bundleAClaimedDayIndex;
    mapping(address => uint256) public bundleAClaimsToday;

    uint256 public bundleACooldown = 1 days;
    uint256 public maxBundleAClaimsPerDay = 1;

    // -------------------------
    // Bundle B
    // -------------------------
    bool public bundleBEnabled = true;
    address[] public bundleBTokens;
    mapping(address => bool) public isBundleBToken;

    mapping(address => uint256) public lastBundleBClaimAt;
    mapping(address => uint256) public bundleBClaimedDayIndex;
    mapping(address => uint256) public bundleBClaimsToday;

    uint256 public bundleBCooldown = 1 days;
    uint256 public maxBundleBClaimsPerDay = 1;

    // token => bundle kind
    mapping(address => uint8) public bundleKindOf;

    // claim tracking
    // user => token => last claim timestamp
    mapping(address => mapping(address => uint256)) public lastClaimAt;

    // user => token => day index => claimed amount
    mapping(address => mapping(address => uint256)) public claimedDayIndex;
    mapping(address => mapping(address => uint256)) public claimedAmountToday;

    event TokenSupported(
        address indexed token,
        bool enabled,
        uint256 amountPerClaim,
        uint256 cooldown,
        uint256 maxPerWalletPerDay
    );
    event TokenConfigUpdated(
        address indexed token,
        bool enabled,
        uint256 amountPerClaim,
        uint256 cooldown,
        uint256 maxPerWalletPerDay
    );
    event TokenRemoved(address indexed token);

    event TokenClaimed(address indexed user, address indexed token, uint256 amount);

    event BundleAClaimed(address indexed user, uint256 tokenCount);
    event BundleBClaimed(address indexed user, uint256 tokenCount);

    event WhitelistUpdated(address indexed user, bool allowed);
    event WhitelistBatchUpdated(uint256 count, bool allowed);
    event WhitelistWindowUpdated(bool enabled, uint256 endsAt);

    event BundleAStatusUpdated(bool enabled);
    event BundleBStatusUpdated(bool enabled);

    event BundleAPolicyUpdated(uint256 cooldown, uint256 maxClaimsPerDay);
    event BundleBPolicyUpdated(uint256 cooldown, uint256 maxClaimsPerDay);

    event BundleAssignmentUpdated(address indexed token, uint8 bundleKind);

    event Rescue(address indexed token, address indexed to, uint256 amount);

    error NotWhitelisted();
    error UnsupportedToken();
    error TokenDisabled();
    error CooldownActive();
    error DailyLimitExceeded();
    error FaucetEmpty();
    error BundleDisabled();
    error InvalidToken();
    error InvalidRecipient();
    error DuplicateToken();
    error TooManyBundleTokens();
    error InvalidBundleKind();

    constructor(address initialOwner) Ownable(initialOwner) {
        require(initialOwner != address(0), "zero owner");
    }

    // -------------------------------------------------
    // Views
    // -------------------------------------------------

    function supportedTokensLength() external view returns (uint256) {
        return supportedTokens.length;
    }

    function bundleATokensLength() external view returns (uint256) {
        return bundleATokens.length;
    }

    function bundleBTokensLength() external view returns (uint256) {
        return bundleBTokens.length;
    }

    /// @notice Legacy helper: total raw entries across both bundle arrays
    function bundleTokensLength() external view returns (uint256) {
        return bundleATokens.length + bundleBTokens.length;
    }

    function whitelistRequired() public view returns (bool) {
        return whitelistEnabled && block.timestamp < whitelistEndsAt;
    }

    function currentDayIndex() public view returns (uint256) {
        return block.timestamp / DAY;
    }

    function canClaimToken(address user, address token) external view returns (
        bool ok,
        string memory reason,
        uint256 nextClaimAt,
        uint256 remainingToday
    ) {
        if (whitelistRequired() && !whitelist[user]) {
            return (false, "NOT_WHITELISTED", 0, 0);
        }

        TokenConfig memory cfg = tokenConfigs[token];
        if (!cfg.supported) {
            return (false, "UNSUPPORTED_TOKEN", 0, 0);
        }
        if (!cfg.enabled) {
            return (false, "TOKEN_DISABLED", 0, 0);
        }

        uint256 last = lastClaimAt[user][token];
        if (cfg.cooldown > 0 && block.timestamp < last + cfg.cooldown) {
            return (false, "COOLDOWN_ACTIVE", last + cfg.cooldown, 0);
        }

        uint256 dayIdx = currentDayIndex();
        uint256 alreadyClaimed = claimedDayIndex[user][token] == dayIdx
            ? claimedAmountToday[user][token]
            : 0;

        if (alreadyClaimed >= cfg.maxPerWalletPerDay) {
            return (false, "DAILY_LIMIT_REACHED", 0, 0);
        }

        uint256 remaining = cfg.maxPerWalletPerDay - alreadyClaimed;
        if (remaining < cfg.amountPerClaim) {
            return (false, "INSUFFICIENT_DAILY_HEADROOM", 0, remaining);
        }

        uint256 bal = IERC20(token).balanceOf(address(this));
        if (bal < cfg.amountPerClaim) {
            return (false, "FAUCET_EMPTY", 0, remaining);
        }

        return (true, "", 0, remaining);
    }

    function canClaimBundleA(address user) external view returns (
        bool ok,
        string memory reason,
        uint256 nextClaimAt
    ) {
        if (!bundleAEnabled) {
            return (false, "BUNDLE_A_DISABLED", 0);
        }

        if (whitelistRequired() && !whitelist[user]) {
            return (false, "NOT_WHITELISTED", 0);
        }

        if (bundleACooldown > 0 && block.timestamp < lastBundleAClaimAt[user] + bundleACooldown) {
            return (false, "BUNDLE_A_COOLDOWN_ACTIVE", lastBundleAClaimAt[user] + bundleACooldown);
        }

        uint256 dayIdx = currentDayIndex();
        uint256 claimsToday = bundleAClaimedDayIndex[user] == dayIdx ? bundleAClaimsToday[user] : 0;
        if (claimsToday >= maxBundleAClaimsPerDay) {
            return (false, "BUNDLE_A_DAILY_LIMIT", 0);
        }

        return (true, "", 0);
    }

    function canClaimBundleB(address user) external view returns (
        bool ok,
        string memory reason,
        uint256 nextClaimAt
    ) {
        if (!bundleBEnabled) {
            return (false, "BUNDLE_B_DISABLED", 0);
        }

        if (whitelistRequired() && !whitelist[user]) {
            return (false, "NOT_WHITELISTED", 0);
        }

        if (bundleBCooldown > 0 && block.timestamp < lastBundleBClaimAt[user] + bundleBCooldown) {
            return (false, "BUNDLE_B_COOLDOWN_ACTIVE", lastBundleBClaimAt[user] + bundleBCooldown);
        }

        uint256 dayIdx = currentDayIndex();
        uint256 claimsToday = bundleBClaimedDayIndex[user] == dayIdx ? bundleBClaimsToday[user] : 0;
        if (claimsToday >= maxBundleBClaimsPerDay) {
            return (false, "BUNDLE_B_DAILY_LIMIT", 0);
        }

        return (true, "", 0);
    }

    /// @notice Legacy helper for backward compatibility.
    /// Returns Bundle A status.
    function canClaimBundle(address user) external view returns (
        bool ok,
        string memory reason,
        uint256 nextClaimAt
    ) {
        if (!bundleAEnabled) {
            return (false, "BUNDLE_A_DISABLED", 0);
        }

        if (whitelistRequired() && !whitelist[user]) {
            return (false, "NOT_WHITELISTED", 0);
        }

        if (bundleACooldown > 0 && block.timestamp < lastBundleAClaimAt[user] + bundleACooldown) {
            return (false, "BUNDLE_A_COOLDOWN_ACTIVE", lastBundleAClaimAt[user] + bundleACooldown);
        }

        uint256 dayIdx = currentDayIndex();
        uint256 claimsToday = bundleAClaimedDayIndex[user] == dayIdx ? bundleAClaimsToday[user] : 0;
        if (claimsToday >= maxBundleAClaimsPerDay) {
            return (false, "BUNDLE_A_DAILY_LIMIT", 0);
        }

        return (true, "", 0);
    }

    // -------------------------------------------------
    // Claim
    // -------------------------------------------------

    function claimToken(address token) external nonReentrant whenNotPaused {
        _enforceWhitelist(msg.sender);

        TokenConfig memory cfg = tokenConfigs[token];
        if (!cfg.supported) revert UnsupportedToken();
        if (!cfg.enabled) revert TokenDisabled();

        _consumeTokenClaim(msg.sender, token, cfg);
        IERC20(token).safeTransfer(msg.sender, cfg.amountPerClaim);

        emit TokenClaimed(msg.sender, token, cfg.amountPerClaim);
    }

    function claimBundleA() external nonReentrant whenNotPaused {
        if (!bundleAEnabled) revert BundleDisabled();
        _enforceWhitelist(msg.sender);

        if (bundleACooldown > 0 && block.timestamp < lastBundleAClaimAt[msg.sender] + bundleACooldown) {
            revert CooldownActive();
        }

        uint256 dayIdx = currentDayIndex();
        if (bundleAClaimedDayIndex[msg.sender] != dayIdx) {
            bundleAClaimedDayIndex[msg.sender] = dayIdx;
            bundleAClaimsToday[msg.sender] = 0;
        }

        if (bundleAClaimsToday[msg.sender] >= maxBundleAClaimsPerDay) {
            revert DailyLimitExceeded();
        }

        uint256 len = bundleATokens.length;
        require(len > 0, "empty bundle A");

        uint256 claimedCount = 0;
        for (uint256 i = 0; i < len; i++) {
            address token = bundleATokens[i];
            if (!isBundleAToken[token]) continue;

            TokenConfig memory cfg = tokenConfigs[token];
            if (!cfg.supported || !cfg.enabled) continue;

            _consumeTokenClaim(msg.sender, token, cfg);
            IERC20(token).safeTransfer(msg.sender, cfg.amountPerClaim);

            claimedCount += 1;
            emit TokenClaimed(msg.sender, token, cfg.amountPerClaim);
        }

        lastBundleAClaimAt[msg.sender] = block.timestamp;
        bundleAClaimsToday[msg.sender] += 1;

        emit BundleAClaimed(msg.sender, claimedCount);
    }

    function claimBundleB() external nonReentrant whenNotPaused {
        if (!bundleBEnabled) revert BundleDisabled();
        _enforceWhitelist(msg.sender);

        if (bundleBCooldown > 0 && block.timestamp < lastBundleBClaimAt[msg.sender] + bundleBCooldown) {
            revert CooldownActive();
        }

        uint256 dayIdx = currentDayIndex();
        if (bundleBClaimedDayIndex[msg.sender] != dayIdx) {
            bundleBClaimedDayIndex[msg.sender] = dayIdx;
            bundleBClaimsToday[msg.sender] = 0;
        }

        if (bundleBClaimsToday[msg.sender] >= maxBundleBClaimsPerDay) {
            revert DailyLimitExceeded();
        }

        uint256 len = bundleBTokens.length;
        require(len > 0, "empty bundle B");

        uint256 claimedCount = 0;
        for (uint256 i = 0; i < len; i++) {
            address token = bundleBTokens[i];
            if (!isBundleBToken[token]) continue;

            TokenConfig memory cfg = tokenConfigs[token];
            if (!cfg.supported || !cfg.enabled) continue;

            _consumeTokenClaim(msg.sender, token, cfg);
            IERC20(token).safeTransfer(msg.sender, cfg.amountPerClaim);

            claimedCount += 1;
            emit TokenClaimed(msg.sender, token, cfg.amountPerClaim);
        }

        lastBundleBClaimAt[msg.sender] = block.timestamp;
        bundleBClaimsToday[msg.sender] += 1;

        emit BundleBClaimed(msg.sender, claimedCount);
    }

    /// @notice Legacy helper for backward compatibility. Routes to Bundle A.
    function claimBundle() external nonReentrant whenNotPaused {
        if (!bundleAEnabled) revert BundleDisabled();
        _enforceWhitelist(msg.sender);

        if (bundleACooldown > 0 && block.timestamp < lastBundleAClaimAt[msg.sender] + bundleACooldown) {
            revert CooldownActive();
        }

        uint256 dayIdx = currentDayIndex();
        if (bundleAClaimedDayIndex[msg.sender] != dayIdx) {
            bundleAClaimedDayIndex[msg.sender] = dayIdx;
            bundleAClaimsToday[msg.sender] = 0;
        }

        if (bundleAClaimsToday[msg.sender] >= maxBundleAClaimsPerDay) {
            revert DailyLimitExceeded();
        }

        uint256 len = bundleATokens.length;
        require(len > 0, "empty bundle A");

        uint256 claimedCount = 0;
        for (uint256 i = 0; i < len; i++) {
            address token = bundleATokens[i];
            if (!isBundleAToken[token]) continue;

            TokenConfig memory cfg = tokenConfigs[token];
            if (!cfg.supported || !cfg.enabled) continue;

            _consumeTokenClaim(msg.sender, token, cfg);
            IERC20(token).safeTransfer(msg.sender, cfg.amountPerClaim);

            claimedCount += 1;
            emit TokenClaimed(msg.sender, token, cfg.amountPerClaim);
        }

        lastBundleAClaimAt[msg.sender] = block.timestamp;
        bundleAClaimsToday[msg.sender] += 1;

        emit BundleAClaimed(msg.sender, claimedCount);
    }

    function _consumeTokenClaim(address user, address token, TokenConfig memory cfg) internal {
        uint256 last = lastClaimAt[user][token];
        if (cfg.cooldown > 0 && block.timestamp < last + cfg.cooldown) {
            revert CooldownActive();
        }

        uint256 dayIdx = currentDayIndex();
        if (claimedDayIndex[user][token] != dayIdx) {
            claimedDayIndex[user][token] = dayIdx;
            claimedAmountToday[user][token] = 0;
        }

        uint256 newClaimed = claimedAmountToday[user][token] + cfg.amountPerClaim;
        if (newClaimed > cfg.maxPerWalletPerDay) {
            revert DailyLimitExceeded();
        }

        uint256 bal = IERC20(token).balanceOf(address(this));
        if (bal < cfg.amountPerClaim) revert FaucetEmpty();

        claimedAmountToday[user][token] = newClaimed;
        lastClaimAt[user][token] = block.timestamp;
    }

    function _enforceWhitelist(address user) internal view {
        if (whitelistRequired() && !whitelist[user]) {
            revert NotWhitelisted();
        }
    }

    // -------------------------------------------------
    // Admin: token config
    // -------------------------------------------------

    function addSupportedToken(
        address token,
        bool enabled,
        uint256 amountPerClaim,
        uint256 cooldown,
        uint256 maxPerWalletPerDay
    ) external onlyOwner {
        if (token == address(0)) revert InvalidToken();
        if (isSupportedToken[token]) revert DuplicateToken();
        require(amountPerClaim > 0, "amount=0");
        require(maxPerWalletPerDay >= amountPerClaim, "daily<claim");

        tokenConfigs[token] = TokenConfig({
            supported: true,
            enabled: enabled,
            amountPerClaim: amountPerClaim,
            cooldown: cooldown,
            maxPerWalletPerDay: maxPerWalletPerDay
        });

        isSupportedToken[token] = true;
        supportedTokens.push(token);

        emit TokenSupported(token, enabled, amountPerClaim, cooldown, maxPerWalletPerDay);
    }

    function updateTokenConfig(
        address token,
        bool enabled,
        uint256 amountPerClaim,
        uint256 cooldown,
        uint256 maxPerWalletPerDay
    ) external onlyOwner {
        if (!isSupportedToken[token]) revert UnsupportedToken();
        require(amountPerClaim > 0, "amount=0");
        require(maxPerWalletPerDay >= amountPerClaim, "daily<claim");

        tokenConfigs[token] = TokenConfig({
            supported: true,
            enabled: enabled,
            amountPerClaim: amountPerClaim,
            cooldown: cooldown,
            maxPerWalletPerDay: maxPerWalletPerDay
        });

        emit TokenConfigUpdated(token, enabled, amountPerClaim, cooldown, maxPerWalletPerDay);
    }

    function addSupportedTokensBatch(
        address[] calldata tokens,
        bool[] calldata enabledFlags,
        uint256[] calldata amountsPerClaim,
        uint256[] calldata cooldowns,
        uint256[] calldata maxPerWalletPerDays
    ) external onlyOwner {
        uint256 len = tokens.length;
        require(
            len == enabledFlags.length &&
            len == amountsPerClaim.length &&
            len == cooldowns.length &&
            len == maxPerWalletPerDays.length,
            "length mismatch"
        );

        for (uint256 i = 0; i < len; i++) {
            if (tokens[i] == address(0)) revert InvalidToken();
            if (isSupportedToken[tokens[i]]) revert DuplicateToken();
            require(amountsPerClaim[i] > 0, "amount=0");
            require(maxPerWalletPerDays[i] >= amountsPerClaim[i], "daily<claim");

            tokenConfigs[tokens[i]] = TokenConfig({
                supported: true,
                enabled: enabledFlags[i],
                amountPerClaim: amountsPerClaim[i],
                cooldown: cooldowns[i],
                maxPerWalletPerDay: maxPerWalletPerDays[i]
            });

            isSupportedToken[tokens[i]] = true;
            supportedTokens.push(tokens[i]);

            emit TokenSupported(
                tokens[i],
                enabledFlags[i],
                amountsPerClaim[i],
                cooldowns[i],
                maxPerWalletPerDays[i]
            );
        }
    }

    // -------------------------------------------------
    // Admin: whitelist
    // -------------------------------------------------

    function setWhitelist(address user, bool allowed) external onlyOwner {
        whitelist[user] = allowed;
        emit WhitelistUpdated(user, allowed);
    }

    function setWhitelistBatch(address[] calldata users, bool allowed) external onlyOwner {
        for (uint256 i = 0; i < users.length; i++) {
            whitelist[users[i]] = allowed;
            emit WhitelistUpdated(users[i], allowed);
        }
        emit WhitelistBatchUpdated(users.length, allowed);
    }

    function setWhitelistWindow(bool enabled, uint256 endsAt) external onlyOwner {
        whitelistEnabled = enabled;
        whitelistEndsAt = endsAt;
        emit WhitelistWindowUpdated(enabled, endsAt);
    }

    // -------------------------------------------------
    // Admin: bundles
    // -------------------------------------------------

    function setBundleAEnabled(bool enabled) external onlyOwner {
        bundleAEnabled = enabled;
        emit BundleAStatusUpdated(enabled);
    }

    function setBundleBEnabled(bool enabled) external onlyOwner {
        bundleBEnabled = enabled;
        emit BundleBStatusUpdated(enabled);
    }

    /// @notice Legacy helper. Routes to Bundle A.
    function setBundleEnabled(bool enabled) external onlyOwner {
        bundleAEnabled = enabled;
        emit BundleAStatusUpdated(enabled);
    }

    function setBundleAPolicy(uint256 cooldown, uint256 maxClaimsPerDay) external onlyOwner {
        require(maxClaimsPerDay > 0, "claims=0");
        bundleACooldown = cooldown;
        maxBundleAClaimsPerDay = maxClaimsPerDay;
        emit BundleAPolicyUpdated(cooldown, maxClaimsPerDay);
    }

    function setBundleBPolicy(uint256 cooldown, uint256 maxClaimsPerDay) external onlyOwner {
        require(maxClaimsPerDay > 0, "claims=0");
        bundleBCooldown = cooldown;
        maxBundleBClaimsPerDay = maxClaimsPerDay;
        emit BundleBPolicyUpdated(cooldown, maxClaimsPerDay);
    }

    /// @notice Legacy helper. Routes to Bundle A.
    function setBundlePolicy(uint256 cooldown, uint256 maxClaimsPerDay) external onlyOwner {
        require(maxClaimsPerDay > 0, "claims=0");
        bundleACooldown = cooldown;
        maxBundleAClaimsPerDay = maxClaimsPerDay;
        emit BundleAPolicyUpdated(cooldown, maxClaimsPerDay);
    }

    /**
     * @notice Assign token to a bundle.
     * @param token Supported token address
     * @param bundleKind 0 = none, 1 = bundle A, 2 = bundle B
     */
    function setBundleToken(address token, uint8 bundleKind) external onlyOwner {
        _setBundleToken(token, bundleKind);
    }

    function setBundleTokensBatch(address[] calldata tokens, uint8 bundleKind) external onlyOwner {
        for (uint256 i = 0; i < tokens.length; i++) {
            _setBundleToken(tokens[i], bundleKind);
        }
    }

    function _setBundleToken(address token, uint8 bundleKind) internal {
        if (!isSupportedToken[token]) revert UnsupportedToken();
        if (bundleKind > BUNDLE_B) revert InvalidBundleKind();

        uint8 current = bundleKindOf[token];
        if (current == bundleKind) {
            emit BundleAssignmentUpdated(token, bundleKind);
            return;
        }

        // remove from old bundle
        if (current == BUNDLE_A) {
            isBundleAToken[token] = false;
        } else if (current == BUNDLE_B) {
            isBundleBToken[token] = false;
        }

        // add to new bundle
        if (bundleKind == BUNDLE_A) {
            if (!isBundleAToken[token]) {
                if (!_existsInArray(bundleATokens, token)) {
                    if (bundleATokens.length >= MAX_BUNDLE_TOKENS) revert TooManyBundleTokens();
                    bundleATokens.push(token);
                }
                isBundleAToken[token] = true;
            }
        } else if (bundleKind == BUNDLE_B) {
            if (!isBundleBToken[token]) {
                if (!_existsInArray(bundleBTokens, token)) {
                    if (bundleBTokens.length >= MAX_BUNDLE_TOKENS) revert TooManyBundleTokens();
                    bundleBTokens.push(token);
                }
                isBundleBToken[token] = true;
            }
        }

        bundleKindOf[token] = bundleKind;
        emit BundleAssignmentUpdated(token, bundleKind);
    }

    function _existsInArray(address[] storage arr, address token) internal view returns (bool) {
        uint256 len = arr.length;
        for (uint256 i = 0; i < len; i++) {
            if (arr[i] == token) return true;
        }
        return false;
    }

    // -------------------------------------------------
    // Admin: safety
    // -------------------------------------------------

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    function rescue(address token, address to, uint256 amount) external onlyOwner {
        if (to == address(0)) revert InvalidRecipient();
        IERC20(token).safeTransfer(to, amount);
        emit Rescue(token, to, amount);
    }

    // -------------------------------------------------
    // Optional helper for UI
    // -------------------------------------------------

    /// @notice Legacy helper: returns whether token is in any bundle.
    function tokenMeta(address token) external view returns (
        string memory symbol,
        uint8 decimals,
        uint256 balance,
        TokenConfig memory cfg,
        bool inBundle
    ) {
        symbol = IERC20Metadata(token).symbol();
        decimals = IERC20Metadata(token).decimals();
        balance = IERC20(token).balanceOf(address(this));
        cfg = tokenConfigs[token];
        inBundle = bundleKindOf[token] != BUNDLE_NONE;
    }

    /// @notice New helper: includes exact bundle kind.
    function tokenMetaV2(address token) external view returns (
        string memory symbol,
        uint8 decimals,
        uint256 balance,
        TokenConfig memory cfg,
        uint8 bundleKind
    ) {
        symbol = IERC20Metadata(token).symbol();
        decimals = IERC20Metadata(token).decimals();
        balance = IERC20(token).balanceOf(address(this));
        cfg = tokenConfigs[token];
        bundleKind = bundleKindOf[token];
    }
}
