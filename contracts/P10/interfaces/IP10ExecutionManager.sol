// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {IP10VenueAdapter} from "./IP10VenueAdapter.sol";

interface IP10ExecutionManager {
    function buyBasketSingleToken(
        IP10VenueAdapter venue,
        address inputToken,
        uint256 inputAmount,
        IP10VenueAdapter.BasketLeg[] calldata legs,
        uint256 minTotalValueUsdE18,
        bytes calldata venueData
    ) external returns (uint256[] memory actualAcquired);

    function sellBasketToSingleToken(
        IP10VenueAdapter venue,
        IP10VenueAdapter.BasketLeg[] calldata legs,
        address outputToken,
        uint256 minOutput,
        address recipient,
        bytes calldata venueData
    ) external returns (uint256 actualOutput);
}
