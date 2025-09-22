// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

interface IReferralManager {
    function getReferrer(address user) external view returns (address);
    function recordReferral(address user, address referrer) external;
    function addReferralPoints(address user, uint256 points) external;
}
