// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

interface IP10VenueAdapter {
    struct BasketLeg {
        address token;
        uint256 targetAmount;
        uint256 minAmount;
    }

    /// @notice Buy basket legs using one input token.
    /// @dev Must send acquired basket assets to `receiver`.
    function buyBasketSingleToken(
        address inputToken,
        uint256 inputAmount,
        BasketLeg[] calldata legs,
        address receiver,
        bytes calldata venueData
    ) external returns (uint256[] memory actualAcquired);

    /// @notice Sell basket legs into one output token.
    /// @dev Must send output token to `recipient`.
    function sellBasketToSingleToken(
        BasketLeg[] calldata legs,
        address outputToken,
        uint256 minOutput,
        address recipient,
        bytes calldata venueData
    ) external returns (uint256 actualOutput);

    function name() external pure returns (string memory);
}
