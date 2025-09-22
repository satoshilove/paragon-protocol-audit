// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MockERC20FOT is ERC20 {
    uint8 private _dec;
    uint16 public feeBips; // transfer fee to this contract for simplicity

    constructor(string memory n, string memory s, uint8 d, uint16 _feeBips) ERC20(n, s) {
        require(_feeBips <= 1000, "fee too high");
        _dec = d;
        feeBips = _feeBips;
    }

    function decimals() public view override returns (uint8) { return _dec; }

    function mint(address to, uint256 amt) external { _mint(to, amt); }

    function _update(address from, address to, uint256 value) internal override {
        if (from != address(0) && to != address(0) && feeBips > 0) {
            uint256 fee = (value * feeBips) / 10000;
            uint256 send = value - fee;
            super._update(from, address(this), fee);
            super._update(from, to, send);
        } else {
            super._update(from, to, value);
        }
    }
}
