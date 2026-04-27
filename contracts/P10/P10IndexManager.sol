// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {P10Token} from "./P10Token.sol";
import {IP10Pricing} from "./interfaces/IP10Core.sol";
import {IP10VenueAdapter} from "./interfaces/IP10VenueAdapter.sol";
import {IP10Vault} from "./interfaces/IP10Vault.sol";
import {IP10ExecutionManager} from "./interfaces/IP10ExecutionManager.sol";

contract P10IndexManager is Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint16 public constant EXACT_BASKET_TOLERANCE_BPS = 50; // 0.50%

    struct Asset {
        address token;
        uint8 decimals;
        uint96 unitsPerP10E18;
    }

    uint256 public snapshotId;
    mapping(uint256 => Asset[]) internal _snapshots;

    P10Token public immutable p10;
    IP10Pricing public pricing;
    IP10Vault public vault;
    IP10ExecutionManager public executionManager;

    address public mintVenue;
    address public redeemVenue;

    uint16 public mintFeeBps = 10;
    uint16 public redeemFeeBps = 10;

    uint256 public perTxMintCapUsdE18;
    uint16 public dailyMintCapBps = 200;

    uint256 public lastMintDay;
    uint256 public mintedToday;

    bool public mintPaused;
    bool public redeemPaused;
    bool public emergencyFrozen;

    address public feeRecipient;
    address public pauser;
    address public guardian;

    event SnapshotActivated(uint256 indexed snapshotId);
    event Minted(address indexed user, uint256 p10Out, uint256 feeP10, uint256 basketUsdE18);
    event Redeemed(address indexed user, uint256 p10In, uint256 feeP10);
    event MintPaused(bool paused);
    event RedeemPaused(bool paused);
    event EmergencyFrozen(bool frozen);
    event PricingUpdated(address indexed pricing);
    event VaultUpdated(address indexed vault);
    event ExecutionManagerUpdated(address indexed executionManager);
    event MintVenueUpdated(address indexed venue);
    event RedeemVenueUpdated(address indexed venue);
    event FeesUpdated(uint16 mintFeeBps, uint16 redeemFeeBps);
    event MintCapsUpdated(uint256 perTxUsdE18, uint16 dailyMintCapBps);
    event FeeRecipientUpdated(address indexed feeRecipient);
    event PauserUpdated(address indexed pauser);
    event GuardianUpdated(address indexed guardian);

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

    constructor(
        address initialOwner,
        address p10Token,
        address pricing_
    ) Ownable(initialOwner) {
        require(initialOwner != address(0), "P10: zero owner");
        require(p10Token != address(0), "P10: zero p10");
        require(pricing_ != address(0), "P10: zero pricing");

        p10 = P10Token(p10Token);
        pricing = IP10Pricing(pricing_);
    }

    function setPricing(address _pricing) external onlyOwner {
        require(_pricing != address(0), "P10: zero pricing");
        pricing = IP10Pricing(_pricing);
        emit PricingUpdated(_pricing);
    }

    function setVault(address _vault) external onlyOwner {
        require(_vault != address(0), "P10: zero vault");
        vault = IP10Vault(_vault);
        emit VaultUpdated(_vault);
    }

    function setExecutionManager(address _executionManager) external onlyOwner {
        require(_executionManager != address(0), "P10: zero exec manager");
        executionManager = IP10ExecutionManager(_executionManager);
        emit ExecutionManagerUpdated(_executionManager);
    }

    function setMintVenue(address _venue) external onlyOwner {
        require(_venue != address(0), "P10: zero mint venue");
        mintVenue = _venue;
        emit MintVenueUpdated(_venue);
    }

    function setRedeemVenue(address _venue) external onlyOwner {
        require(_venue != address(0), "P10: zero redeem venue");
        redeemVenue = _venue;
        emit RedeemVenueUpdated(_venue);
    }

    function setFeeRecipient(address _feeRecipient) external onlyOwner {
        feeRecipient = _feeRecipient;
        emit FeeRecipientUpdated(_feeRecipient);
    }

    function setPauser(address _pauser) external onlyOwner {
        pauser = _pauser;
        emit PauserUpdated(_pauser);
    }

    function setGuardian(address _guardian) external onlyOwner {
        guardian = _guardian;
        emit GuardianUpdated(_guardian);
    }

    function setFees(uint16 _mintFeeBps, uint16 _redeemFeeBps) external onlyOwner {
        require(_mintFeeBps <= 100, "P10: mint fee too high");
        require(_redeemFeeBps <= 100, "P10: redeem fee too high");
        mintFeeBps = _mintFeeBps;
        redeemFeeBps = _redeemFeeBps;
        emit FeesUpdated(_mintFeeBps, _redeemFeeBps);
    }

    function setMintCaps(uint256 _perTxUsdE18, uint16 _dailyMintCapBps) external onlyOwner {
        require(_dailyMintCapBps <= 1_000, "P10: daily cap too high");
        perTxMintCapUsdE18 = _perTxUsdE18;
        dailyMintCapBps = _dailyMintCapBps;
        emit MintCapsUpdated(_perTxUsdE18, _dailyMintCapBps);
    }

    function setMintPaused(bool _paused) external onlyOwnerOrPauser {
        if (!_paused) require(msg.sender == owner(), "P10: only owner unpause");
        mintPaused = _paused;
        emit MintPaused(_paused);
    }

    function setRedeemPaused(bool _paused) external onlyOwnerOrPauser {
        if (!_paused) require(msg.sender == owner(), "P10: only owner unpause");
        redeemPaused = _paused;
        emit RedeemPaused(_paused);
    }

    function setEmergencyFrozen(bool _frozen) external onlyOwnerOrGuardian {
        if (!_frozen) require(msg.sender == owner(), "P10: only owner unfreeze");
        emergencyFrozen = _frozen;
        emit EmergencyFrozen(_frozen);
    }

    function activateSnapshot(
        address[] calldata tokens,
        uint8[] calldata decimals,
        uint96[] calldata unitsPerP10E18
    ) external onlyOwner {
        uint256 len = tokens.length;
        require(len > 0, "P10: empty snapshot");
        require(len == decimals.length && len == unitsPerP10E18.length, "P10: length mismatch");

        for (uint256 i = 0; i < len; i++) {
            require(tokens[i] != address(0), "P10: zero token");
            require(unitsPerP10E18[i] > 0, "P10: zero units");
            for (uint256 j = i + 1; j < len; j++) {
                require(tokens[i] != tokens[j], "P10: duplicate token");
            }
        }

        uint256 newId = snapshotId + 1;
        delete _snapshots[newId];

        Asset[] storage arr = _snapshots[newId];
        for (uint256 i = 0; i < len; i++) {
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

    function getSnapshotAssets(uint256 id) external view returns (Asset[] memory) {
        return _snapshots[id];
    }

    function getActiveAssets() public view returns (Asset[] memory) {
        return _snapshots[snapshotId];
    }

    function navPerP10USD() public view returns (uint256 navE18) {
        return _computeNAV(snapshotId);
    }

    function getSnapshotNAV(uint256 id) public view returns (uint256 navE18) {
        return _computeNAV(id);
    }

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

    function _checkAllPricesSafe() internal view {
        Asset[] memory assets = getActiveAssets();
        require(assets.length > 0, "P10: no snapshot");

        for (uint256 i = 0; i < assets.length; i++) {
            (, , bool isSafe) = pricing.getSafePriceUSD(assets[i].token);
            require(isSafe, "P10: unsafe price");
        }
    }

    function getBasketValue(uint256[] calldata amounts) external view returns (uint256 usdE18) {
        Asset[] memory assets = getActiveAssets();
        require(assets.length == amounts.length, "P10: length mismatch");

        _checkAllPricesSafe();

        for (uint256 i = 0; i < assets.length; i++) {
            uint256 amt = amounts[i];
            if (amt == 0) continue;

            (uint256 priceE18, , ) = pricing.getSafePriceUSD(assets[i].token);
            usdE18 += (amt * priceE18) / (10 ** assets[i].decimals);
        }
    }

    function _updateDailyMint(uint256 p10Amount) internal {
        uint256 day = block.timestamp / 1 days;
        if (day > lastMintDay) {
            lastMintDay = day;
            mintedToday = 0;
        }

        mintedToday += p10Amount;

        uint256 supply = p10.totalSupply();
        if (supply == 0) return;
        if (dailyMintCapBps == 0) return;

        uint256 maxToday = (supply * dailyMintCapBps) / 10_000;
        require(mintedToday <= maxToday, "P10: daily mint cap");
    }

    function _normalizeTo1e18(uint256 amount, uint8 decimals) internal pure returns (uint256) {
        if (decimals == 18) return amount;
        if (decimals < 18) return amount * (10 ** (18 - decimals));
        return amount / (10 ** (decimals - 18));
    }

    function _enforceExactBasket(uint256[] calldata amounts, Asset[] memory assets) internal pure {
        uint256 len = assets.length;
        require(len > 0, "P10: no snapshot");
        require(amounts.length == len, "P10: length mismatch");

        uint256 baseAmountNorm = _normalizeTo1e18(amounts[0], assets[0].decimals);
        uint256 baseUnits = uint256(assets[0].unitsPerP10E18);

        require(baseAmountNorm > 0, "P10: zero basket leg");
        require(baseUnits > 0, "P10: zero base units");

        for (uint256 i = 0; i < len; i++) {
            uint256 amountNorm = _normalizeTo1e18(amounts[i], assets[i].decimals);

            require(amountNorm > 0, "P10: zero basket leg");
            require(assets[i].unitsPerP10E18 > 0, "P10: zero units");

            uint256 lhs = amountNorm * baseUnits;
            uint256 rhs = baseAmountNorm * uint256(assets[i].unitsPerP10E18);

            if (lhs == rhs) continue;

            uint256 diff = lhs > rhs ? lhs - rhs : rhs - lhs;
            require(diff * 10_000 <= rhs * EXACT_BASKET_TOLERANCE_BPS, "P10: basket ratio");
        }
    }

    function mintBasketExact(
        uint256[] calldata amounts,
        address recipient
    ) external nonReentrant notFrozen returns (uint256 p10Out) {
        require(!mintPaused, "P10: mint paused");
        require(address(vault) != address(0), "P10: vault not set");
        require(recipient != address(0), "P10: zero recipient");

        Asset[] memory assets = getActiveAssets();
        require(assets.length == amounts.length, "P10: length mismatch");

        _checkAllPricesSafe();
        _enforceExactBasket(amounts, assets);

        uint256 navE18 = navPerP10USD();
        uint256 basketUsdE18;

        for (uint256 i = 0; i < assets.length; i++) {
            uint256 amt = amounts[i];
            vault.directDepositFromUser(assets[i].token, msg.sender, amt);

            (uint256 priceE18, , ) = pricing.getSafePriceUSD(assets[i].token);
            basketUsdE18 += (amt * priceE18) / (10 ** assets[i].decimals);
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

    function redeemBasketProRata(
        uint256 p10In,
        address recipient
    ) external nonReentrant notFrozen returns (uint256[] memory amountsOut) {
        require(!redeemPaused, "P10: redeem paused");
        require(address(vault) != address(0), "P10: vault not set");
        require(recipient != address(0), "P10: zero recipient");
        require(p10In > 0, "P10: zero in");

        Asset[] memory assets = getActiveAssets();
        amountsOut = new uint256[](assets.length);

        uint256 supplyBefore = p10.totalSupply();
        require(supplyBefore > 0, "P10: no supply");

        IERC20(address(p10)).safeTransferFrom(msg.sender, address(this), p10In);
        p10.burn(address(this), p10In);

        uint256 feeP10 = (p10In * redeemFeeBps) / 10_000;
        uint256 p10Net = p10In - feeP10;

        if (feeP10 > 0 && feeRecipient != address(0)) {
            p10.mint(feeRecipient, feeP10);
        }

        for (uint256 i = 0; i < assets.length; i++) {
            uint256 vaultBal = IERC20(assets[i].token).balanceOf(address(vault));
            if (vaultBal == 0) continue;

            uint256 share = (vaultBal * p10Net) / supplyBefore;
            if (share > 0) {
                vault.directWithdrawToUser(assets[i].token, recipient, share);
                amountsOut[i] = share;
            }
        }

        emit Redeemed(recipient, p10In, feeP10);
    }

    function previewMintSingle(address assetIn, uint256 amountIn) external view returns (uint256 p10Out) {
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

    function previewRedeemSingle(uint256 p10In, address assetOut) external view returns (uint256 amountOut) {
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

    function mintSingle(
        address assetIn,
        uint256 amountIn,
        address recipient,
        uint256 minP10Out,
        bytes calldata venueData
    ) external nonReentrant notFrozen returns (uint256 p10Out) {
        require(!mintPaused, "P10: mint paused");
        require(address(vault) != address(0), "P10: vault not set");
        require(address(executionManager) != address(0), "P10: exec not set");
        require(mintVenue != address(0), "P10: mint venue not set");
        require(amountIn > 0, "P10: zero in");
        require(recipient != address(0), "P10: zero recipient");

        _checkAllPricesSafe();
        uint256 navE18 = navPerP10USD();

        IERC20(assetIn).safeTransferFrom(msg.sender, address(this), amountIn);
        IERC20(assetIn).safeTransfer(address(executionManager), amountIn);

        Asset[] memory assets = getActiveAssets();
        IP10VenueAdapter.BasketLeg[] memory legs = new IP10VenueAdapter.BasketLeg[](assets.length);

        (uint256 inPrice, , bool inSafe) = pricing.getSafePriceUSD(assetIn);
        require(inSafe, "P10: unsafe assetIn price");
        uint8 inDec = _tryGetDecimals(assetIn);
        uint256 inputUsdE18 = (amountIn * inPrice) / (10 ** inDec);

        uint256 expectedBasketUsdE18;
        for (uint256 i = 0; i < assets.length; i++) {
            uint256 targetAmt = (((uint256(assets[i].unitsPerP10E18) * inputUsdE18) / navE18) * (10 ** assets[i].decimals)) / 1e18;

            legs[i] = IP10VenueAdapter.BasketLeg({
                token: assets[i].token,
                targetAmount: targetAmt,
                minAmount: (targetAmt * 990) / 1000
            });

            expectedBasketUsdE18 += getAssetValue(assets[i].token, targetAmt);
        }

        if (perTxMintCapUsdE18 > 0) {
            require(expectedBasketUsdE18 <= perTxMintCapUsdE18, "P10: per-tx cap");
        }

        uint256[] memory actualAcquired = executionManager.buyBasketSingleToken(
            IP10VenueAdapter(mintVenue),
            assetIn,
            amountIn,
            legs,
            (expectedBasketUsdE18 * 985) / 1000,
            venueData
        );

        uint256 actualBasketUsdE18;
        for (uint256 i = 0; i < assets.length; i++) {
            actualBasketUsdE18 += getAssetValue(assets[i].token, actualAcquired[i]);
        }

        require(actualBasketUsdE18 > 0, "P10: zero actual basket value");

        uint256 grossP10 = (actualBasketUsdE18 * 1e18) / navE18;
        uint256 feeP10 = (grossP10 * mintFeeBps) / 10_000;
        p10Out = grossP10 - feeP10;

        _updateDailyMint(p10Out);
        require(p10Out >= minP10Out, "P10: slippage");

        if (feeP10 > 0 && feeRecipient != address(0)) {
            p10.mint(feeRecipient, feeP10);
        }
        p10.mint(recipient, p10Out);

        emit Minted(recipient, p10Out, feeP10, actualBasketUsdE18);
    }

    function redeemSingle(
        uint256 p10In,
        address assetOut,
        address recipient,
        uint256 minAmountOut,
        bytes calldata venueData
    ) external nonReentrant notFrozen returns (uint256 amountOut) {
        require(!redeemPaused, "P10: redeem paused");
        require(address(vault) != address(0), "P10: vault not set");
        require(address(executionManager) != address(0), "P10: exec not set");
        require(redeemVenue != address(0), "P10: redeem venue not set");
        require(p10In > 0, "P10: zero in");
        require(assetOut != address(0), "P10: zero assetOut");
        require(recipient != address(0), "P10: zero recipient");

        Asset[] memory assets = getActiveAssets();
        require(assets.length > 0, "P10: no snapshot");

        uint256 supplyBefore = p10.totalSupply();
        require(supplyBefore > 0, "P10: no supply");

        IERC20(address(p10)).safeTransferFrom(msg.sender, address(this), p10In);
        p10.burn(address(this), p10In);

        uint256 feeP10 = (p10In * redeemFeeBps) / 10_000;
        uint256 p10Net = p10In - feeP10;

        if (feeP10 > 0 && feeRecipient != address(0)) {
            p10.mint(feeRecipient, feeP10);
        }

        IP10VenueAdapter.BasketLeg[] memory legs = new IP10VenueAdapter.BasketLeg[](assets.length);

        for (uint256 i = 0; i < assets.length; i++) {
            uint256 vaultBal = IERC20(assets[i].token).balanceOf(address(vault));
            if (vaultBal == 0) continue;

            uint256 share = (vaultBal * p10Net) / supplyBefore;
            if (share > 0) {
                vault.withdrawToExecutionManager(assets[i].token, share);
                legs[i] = IP10VenueAdapter.BasketLeg({
                    token: assets[i].token,
                    targetAmount: share,
                    minAmount: share
                });
            }
        }

        amountOut = executionManager.sellBasketToSingleToken(
            IP10VenueAdapter(redeemVenue),
            legs,
            assetOut,
            minAmountOut,
            recipient,
            venueData
        );

        require(amountOut >= minAmountOut, "P10: slippage");
        emit Redeemed(recipient, p10In, feeP10);
    }

    function getAssetValue(address token, uint256 amount) public view returns (uint256 usdE18) {
        if (amount == 0) return 0;
        (uint256 priceE18, , bool isSafe) = pricing.getSafePriceUSD(token);
        require(isSafe, "P10: unsafe price");
        uint8 dec = _tryGetDecimals(token);
        return (amount * priceE18) / (10 ** dec);
    }

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
