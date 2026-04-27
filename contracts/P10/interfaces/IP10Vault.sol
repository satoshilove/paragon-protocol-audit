// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

interface IP10Vault {
    function directDepositFromUser(address token, address from, uint256 amount) external;
    function directWithdrawToUser(address token, address to, uint256 amount) external;
    function withdrawToExecutionManager(address token, uint256 amount) external;
}
