// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @title Mock Wrapped BNB (WBNB) for testing
contract WETH9 {
    string public name     = "Wrapped BNB";
    string public symbol   = "WBNB";
    uint8  public decimals = 18;

    event  Approval(address indexed src, address indexed guy, uint wad);
    event  Transfer(address indexed src, address indexed dst, uint wad);
    event  Deposit(address indexed dst, uint wad);
    event  Withdrawal(address indexed src, uint wad);

    mapping(address => uint)                      public balanceOf;
    mapping(address => mapping(address => uint)) public allowance;

    receive() external payable {
        balanceOf[msg.sender] += msg.value;
        emit Deposit(msg.sender, msg.value);
    }

    function approve(address guy, uint wad) external returns (bool) {
        allowance[msg.sender][guy] = wad;
        emit Approval(msg.sender, guy, wad);
        return true;
    }

    function transfer(address dst, uint wad) external returns (bool) {
        return transferFrom(msg.sender, dst, wad);
    }

    function transferFrom(address src, address dst, uint wad) public returns (bool) {
        require(balanceOf[src] >= wad, "WBNB: balance");
        if (src != msg.sender && allowance[src][msg.sender] != type(uint).max) {
            require(allowance[src][msg.sender] >= wad, "WBNB: allowance");
            allowance[src][msg.sender] -= wad;
        }
        balanceOf[src] -= wad;
        balanceOf[dst] += wad;
        emit Transfer(src, dst, wad);
        return true;
    }

    function withdraw(uint wad) external {
        require(balanceOf[msg.sender] >= wad, "WBNB: balance");
        balanceOf[msg.sender] -= wad;
        payable(msg.sender).transfer(wad);
        emit Withdrawal(msg.sender, wad);
    }
}
