// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

contract MalToken {
    string public name = "MAL";
    string public symbol = "MAL";
    uint8  public decimals = 18;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    address public reenterTarget;

    function setReenterTarget(address t) external { reenterTarget = t; }

    function mint(address to, uint256 amt) external { balanceOf[to] += amt; }

    function approve(address s, uint256 amt) external returns (bool) {
        allowance[msg.sender][s] = amt;
        return true;
    }

    function transferFrom(address from, address to, uint256 amt) external returns (bool) {
        uint256 a = allowance[from][msg.sender];
        require(a >= amt, "allow");
        allowance[from][msg.sender] = a - amt;
        _xfer(from, to, amt);
        return true;
    }

    function transfer(address to, uint256 amt) external returns (bool) {
        _xfer(msg.sender, to, amt);
        return true;
    }

    function _xfer(address from, address to, uint256 amt) internal {
        require(balanceOf[from] >= amt, "bal");
        balanceOf[from] -= amt;
        balanceOf[to] += amt;
        // Attempt to re-enter dripper.drip() when dripper is msg.sender
        if (reenterTarget != address(0) && msg.sender == reenterTarget) {
            (bool ok,) = reenterTarget.call(abi.encodeWithSignature("drip()"));
            ok; // silence warning (we expect revert)
        }
    }
}
