// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;
contract WETH9 {
    string public name = "Wrapped Ether";
    string public symbol = "WETH";
    uint8  public decimals = 18;
    mapping(address=>uint256) public balanceOf;
    mapping(address=>mapping(address=>uint256)) public allowance;
    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);
    receive() external payable { deposit(); }
    function deposit() public payable { balanceOf[msg.sender] += msg.value; emit Transfer(address(0), msg.sender, msg.value); }
    function withdraw(uint256 wad) public { require(balanceOf[msg.sender] >= wad); balanceOf[msg.sender] -= wad; payable(msg.sender).transfer(wad); emit Transfer(msg.sender, address(0), wad); }
    function approve(address guy, uint wad) public returns (bool) { allowance[msg.sender][guy] = wad; emit Approval(msg.sender,guy,wad); return true; }
    function transfer(address to, uint wad) public returns (bool) { return transferFrom(msg.sender,to,wad); }
    function transferFrom(address from, address to, uint wad) public returns (bool) {
        if (from != msg.sender) { uint256 a = allowance[from][msg.sender]; require(a >= wad); if (a != type(uint256).max) allowance[from][msg.sender] = a - wad; }
        require(balanceOf[from] >= wad); balanceOf[from] -= wad; balanceOf[to] += wad; emit Transfer(from,to,wad); return true;
    }
}
