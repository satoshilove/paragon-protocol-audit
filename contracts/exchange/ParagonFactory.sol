// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import "./interfaces/IParagonFactory.sol";
import "./interfaces/IParagonPair.sol";
import { ParagonPair } from "./ParagonPair.sol";

/**
 * @title ParagonFactory
 * @dev Factory contract for creating ParagonPair liquidity pools
 *      - Global default swap fee (swapFeeBips)
 *      - Per-pair fee overrides (pairSwapFeeBips)
 *      - Auto-assign higher fees to non-core pairs at creation
 *        * Core/allowlisted pairs → use global default
 *        * One-base + one-nonbase → mid/high fee (nonBaseWithBaseFeeBips)
 *        * Nonbase + nonbase → high fee (nonBaseFeeBips)
 */
contract ParagonFactory is IParagonFactory, Ownable, Pausable, ReentrancyGuard {
    bytes32 public constant INIT_CODE_PAIR_HASH =
        keccak256(abi.encodePacked(type(ParagonPair).creationCode));

    // 1% hard ceiling — keeps all admin-settable fees bounded
    uint32 public constant MAX_FEE_BIPS = 100; // 1.00%

    /// @inheritdoc IParagonFactory
    address public override feeTo;
    /// @inheritdoc IParagonFactory
    address public override feeToSetter;

    /// @inheritdoc IParagonFactory
    uint32 public override swapFeeBips = 20; // 0.20% global default (can raise to 0.30% later)

    /// Optional: Library uses this to guard XPGN routes when paused.
    address public override xpgnToken;

    /// @inheritdoc IParagonFactory
    mapping(address => mapping(address => address)) public override getPair;
    /// @inheritdoc IParagonFactory
    address[] public override allPairs;
    /// quick lookup for pairs (not part of interface)
    mapping(address => bool) public isPair;

    // ─────────────────────── Dynamic-fee additions ───────────────────────

    /// Per-pair fee override in bips. 0 => use global swapFeeBips
    mapping(address => uint32) public pairSwapFeeBips;

    /// Base/core tokens (e.g., WBNB, USDT, XPGN). Configured by owner.
    mapping(address => bool) public baseToken;

    /// Specific allowlisted pairs (sorted token order). If true → use global default.
    mapping(bytes32 => bool) public allowlistedPair;

    /// Default policy for non-core pairs created by anyone:
    ///  (a) base+nonbase pairs (e.g., WBNB/NEW) → 0.35% by default
    ///  (b) nonbase+nonbase pairs (e.g., NEW1/NEW2) → 0.50% by default
    uint32 public nonBaseWithBaseFeeBips = 35; // 0.35%
    uint32 public nonBaseFeeBips        = 50; // 0.50%

    // ───────────────────────── Blacklist (existing) ──────────────────────
    mapping(address => bool) public tokenBlacklist;
    bool public blacklistEnabled; // defaults to false

    // ───────────────────────────── Events ────────────────────────────────
    event TokenBlacklisted(address indexed token);
    event TokenRemovedFromBlacklist(address indexed token);
    event BlacklistStatusUpdated(bool enabled);

    event PairSwapFeeUpdated(address indexed pair, uint32 bips);
    event DefaultFeePolicyUpdated(uint32 nonBaseWithBaseFeeBips, uint32 nonBaseFeeBips);
    event BaseTokenUpdated(address indexed token, bool isBase);
    event PairAllowlistUpdated(address indexed token0, address indexed token1, bool allowed);

    // Raised when a new pair is created and an initial fee is auto-applied
    // category: 0=allowlist/core, 1=base+nonbase, 2=nonbase+nonbase
    event PairAutoFeeApplied(address indexed pair, uint32 bips, uint8 category);

    // ─────────────────────────── Modifiers ───────────────────────────────
    modifier onlyFeeToSetter() {
        require(msg.sender == feeToSetter, "Paragon: FORBIDDEN");
        _;
    }

    constructor(address _feeToSetter, address _xpgnToken) Ownable(msg.sender) {
        require(_feeToSetter != address(0), "Paragon: INVALID_FEE_TO_SETTER");
        feeToSetter = _feeToSetter;
        xpgnToken = _xpgnToken; // can be address(0) to disable special handling
        blacklistEnabled = false; // explicit default off
    }

    /// @inheritdoc IParagonFactory
    function allPairsLength() external view override returns (uint256) {
        return allPairs.length;
    }

    // ───────────────────── Helper: pair key for allowlist ─────────────────────
    function _pairKey(address tokenA, address tokenB) internal pure returns (bytes32) {
        (address t0, address t1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        return keccak256(abi.encodePacked(t0, t1));
    }

    // View: what fee would we assign by policy if this pair were created now?
    function calculateInitialPairFeeBips(address tokenA, address tokenB) public view returns (uint32 bips, uint8 category) {
        bytes32 key = _pairKey(tokenA, tokenB);

        // 0) explicit allowlist → use global default
        if (allowlistedPair[key]) {
            return (0, 0);
        }

        // 1) both tokens are base/core → use global default
        if (baseToken[tokenA] && baseToken[tokenB]) {
            return (0, 0);
        }

        // 2) exactly one base token → mid/high default
        if (baseToken[tokenA] || baseToken[tokenB]) {
            return (nonBaseWithBaseFeeBips, 1);
        }

        // 3) no base tokens → highest default
        return (nonBaseFeeBips, 2);
    }

    /// @inheritdoc IParagonFactory
    function createPair(address tokenA, address tokenB)
        external
        override
        nonReentrant
        whenNotPaused
        returns (address pair)
    {
        require(tokenA != tokenB, "Paragon: IDENTICAL_ADDRESSES");
        require(tokenA != address(0) && tokenB != address(0), "Paragon: ZERO_ADDRESS");
        require(getPair[tokenA][tokenB] == address(0), "Paragon: PAIR_EXISTS");
        require(!isBlacklisted(tokenA) && !isBlacklisted(tokenB), "Paragon: BLACKLISTED_TOKEN");

        _validateToken(tokenA);
        _validateToken(tokenB);

        (address token0, address token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        require(token0 != address(0) && token1 != address(0), "Paragon: ZERO_ADDRESS_SORTED");

        bytes memory bytecode = type(ParagonPair).creationCode;
        bytes32 salt = keccak256(abi.encodePacked(token0, token1));

        assembly {
            pair := create2(0, add(bytecode, 32), mload(bytecode), salt)
        }
        require(pair != address(0), "Paragon: PAIR_CREATION_FAILED");

        IParagonPair(pair).initialize(token0, token1);

        getPair[token0][token1] = pair;
        getPair[token1][token0] = pair;
        isPair[pair] = true;
        allPairs.push(pair);

        // Apply initial dynamic fee policy
        (uint32 initBips, uint8 category) = calculateInitialPairFeeBips(token0, token1);
        if (initBips > 0) {
            // store per-pair override (0 means "use global")
            pairSwapFeeBips[pair] = initBips;
            emit PairSwapFeeUpdated(pair, initBips);
        }
        emit PairAutoFeeApplied(pair, initBips, category);

        emit PairCreated(token0, token1, pair, allPairs.length);
    }

    // ───────────────────────── Fee admin (global & per-pair) ─────────────────────────

    /// Global default swap fee (applies when per-pair override is 0)
    function setSwapFee(uint32 _swapFeeBips) external override onlyFeeToSetter {
        require(_swapFeeBips <= MAX_FEE_BIPS, "Paragon: FEE_TOO_HIGH");
        swapFeeBips = _swapFeeBips;
        emit SwapFeeUpdated(_swapFeeBips);
    }

    /// Set or clear a per-pair override. 0 => use global default.
    function setPairSwapFee(address pair, uint32 bips) external onlyFeeToSetter {
        require(isPair[pair], "Paragon: NOT_PAIR");
        require(bips <= MAX_FEE_BIPS, "Paragon: FEE_TOO_HIGH");
        pairSwapFeeBips[pair] = bips; // 0 allowed
        emit PairSwapFeeUpdated(pair, bips);
    }

    /// Effective fee the Pair/Library should use for a given pair.
    function getEffectiveSwapFeeBips(address pair) external view returns (uint32) {
        uint32 b = pairSwapFeeBips[pair];
        if (b != 0) return b; // explicit override takes priority

        // Dynamic policy fallback (no override): compute from tokens + allowlist
        address t0 = IParagonPair(pair).token0();
        address t1 = IParagonPair(pair).token1();
        bytes32 key = keccak256(abi.encodePacked(t0, t1));

        // allowlisted or both base → global default
        if (allowlistedPair[key] || (baseToken[t0] && baseToken[t1])) {
            return swapFeeBips;
        }
        // exactly one base → mid/high default
        if (baseToken[t0] || baseToken[t1]) {
            return nonBaseWithBaseFeeBips;
        }
        // neither base → highest default
        return nonBaseFeeBips;
    }

    /// Update default policy for automatically assigned higher fees on new pairs.
    function setDefaultNonBaseFees(uint32 _nonBaseWithBaseFeeBips, uint32 _nonBaseFeeBips) external onlyFeeToSetter {
        require(_nonBaseWithBaseFeeBips <= MAX_FEE_BIPS, "Paragon: FEE_TOO_HIGH");
        require(_nonBaseFeeBips        <= MAX_FEE_BIPS, "Paragon: FEE_TOO_HIGH");
        nonBaseWithBaseFeeBips = _nonBaseWithBaseFeeBips;
        nonBaseFeeBips = _nonBaseFeeBips;
        emit DefaultFeePolicyUpdated(_nonBaseWithBaseFeeBips, _nonBaseFeeBips);
    }

    /// Mark/unmark a token as base/core (e.g., WBNB, USDT, XPGN)
    function setBaseToken(address token, bool isBase) external onlyOwner {
        require(token != address(0), "Paragon: ZERO_ADDRESS");
        baseToken[token] = isBase;
        emit BaseTokenUpdated(token, isBase);
    }

    function setBaseTokens(address[] calldata tokens, bool[] calldata flags) external onlyOwner {
        require(tokens.length == flags.length, "Paragon: LEN_MISMATCH");
        for (uint i = 0; i < tokens.length; i++) {
            address t = tokens[i];
            require(t != address(0), "Paragon: ZERO_ADDRESS");
            baseToken[t] = flags[i];
            emit BaseTokenUpdated(t, flags[i]);
        }
    }

    /// Allowlist a specific pair (by tokens) to always use global default
    function setPairAllowlist(address tokenA, address tokenB, bool allowed) external onlyOwner {
        bytes32 key = _pairKey(tokenA, tokenB);
        allowlistedPair[key] = allowed;
        (address t0, address t1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        emit PairAllowlistUpdated(t0, t1, allowed);
    }

    function clearPairSwapFee(address pair) external onlyFeeToSetter {
        require(isPair[pair], "Paragon: NOT_PAIR");
        pairSwapFeeBips[pair] = 0;
        emit PairSwapFeeUpdated(pair, 0);
    }

    // ───────────────────────── FeeTo / setters (existing) ─────────────────────────

    function setFeeTo(address _feeTo) external override onlyFeeToSetter {
        feeTo = _feeTo;
        emit FeeToUpdated(_feeTo);
    }

    function setFeeToSetter(address _feeToSetter) external override onlyFeeToSetter {
        require(_feeToSetter != address(0), "Paragon: INVALID_ADDRESS");
        feeToSetter = _feeToSetter;
        emit FeeToSetterUpdated(_feeToSetter);
    }

    /// Owner can update the XPGN token (used by Library for pause guard)
    function setXPGNToken(address _xpgnToken) external onlyOwner {
        xpgnToken = _xpgnToken;
        emit XPGNTokenUpdated(_xpgnToken);
    }

    // ───────────────────────── Blacklist controls (existing) ─────────────────────────

    function setBlacklistEnabled(bool _enabled) external onlyOwner {
        blacklistEnabled = _enabled;
        emit BlacklistStatusUpdated(_enabled);
    }

    function addToBlacklist(address token) external onlyOwner {
        require(token != address(0), "Paragon: ZERO_ADDRESS");
        tokenBlacklist[token] = true;
        emit TokenBlacklisted(token);
    }

    function removeFromBlacklist(address token) external onlyOwner {
        require(token != address(0), "Paragon: ZERO_ADDRESS");
        tokenBlacklist[token] = false;
        emit TokenRemovedFromBlacklist(token);
    }

    function isBlacklisted(address token) public view returns (bool) {
        return blacklistEnabled && tokenBlacklist[token];
    }

    // ───────────────────────── Pause (existing) ─────────────────────────

    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }

    // ───────────────────────── Helpers (existing) ─────────────────────────

    function getPairs(uint256 start, uint256 limit)
        external
        view
        returns (address[] memory pairs)
    {
        if (start >= allPairs.length) {
            return new address[](0);
        }
        uint256 end = start + limit > allPairs.length ? allPairs.length : start + limit;
        pairs = new address[](end - start);
        for (uint256 i = start; i < end; i++) {
            pairs[i - start] = allPairs[i];
        }
    }

    // ───────────────────────── Internal sanity checks (existing) ─────────────────────────

    function _validateToken(address token) internal view {
        require(token.code.length > 0, "Paragon: NOT_CONTRACT");
        try IERC20Metadata(token).decimals() returns (uint8 decimals) {
            require(decimals <= 18, "Paragon: INVALID_DECIMALS");
        } catch {
            revert("Paragon: INVALID_TOKEN");
        }
        try IERC20Metadata(token).symbol() returns (string memory symbol) {
            require(bytes(symbol).length > 0, "Paragon: NO_SYMBOL");
        } catch {
            revert("Paragon: NO_SYMBOL");
        }
    }
}