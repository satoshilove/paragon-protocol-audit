// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

contract MockReferralManager {
    mapping(address => address) public ref;

    event Recorded(address indexed user, address indexed referrer);

    function getReferrer(address u) external view returns (address) { return ref[u]; }
    function recordReferral(address u, address r) external {
        if (r != address(0) && ref[u] == address(0)) {
            ref[u] = r;
            emit Recorded(u, r);
        }
    }
    function addReferralPoints(address, uint256) external {}
}
