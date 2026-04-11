// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {P10Token} from "./P10Token.sol";
import {IP10Router, IP10Pricing} from "./interfaces/IP10Core.sol";

/**
 * @title P10IndexManager
 * @notice Manages composition, NAV, and mint/redeem for Paragon P10.
 *
 * Design notes:
 * - This contract does NOT modify your DEX contracts.
 * - It only:
 *     - Reads safe prices from IP10Pricing (your existing oracle module).
 *     - Calls router via IP10Router (your existing Flow router / adapter).
 * - Backing options:
 *     - Testnet synthetic: off-chain keeper tracks a backing basket within a band.
 *     - Mainnet basket-backed: this contract (or a dedicated vault) holds constituents.
 *
 * Security model:
 * - Mint only allowed when all IP10Pricing feeds return isSafe == true.
 * - NAV is computed from the target composition snapshot, not current holdings.
 * - Mint caps & pause protect against runaway supply growth.
 *
 * Invariants (high level):
 * - Backing value >= (totalSupply * NAV / 1e18), modulo Flow rebalance lag.
 * - Pro-rata redeem preserves per-share backing.
 * - Fees are minted with equivalent backing allocation (no dilution).
 */
contract P10IndexManager is Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ========= Structs & Storage =========

    /**
     * @dev Per-constituent asset data at a snapshot.
     *
     * fields:
     * - token:          ERC20 address
     * - decimals:       token decimals (cached)
     * - unitsPerP10E18: how many token units correspond to 1 P10 at this snapshot,
     *                   scaled by 1e18 (fractional units safe).
     */
    struct Asset {
        address token;
        uint8 decimals;
        uint96 unitsPerP10E18;
    }

    /// @notice Current active snapshot id (monotonic).
    uint256 public snapshotId;

    /// @dev snapshotId => list of assets.
    mapping(uint256 => Asset[]) internal _snapshots;

    /// @notice P10 index token.
    P10Token public immutable p10;

    /// @notice Router / Flow adapter.
    IP10Router public router;

    /// @notice Pricing & Oracles adapter.
    IP10Pricing public pricing;

    /// @notice Mint fee in basis points (1e4 = 100%). e.g. 10 = 0.10%
    uint16 public mintFeeBps = 10;

    /// @notice Redeem fee in basis points.
    uint16 public redeemFeeBps = 10;

    /// @notice Per-tx mint cap in USD (1e18 scale). 0 means no per-tx cap.
    uint256 public perTxMintCapUsdE18;

    /// @notice Daily mint cap as basis points of total supply (e.g. 200 = 2%).
    uint16 public dailyMintCapBps = 200; // 2% / day

    /// @notice Timestamp-truncated current day, used for mint accounting.
    uint256 public lastMintDay;

    /// @notice Total P10 minted today (net of burns is not tracked; conservative).
    uint256 public mintedToday;

    /// @notice Whether minting is paused (e.g. due to oracle issues).
    bool public mintPaused;

    /// @notice Whether redeem is paused (extreme router/oracle issues).
    bool public redeemPaused;

    /// @notice Whether the whole system is frozen (no mint or redeem).
    bool public emergencyFrozen;

    /// @notice Treasury address where fee P10 is minted (optional).
    address public feeRecipient;

    /// @notice Fast pauser role (can pause, owner can unpause).
    address public pauser;

    /// @notice Guardian role (can trigger emergency freeze, owner can unfreeze).
    address public guardian;

    // ========= Events =========

    event SnapshotActivated(uint256 indexed snapshotId);
    event Minted(address indexed user, uint256 p10Out, uint256 feeP10, uint256 basketUsdE18);
    event Redeemed(address indexed user, uint256 p10In, uint256 feeP10);

    event MintPaused(bool paused);
    event RedeemPaused(bool paused);
    event EmergencyFrozen(bool frozen);

    event RouterUpdated(address indexed router);
    event PricingUpdated(address indexed pricing);
    event FeesUpdated(uint16 mintFeeBps, uint16 redeemFeeBps);
    event MintCapsUpdated(uint256 perTxUsdE18, uint16 dailyMintCapBps);
    event FeeRecipientUpdated(address indexed feeRecipient);

    event PauserUpdated(address indexed pauser);
    event GuardianUpdated(address indexed guardian);

    // ========= Modifiers & role helpers =========

    modifier notFrozen() {
        require(!emergencyFrozen, "P10: frozen");
        _;
    }

    modifier onlyOwnerOrPauser() {
        require(msg.sender == owner() || msg.sender == pauser, "P10: not owner/pauser");
        _;
    }

    modifier onlyOwnerOrGuardian() {
        require(msg.sender == owner() || msg.sender == guardian, "P10: not owner/guardian");
        _;
    }

    // ========= Constructor & admin config =========

    /**
     * @notice Constructor for P10IndexManager.
     * @param initialOwner Initial owner (later timelock / multisig).
     * @param p10Token Address of the P10Token contract.
     * @param router_ Address of the IP10Router adapter.
     * @param pricing_ Address of the IP10Pricing adapter.
     */
    constructor(
        address initialOwner,
        address p10Token,
        address router_,
        address pricing_
    ) Ownable(initialOwner) {
        require(initialOwner != address(0), "P10: zero owner");
        require(p10Token != address(0), "P10: zero p10");
        require(router_ != address(0), "P10: zero router");
        require(pricing_ != address(0), "P10: zero pricing");

        p10 = P10Token(p10Token);
        router = IP10Router(router_);
        pricing = IP10Pricing(pricing_);
    }

    /**
     * @notice Update the router adapter.
     * @dev Only callable by owner.
     * @param _router New router address.
     */
    function setRouter(address _router) external onlyOwner {
        require(_router != address(0), "P10: zero router");
        router = IP10Router(_router);
        emit RouterUpdated(_router);
    }

    /**
     * @notice Update the pricing adapter.
     * @dev Only callable by owner.
     * @param _pricing New pricing address.
     */
    function setPricing(address _pricing) external onlyOwner {
        require(_pricing != address(0), "P10: zero pricing");
        pricing = IP10Pricing(_pricing);
        emit PricingUpdated(_pricing);
    }

    /**
     * @notice Update the fee recipient (P10 fees are minted here).
     * @dev Only callable by owner.
     * @param _feeRecipient New fee recipient address.
     */
    function setFeeRecipient(address _feeRecipient) external onlyOwner {
        feeRecipient = _feeRecipient;
        emit FeeRecipientUpdated(_feeRecipient);
    }

    /**
     * @notice Set the pauser address.
     * @dev Only owner can change it.
     */
    function setPauser(address _pauser) external onlyOwner {
        pauser = _pauser;
        emit PauserUpdated(_pauser);
    }

    /**
     * @notice Set the guardian address.
     * @dev Only owner can change it.
     */
    function setGuardian(address _guardian) external onlyOwner {
        guardian = _guardian;
        emit GuardianUpdated(_guardian);
    }

    /**
     * @notice Update mint and redeem fees (capped at 1%).
     * @dev Only callable by owner.
     * @param _mintFeeBps New mint fee in basis points.
     * @param _redeemFeeBps New redeem fee in basis points.
     */
    function setFees(uint16 _mintFeeBps, uint16 _redeemFeeBps) external onlyOwner {
        require(_mintFeeBps <= 100, "P10: mint fee too high"); // max 1%
        require(_redeemFeeBps <= 100, "P10: redeem fee too high"); // max 1%
        mintFeeBps = _mintFeeBps;
        redeemFeeBps = _redeemFeeBps;
        emit FeesUpdated(_mintFeeBps, _redeemFeeBps);
    }

    /**
     * @notice Update mint caps (per-tx and daily).
     * @dev Only callable by owner.
     * @param _perTxUsdE18 New per-tx cap in USD (1e18).
     * @param _dailyMintCapBps New daily cap in basis points.
     */
    function setMintCaps(uint256 _perTxUsdE18, uint16 _dailyMintCapBps) external onlyOwner {
        require(_dailyMintCapBps <= 1_000, "P10: daily cap too high"); // max 10%/day
        perTxMintCapUsdE18 = _perTxUsdE18;
        dailyMintCapBps = _dailyMintCapBps;
        emit MintCapsUpdated(_perTxUsdE18, _dailyMintCapBps);
    }

    /**
     * @notice Pause or unpause minting.
     * @dev pauser or owner can pause, only owner can unpause.
     * @param _paused Whether to pause minting.
     */
    function setMintPaused(bool _paused) external {
        if (_paused) {
            require(msg.sender == owner() || msg.sender == pauser, "P10: not owner/pauser");
        } else {
            require(msg.sender == owner(), "P10: only owner unpause");
        }
        mintPaused = _paused;
        emit MintPaused(_paused);
    }

    /**
     * @notice Pause or unpause redeem.
     * @dev pauser or owner can pause, only owner can unpause.
     * @param _paused Whether to pause redeem.
     */
    function setRedeemPaused(bool _paused) external {
        if (_paused) {
            require(msg.sender == owner() || msg.sender == pauser, "P10: not owner/pauser");
        } else {
            require(msg.sender == owner(), "P10: only owner unpause");
        }
        redeemPaused = _paused;
        emit RedeemPaused(_paused);
    }

    /**
     * @notice Set or clear global emergency freeze.
     * @dev guardian or owner can freeze, only owner can unfreeze.
     * @param _frozen New frozen state.
     */
    function setEmergencyFrozen(bool _frozen) external {
        if (_frozen) {
            require(msg.sender == owner() || msg.sender == guardian, "P10: not owner/guardian");
        } else {
            require(msg.sender == owner(), "P10: only owner unfreeze");
        }
        emergencyFrozen = _frozen;
        emit EmergencyFrozen(_frozen);
    }

    // ========= Snapshot management =========

    /**
     * @notice Push and activate a new index snapshot.
     * @dev Called by governance after off-chain RankOracle computes Top 10 + weights.
     *      Route through a timelock on mainnet. Off-chain sanity checks recommended.
     * @param tokens Array of constituent token addresses.
     * @param decimals Array of decimals for each token.
     * @param unitsPerP10E18 Array: target units-per-P10 for each token, scaled by 1e18.
     */
    function activateSnapshot(
        address[] calldata tokens,
        uint8[] calldata decimals,
        uint96[] calldata unitsPerP10E18
    ) external onlyOwner {
        uint256 len = tokens.length;
        require(len > 0, "P10: empty snapshot");
        require(
            len == decimals.length && len == unitsPerP10E18.length,
            "P10: length mismatch"
        );

        uint256 newId = snapshotId + 1;

        // Clear any existing data for newId (in case of reuse).
        delete _snapshots[newId];

        Asset[] storage arr = _snapshots[newId];
        for (uint256 i = 0; i < len; i++) {
            require(tokens[i] != address(0), "P10: zero token");
            arr.push(
                Asset({
                    token: tokens[i],
                    decimals: decimals[i],
                    unitsPerP10E18: unitsPerP10E18[i]
                })
            );
        }

        snapshotId = newId;
        emit SnapshotActivated(newId);
    }

    /**
     * @notice Get assets for a specific snapshot.
     * @param id Snapshot ID.
     * @return Assets array for the snapshot.
     */
    function getSnapshotAssets(uint256 id) external view returns (Asset[] memory) {
        return _snapshots[id];
    }

    /**
     * @notice Get active snapshot assets.
     * @return Assets array for the active snapshot.
     */
    function getActiveAssets() public view returns (Asset[] memory) {
        return _snapshots[snapshotId];
    }

    // ========= NAV + oracle guard =========

    /**
     * @notice Compute NAV per 1 P10 in USD (1e18) for the active snapshot.
     * @dev Uses target composition. Requires all prices safe.
     * @return navE18 NAV in USD * 1e18.
     */
    function navPerP10USD() public view returns (uint256 navE18) {
        return _computeNAV(snapshotId);
    }

    /**
     * @notice Compute NAV per 1 P10 in USD (1e18) for a historical snapshot.
     * @dev Uses target composition. Requires all prices safe.
     * @param id Snapshot ID.
     * @return navE18 NAV in USD * 1e18.
     */
    function getSnapshotNAV(uint256 id) public view returns (uint256 navE18) {
        return _computeNAV(id);
    }

    /**
     * @dev Internal: Compute NAV for a snapshot ID.
     */
    function _computeNAV(uint256 id) internal view returns (uint256 navE18) {
        Asset[] memory assets = _snapshots[id];
        uint256 len = assets.length;
        require(len > 0, "P10: no snapshot");

        for (uint256 i = 0; i < len; i++) {
            (uint256 priceE18, , bool isSafe) = pricing.getSafePriceUSD(assets[i].token);
            require(isSafe, "P10: unsafe price");
            navE18 += (uint256(assets[i].unitsPerP10E18) * priceE18) / 1e18;
        }
        require(navE18 > 0, "P10: nav zero");
    }

    /**
     * @dev Ensure pricing is safe for all constituents without computing NAV.
     *      Used in mint flows to early revert if oracle is degraded.
     */
    function _checkAllPricesSafe() internal view {
        Asset[] memory assets = getActiveAssets();
        uint256 len = assets.length;
        require(len > 0, "P10: no snapshot");

        for (uint256 i = 0; i < len; i++) {
            (, , bool isSafe) = pricing.getSafePriceUSD(assets[i].token);
            require(isSafe, "P10: unsafe price");
        }
    }

    /**
     * @notice Compute USD value (1e18) of a basket of amounts aligned with active snapshot.
     * @dev For frontend quoting. Assumes amounts[i] corresponds to active assets[i].
     * @param amounts Amounts of each asset.
     * @return usdE18 Total USD value * 1e18.
     */
    function getBasketValue(uint256[] calldata amounts) external view returns (uint256 usdE18) {
        Asset[] memory assets = getActiveAssets();
        uint256 len = assets.length;
        require(len == amounts.length, "P10: length mismatch");

        _checkAllPricesSafe(); // Ensures prices are safe

        for (uint256 i = 0; i < len; i++) {
            uint256 amt = amounts[i];
            if (amt == 0) continue;

            (uint256 priceE18, , ) = pricing.getSafePriceUSD(assets[i].token);
            uint256 valueUsd = (amt * priceE18) / (10 ** assets[i].decimals);
            usdE18 += valueUsd;
        }
    }

    // ========= Mint caps & accounting =========

    function _updateDailyMint(uint256 p10Amount) internal {
        uint256 day = block.timestamp / 1 days;
        if (day > lastMintDay) {
            lastMintDay = day;
            mintedToday = 0;
        }
        mintedToday += p10Amount;

        uint256 supply = p10.totalSupply();
        if (supply == 0) {
            // No daily cap on very first mint(s); optional.
            return;
        }

        uint256 maxToday = (supply * dailyMintCapBps) / 10_000;
        require(mintedToday <= maxToday, "P10: daily mint cap");
    }

    // ========= Basket-in / Basket-out =========

    /**
     * @notice Mint P10 by depositing the exact basket constituents (no swap).
     * @dev Caller must approve this contract for each token.
     *      Mint amount based on oracle value of deposits and NAV.
     * @param amounts Amounts of each token to deposit (aligned with active snapshot).
     * @param recipient Address receiving the newly minted P10.
     * @return p10Out Net P10 minted (after fee).
     */
    function mintBasketExact(
        uint256[] calldata amounts,
        address recipient
    ) external nonReentrant notFrozen returns (uint256 p10Out) {
        require(!mintPaused, "P10: mint paused");

        Asset[] memory assets = getActiveAssets();
        uint256 len = assets.length;
        require(len == amounts.length, "P10: length mismatch");

        _checkAllPricesSafe();
        uint256 navE18 = navPerP10USD();

        uint256 basketUsdE18;
        for (uint256 i = 0; i < len; i++) {
            uint256 amt = amounts[i];
            if (amt == 0) continue;
            IERC20(assets[i].token).safeTransferFrom(msg.sender, address(this), amt);

            (uint256 priceE18, , ) = pricing.getSafePriceUSD(assets[i].token);
            uint256 valueUsd = (amt * priceE18) / (10 ** assets[i].decimals);
            basketUsdE18 += valueUsd;
        }

        require(basketUsdE18 > 0, "P10: zero basket value");

        uint256 grossP10 = (basketUsdE18 * 1e18) / navE18;
        uint256 feeP10 = (grossP10 * mintFeeBps) / 10_000;
        p10Out = grossP10 - feeP10;

        if (perTxMintCapUsdE18 > 0) {
            require(basketUsdE18 <= perTxMintCapUsdE18, "P10: per-tx cap");
        }
        _updateDailyMint(p10Out);

        if (feeP10 > 0 && feeRecipient != address(0)) {
            p10.mint(feeRecipient, feeP10);
        }
        p10.mint(recipient, p10Out);

        emit Minted(recipient, p10Out, feeP10, basketUsdE18);
    }

    /**
     * @notice Redeem P10 into the pro-rata basket (no swap).
     * @dev Caller must approve P10 to this contract.
     *      Pure pro-rata based on current holdings.
     * @param p10In Amount of P10 to redeem.
     * @param recipient Address receiving the basket tokens.
     * @return amountsOut Amounts of each constituent returned.
     */
    function redeemBasketProRata(
        uint256 p10In,
        address recipient
    ) external nonReentrant notFrozen returns (uint256[] memory amountsOut) {
        require(!redeemPaused, "P10: redeem paused");
        require(p10In > 0, "P10: zero in");

        Asset[] memory assets = getActiveAssets();
        uint256 len = assets.length;
        amountsOut = new uint256[](len);

        uint256 supplyBefore = p10.totalSupply();
        require(supplyBefore > 0, "P10: no supply");

        IERC20(address(p10)).safeTransferFrom(msg.sender, address(this), p10In);
        p10.burn(address(this), p10In);

        uint256 feeP10 = (p10In * redeemFeeBps) / 10_000;
        uint256 p10Net = p10In - feeP10;

        if (feeP10 > 0 && feeRecipient != address(0)) {
            p10.mint(feeRecipient, feeP10);
        }

        for (uint256 i = 0; i < len; i++) {
            uint256 vaultBal = IERC20(assets[i].token).balanceOf(address(this));
            if (vaultBal == 0) continue;

            uint256 share = (vaultBal * p10Net) / supplyBefore;
            if (share > 0) {
                IERC20(assets[i].token).safeTransfer(recipient, share);
                amountsOut[i] = share;
            }
        }

        emit Redeemed(recipient, p10In, feeP10);
    }

    // ========= Single-asset Zap mint/redeem =========

    /**
     * @notice Preview P10 out for single-asset mint (without executing).
     * @dev Ignores caps and pause; for frontend quoting only.
     * @param assetIn Token address user pays with.
     * @param amountIn Amount of assetIn to deposit.
     * @return p10Out Estimated net P10 (after fee).
     */
    function previewMintSingle(
        address assetIn,
        uint256 amountIn
    ) external view returns (uint256 p10Out) {
        require(amountIn > 0, "P10: zero in");

        _checkAllPricesSafe();
        uint256 navE18 = navPerP10USD();

        (uint256 priceE18, , bool isSafe) = pricing.getSafePriceUSD(assetIn);
        require(isSafe, "P10: unsafe assetIn price");

        uint8 decs = _tryGetDecimals(assetIn);
        uint256 basketUsdE18 = (amountIn * priceE18) / (10 ** decs);
        require(basketUsdE18 > 0, "P10: zero basket value");

        uint256 grossP10 = (basketUsdE18 * 1e18) / navE18;
        uint256 feeP10 = (grossP10 * mintFeeBps) / 10_000;
        p10Out = grossP10 - feeP10;
    }

    /**
     * @notice Preview assetOut from redeemSingle (approximate, ignores router slippage).
     * @param p10In Amount of P10 to redeem.
     * @param assetOut Desired output asset.
     * @return amountOut Approx net amount of assetOut (after redeem fee).
     */
    function previewRedeemSingle(
        uint256 p10In,
        address assetOut
    ) external view returns (uint256 amountOut) {
        require(p10In > 0, "P10: zero in");
        require(assetOut != address(0), "P10: zero assetOut");

        _checkAllPricesSafe();
        uint256 navE18 = navPerP10USD();

        (uint256 priceOutE18, , bool isSafe) = pricing.getSafePriceUSD(assetOut);
        require(isSafe, "P10: unsafe assetOut price");

        uint8 decOut = _tryGetDecimals(assetOut);

        uint256 grossUsd = (p10In * navE18) / 1e18;
        uint256 feeUsd = (grossUsd * redeemFeeBps) / 10_000;
        uint256 netUsd = grossUsd - feeUsd;

        amountOut = (netUsd * (10 ** decOut)) / priceOutE18;
    }

    /**
     * @notice Mint P10 using a single asset (Zap in via Flow router).
     * @dev Flow: Value assetIn at oracle → mint at NAV → swap to basket.
     *      Decoupled: NAV-oracle for fairness, Flow for execution (enables rebates).
     * @param assetIn Token address user pays with.
     * @param amountIn Amount of assetIn to deposit.
     * @param recipient Address receiving P10.
     * @param minP10Out Minimum P10 user is willing to receive (slippage guard).
     * @return p10Out Net P10 minted.
     */
    function mintSingle(
        address assetIn,
        uint256 amountIn,
        address recipient,
        uint256 minP10Out
    ) external nonReentrant notFrozen returns (uint256 p10Out) {
        require(!mintPaused, "P10: mint paused");
        require(amountIn > 0, "P10: zero in");

        _checkAllPricesSafe();
        uint256 navE18 = navPerP10USD();

        IERC20(assetIn).safeTransferFrom(msg.sender, address(this), amountIn);

        (uint256 priceE18, , bool isSafe) = pricing.getSafePriceUSD(assetIn);
        require(isSafe, "P10: unsafe assetIn price");

        uint8 decs = _tryGetDecimals(assetIn);
        uint256 basketUsdE18 = (amountIn * priceE18) / (10 ** decs);
        require(basketUsdE18 > 0, "P10: zero basket value");

        uint256 grossP10 = (basketUsdE18 * 1e18) / navE18;
        uint256 feeP10 = (grossP10 * mintFeeBps) / 10_000;
        p10Out = grossP10 - feeP10;

        if (perTxMintCapUsdE18 > 0) {
            require(basketUsdE18 <= perTxMintCapUsdE18, "P10: per-tx cap");
        }
        _updateDailyMint(p10Out);
        require(p10Out >= minP10Out, "P10: slippage");

        if (feeP10 > 0 && feeRecipient != address(0)) {
            p10.mint(feeRecipient, feeP10);
        }
        p10.mint(recipient, p10Out);

        _swapAssetIntoBasket(assetIn, amountIn);

        emit Minted(recipient, p10Out, feeP10, basketUsdE18);
    }

    /**
     * @notice Redeem P10 into a single asset (Zap out via Flow router).
     * @dev Flow: Burn P10 → pro-rata basket → swap to assetOut.
     *      No oracle needed; pure pro-rata + routing.
     * @param p10In Amount of P10 to redeem.
     * @param assetOut Token user wants to receive.
     * @param recipient Address receiving assetOut.
     * @param minAmountOut Minimum acceptable assetOut (slippage guard).
     * @return amountOut Final amount of assetOut received.
     */
    function redeemSingle(
        uint256 p10In,
        address assetOut,
        address recipient,
        uint256 minAmountOut
    ) external nonReentrant notFrozen returns (uint256 amountOut) {
        require(!redeemPaused, "P10: redeem paused");
        require(p10In > 0, "P10: zero in");
        require(assetOut != address(0), "P10: zero assetOut");

        Asset[] memory assets = getActiveAssets();
        uint256 len = assets.length;
        require(len > 0, "P10: no snapshot");

        uint256 supplyBefore = p10.totalSupply();
        require(supplyBefore > 0, "P10: no supply");

        IERC20(address(p10)).safeTransferFrom(msg.sender, address(this), p10In);
        p10.burn(address(this), p10In);

        uint256 feeP10 = (p10In * redeemFeeBps) / 10_000;
        uint256 p10Net = p10In - feeP10;

        if (feeP10 > 0 && feeRecipient != address(0)) {
            p10.mint(feeRecipient, feeP10);
        }

        uint256[] memory basketShares = new uint256[](len);
        for (uint256 i = 0; i < len; i++) {
            uint256 vaultBal = IERC20(assets[i].token).balanceOf(address(this));
            if (vaultBal == 0) continue;

            uint256 share = (vaultBal * p10Net) / supplyBefore;
            basketShares[i] = share;
        }

        amountOut = _swapBasketIntoAssetOut(assets, basketShares, assetOut, recipient);
        require(amountOut >= minAmountOut, "P10: slippage");

        emit Redeemed(recipient, p10In, feeP10);
    }

    // ========= Router integration hooks (Flow) =========

    /**
     * @dev INTERNAL HOOK: convert `amountIn` of `assetIn` (held by this contract)
     *      into the target basket composition for the newly minted gross P10 amount.
     */
    function _swapAssetIntoBasket(address assetIn, uint256 amountIn) internal {
        Asset[] memory assets = getActiveAssets();
        uint256 len = assets.length;
        require(len > 0, "P10: no snapshot");

        _checkAllPricesSafe();
        uint256 navE18 = navPerP10USD();

        (uint256 priceInE18, , ) = pricing.getSafePriceUSD(assetIn);
        uint8 decIn = _tryGetDecimals(assetIn);
        uint256 basketUsdE18 = (amountIn * priceInE18) / (10 ** decIn);
        require(basketUsdE18 > 0, "P10: zero basket value");

        IERC20(assetIn).forceApprove(address(router), amountIn);

        uint256 remainingIn = amountIn;

        for (uint256 i = 0; i < len; i++) {
            address tokenI = assets[i].token;

            // If assetIn is itself in the basket, keep a share directly.
            if (tokenI == assetIn) {
                uint256 weightI = (priceInE18 * uint256(assets[i].unitsPerP10E18)) / navE18;
                uint256 keepHere = (amountIn * weightI) / 1e18;
                if (keepHere > 0 && keepHere <= remainingIn) {
                    remainingIn -= keepHere;
                }
                continue;
            }

            (uint256 priceIE18, , ) = pricing.getSafePriceUSD(tokenI);

            // Target USD for asset i: weight_i * basketUsdE18
            uint256 targetUsdI = (
                (priceIE18 * uint256(assets[i].unitsPerP10E18)) * basketUsdE18
            ) / (navE18 * 1e18);
            if (targetUsdI == 0) continue;

            // target_amount_i = targetUsdI * 10^dec / price_i
            uint256 targetAmtI = (targetUsdI * (10 ** assets[i].decimals)) / priceIE18;
            if (targetAmtI == 0) continue;

            // Rough share of input for this leg, in assetIn units
            uint256 amtLeg = (amountIn * targetUsdI) / basketUsdE18;
            if (amtLeg == 0 || amtLeg > remainingIn) {
                amtLeg = remainingIn;
            }
            if (amtLeg == 0) continue;

            // 0.5% slippage guard vs target amount_i
            uint256 minOutLeg = (targetAmtI * 995) / 1000;

            address[] memory path = new address[](2);
            path[0] = assetIn;
            path[1] = tokenI;

            router.swapExactTokensForTokens(amtLeg, minOutLeg, path, address(this));
            remainingIn -= amtLeg;

            if (remainingIn == 0) break;
        }

        // Allow a tiny leftover (rounding, route constraints).
        require(remainingIn <= amountIn / 500, "P10: excessive leftover"); // <=0.2%
    }

    /**
     * @dev INTERNAL HOOK: swap pro-rata `basketShares` of `assets` into `assetOut`,
     *      sending directly to `recipient`. Returns total amountOut (in assetOut units).
     */
    function _swapBasketIntoAssetOut(
        Asset[] memory assets,
        uint256[] memory basketShares,
        address assetOut,
        address recipient
    ) internal returns (uint256 amountOut) {
        uint256 len = assets.length;
        require(len == basketShares.length, "P10: length mismatch");

        for (uint256 i = 0; i < len; i++) {
            uint256 share = basketShares[i];
            if (share == 0) continue;

            address tokenI = assets[i].token;
            if (tokenI == assetOut) {
                IERC20(tokenI).safeTransfer(recipient, share);
                amountOut += share;
                continue;
            }

            IERC20(tokenI).forceApprove(address(router), share);

            address[] memory path = new address[](2);
            path[0] = tokenI;
            path[1] = assetOut;

            uint256 outLeg = router.swapExactTokensForTokens(
                share,
                0,          // aggregate slippage checked in redeemSingle
                path,
                recipient
            );

            amountOut += outLeg;
        }
    }

    // ========= Internal helpers =========

    /**
     * @dev Best-effort decimals getter. If call fails, default to 18.
     *      For production, you may want to cache decimals per asset in storage.
     */
    function _tryGetDecimals(address token) internal view returns (uint8) {
        (bool ok, bytes memory data) = token.staticcall(
            abi.encodeWithSignature("decimals()")
        );
        if (ok && data.length >= 32) {
            return uint8(uint256(bytes32(data)));
        }
        return 18;
    }
}
