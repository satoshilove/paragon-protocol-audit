// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {IP10VenueAdapter} from "./interfaces/IP10VenueAdapter.sol";
import {IP10IndexManager} from "./interfaces/IP10IndexManager.sol";

contract P10ExecutionManager is Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    IP10IndexManager public immutable indexManager;
    address public immutable vault;

    mapping(address => bool) public venueWhitelisted;

    event VenueWhitelisted(address indexed venue, bool enabled);
    event BasketBought(address indexed venue, uint256[] actualAcquired);
    event BasketSold(address indexed venue, uint256 actualOutput);

    constructor(address initialOwner, address _indexManager, address _vault)
        Ownable(initialOwner)
    {
        require(_indexManager != address(0), "P10Exec: zero indexManager");
        require(_vault != address(0), "P10Exec: zero vault");
        indexManager = IP10IndexManager(_indexManager);
        vault = _vault;
    }

    function whitelistVenue(address venue, bool enabled) external onlyOwner {
        require(venue != address(0), "P10Exec: zero venue");
        venueWhitelisted[venue] = enabled;
        emit VenueWhitelisted(venue, enabled);
    }

    function buyBasketSingleToken(
        IP10VenueAdapter venue,
        address inputToken,
        uint256 inputAmount,
        IP10VenueAdapter.BasketLeg[] calldata legs,
        uint256 minTotalValueUsdE18,
        bytes calldata venueData
    ) external nonReentrant returns (uint256[] memory actualAcquired) {
        require(venueWhitelisted[address(venue)], "P10Exec: venue not whitelisted");
        require(msg.sender == address(indexManager), "P10Exec: only indexManager");
        require(inputToken != address(0), "P10Exec: zero input");
        require(inputAmount > 0, "P10Exec: zero input amount");
        require(legs.length > 0, "P10Exec: empty legs");

        uint256 beforeInputBal = IERC20(inputToken).balanceOf(address(this));
        require(beforeInputBal >= inputAmount, "P10Exec: insufficient input");

        IERC20(inputToken).safeTransfer(address(venue), inputAmount);

        uint256[] memory beforeBal = new uint256[](legs.length);
        for (uint256 i = 0; i < legs.length; i++) {
            if (legs[i].targetAmount == 0) {
                beforeBal[i] = 0;
                continue;
            }
            require(legs[i].token != address(0), "P10Exec: zero leg token");
            beforeBal[i] = IERC20(legs[i].token).balanceOf(vault);
        }

        actualAcquired = venue.buyBasketSingleToken(
            inputToken,
            inputAmount,
            legs,
            vault,
            venueData
        );

        require(actualAcquired.length == legs.length, "P10Exec: bad acquired length");

        uint256 totalValueUsdE18;
        for (uint256 i = 0; i < legs.length; i++) {
            if (legs[i].targetAmount == 0) {
                require(actualAcquired[i] == 0, "P10Exec: unexpected acquired");
                continue;
            }

            uint256 afterBal = IERC20(legs[i].token).balanceOf(vault);
            uint256 delta = afterBal - beforeBal[i];
            require(delta >= legs[i].minAmount, "P10Exec: leg slippage");
            require(delta == actualAcquired[i], "P10Exec: bad delta");
            totalValueUsdE18 += indexManager.getAssetValue(legs[i].token, delta);
        }

        require(totalValueUsdE18 >= minTotalValueUsdE18, "P10Exec: aggregate slippage");

        uint256 afterInputBal = IERC20(inputToken).balanceOf(address(this));
        require(afterInputBal == beforeInputBal - inputAmount, "P10Exec: bad input delta");

        emit BasketBought(address(venue), actualAcquired);
    }

    function sellBasketToSingleToken(
        IP10VenueAdapter venue,
        IP10VenueAdapter.BasketLeg[] calldata legs,
        address outputToken,
        uint256 minOutput,
        address recipient,
        bytes calldata venueData
    ) external nonReentrant returns (uint256 actualOutput) {
        require(venueWhitelisted[address(venue)], "P10Exec: venue not whitelisted");
        require(msg.sender == address(indexManager), "P10Exec: only indexManager");
        require(outputToken != address(0), "P10Exec: zero output");
        require(recipient != address(0), "P10Exec: zero recipient");
        require(minOutput > 0, "P10Exec: zero minOutput");
        require(legs.length > 0, "P10Exec: empty legs");

        uint256[] memory beforeLegBalances = new uint256[](legs.length);
        for (uint256 i = 0; i < legs.length; i++) {
            if (legs[i].targetAmount == 0) {
                beforeLegBalances[i] = 0;
                continue;
            }
            require(legs[i].token != address(0), "P10Exec: zero leg token");
            beforeLegBalances[i] = IERC20(legs[i].token).balanceOf(address(this));
        }

        for (uint256 i = 0; i < legs.length; i++) {
            if (legs[i].targetAmount == 0) continue;

            require(
                beforeLegBalances[i] >= legs[i].targetAmount,
                "P10Exec: insufficient leg balance"
            );

            IERC20(legs[i].token).safeTransfer(address(venue), legs[i].targetAmount);
        }

        uint256 beforeOut = IERC20(outputToken).balanceOf(address(this));

        uint256 venueReportedOut = venue.sellBasketToSingleToken(
            legs,
            outputToken,
            minOutput,
            address(this),
            venueData
        );

        uint256 afterOut = IERC20(outputToken).balanceOf(address(this));
        uint256 deltaOut = afterOut - beforeOut;

        require(deltaOut >= minOutput, "P10Exec: slippage");
        require(deltaOut == venueReportedOut, "P10Exec: bad output delta");

        for (uint256 i = 0; i < legs.length; i++) {
            if (legs[i].targetAmount == 0) continue;
            if (legs[i].token == outputToken) continue;

            uint256 expectedAfter = beforeLegBalances[i] - legs[i].targetAmount;
            uint256 actualAfter = IERC20(legs[i].token).balanceOf(address(this));
            require(actualAfter == expectedAfter, "P10Exec: leftover leg");
        }

        // Critical fix:
        // enforce the user-level minOutput guarantee on the final transfer,
        // so fee-on-transfer output tokens cannot satisfy slippage at the
        // execution-manager boundary but short the final recipient.
        uint256 beforeRecipient = IERC20(outputToken).balanceOf(recipient);
        IERC20(outputToken).safeTransfer(recipient, deltaOut);
        uint256 afterRecipient = IERC20(outputToken).balanceOf(recipient);
        uint256 recipientDelta = afterRecipient - beforeRecipient;

        require(recipientDelta >= minOutput, "P10Exec: recipient slippage");

        actualOutput = recipientDelta;

        emit BasketSold(address(venue), actualOutput);
    }
}
