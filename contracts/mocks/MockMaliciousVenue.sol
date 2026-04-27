// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.27;

import {IP10VenueAdapter} from "../P10/interfaces/IP10VenueAdapter.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract MockMaliciousVenue is IP10VenueAdapter {
    enum Mode {
        GOOD,
        UNDER_DELIVER,
        WRONG_ACQUIRED,
        WRONG_OUTPUT,
        WRONG_RECEIVER
    }

    Mode public mode;

    function setMode(Mode _mode) external {
        mode = _mode;
    }

    function buyBasketSingleToken(
        address,
        uint256,
        BasketLeg[] calldata legs,
        address receiver,
        bytes calldata
    ) external override returns (uint256[] memory actualAcquired) {
        actualAcquired = new uint256[](legs.length);

        for (uint256 i = 0; i < legs.length; i++) {
            if (legs[i].targetAmount == 0) continue;

            uint256 amt = legs[i].targetAmount;

            if (mode == Mode.UNDER_DELIVER) {
                amt = amt / 2;
            }

            if (mode == Mode.WRONG_RECEIVER) {
                IERC20(legs[i].token).transfer(address(0xdead), amt);
            } else {
                IERC20(legs[i].token).transfer(receiver, amt);
            }

            if (mode == Mode.WRONG_ACQUIRED) {
                actualAcquired[i] = amt + 1;
            } else {
                actualAcquired[i] = amt;
            }
        }
    }

    function sellBasketToSingleToken(
        BasketLeg[] calldata,
        address outputToken,
        uint256,
        address recipient,
        bytes calldata
    ) external override returns (uint256 actualOutput) {
        uint256 amt = 1e18;

        if (mode == Mode.WRONG_RECEIVER) {
            IERC20(outputToken).transfer(address(0xdead), amt);
        } else {
            IERC20(outputToken).transfer(recipient, amt);
        }

        if (mode == Mode.WRONG_OUTPUT) {
            return amt + 1;
        }

        return amt;
    }

    function name() external pure override returns (string memory) {
        return "MaliciousVenue";
    }
}
