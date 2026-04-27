// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.25;

contract WETH9 {
    string public name = "Wrapped Ether";
    string public symbol = "WETH";
    uint8 public decimals = 18;

    event Approval(address indexed src, address indexed guy, uint256 wad);
    event Transfer(address indexed src, address indexed dst, uint256 wad);
    event Deposit(address indexed dst, uint256 wad);
    event Withdrawal(address indexed src, uint256 wad);

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    receive() external payable {
        deposit();
    }

    function deposit() public payable {
        require(msg.value > 0, "WETH9: ZERO_DEPOSIT");
        balanceOf[msg.sender] += msg.value;
        emit Deposit(msg.sender, msg.value);
    }

    function withdraw(uint256 wad) public {
        require(balanceOf[msg.sender] >= wad, "WETH9: INSUFFICIENT_BALANCE");

        unchecked {
            balanceOf[msg.sender] -= wad;
        }

        (bool ok,) = msg.sender.call{value: wad}("");
        require(ok, "WETH9: ETH_TRANSFER_FAILED");

        emit Withdrawal(msg.sender, wad);
    }

    function totalSupply() public view returns (uint256) {
        return address(this).balance;
    }

    function approve(address guy, uint256 wad) public returns (bool) {
        allowance[msg.sender][guy] = wad;
        emit Approval(msg.sender, guy, wad);
        return true;
    }

    function transfer(address dst, uint256 wad) public returns (bool) {
        return transferFrom(msg.sender, dst, wad);
    }

    function transferFrom(address src, address dst, uint256 wad) public returns (bool) {
        require(balanceOf[src] >= wad, "WETH9: INSUFFICIENT_BALANCE");

        if (src != msg.sender) {
            uint256 allowed = allowance[src][msg.sender];
            if (allowed != type(uint256).max) {
                require(allowed >= wad, "WETH9: INSUFFICIENT_ALLOWANCE");
                unchecked {
                    allowance[src][msg.sender] = allowed - wad;
                }
            }
        }

        unchecked {
            balanceOf[src] -= wad;
        }
        balanceOf[dst] += wad;

        emit Transfer(src, dst, wad);
        return true;
    }
}
