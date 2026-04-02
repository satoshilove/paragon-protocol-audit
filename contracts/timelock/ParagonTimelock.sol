// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.25;

import "@openzeppelin/contracts/governance/TimelockController.sol";

contract ParagonTimelock is TimelockController {
    /**
     * @param minDelay       Delay in seconds (e.g. 24 hours = 86400, 48 hours = 172800)
     * @param proposers      Array of addresses allowed to queue (use multisig(s))
     * @param executors      Array of addresses allowed to execute (often include address(0) for anyone-after-delay)
     * @param admin          Optional second admin for initial setup. Pass address(0) if you want immediate lock-down.
     */
    constructor(
        uint256 minDelay,
        address[] memory proposers,
        address[] memory executors,
        address admin
    ) TimelockController(minDelay, proposers, executors, admin) {}
}