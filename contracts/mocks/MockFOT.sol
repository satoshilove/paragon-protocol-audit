// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
contract MockFOT is ERC20 {
    uint16 public feeBps; address public feeSink;
    constructor(string memory n, string memory s, uint16 _feeBps, address _sink) ERC20(n, s) {
        feeBps = _feeBps; feeSink = _sink;
    }
    function mint(address to, uint256 amt) external { _mint(to, amt); }
    function _update(address from, address to, uint256 value) internal override {
        if (from != address(0) && feeBps > 0) {
            uint256 fee = value * feeBps / 10000;
            super._update(from, feeSink, fee);
            value -= fee;
        }
        super._update(from, to, value);
    }
}
