// contracts/mocks/MockReputationOperator.sol
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

contract MockReputationOperator {
    event OnPayflowExecuted(address user, uint256 usdVol, uint256 usdSaved, bytes32 ref);

    function onPayflowExecuted(address user, uint256 usdVol, uint256 usdSaved, bytes32 ref) external {
        emit OnPayflowExecuted(user, usdVol, usdSaved, ref);
    }
}