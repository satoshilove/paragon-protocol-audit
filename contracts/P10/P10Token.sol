// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";

contract P10Token is ERC20, Ownable2Step {
    address public indexManager;

    event IndexManagerUpdated(address indexed oldManager, address indexed newManager);

    constructor(address initialOwner)
        ERC20("Paragon P10 Index", "P10")
        Ownable(initialOwner)
    {}

    modifier onlyIndexManager() {
        require(msg.sender == indexManager, "P10: not index manager");
        _;
    }

    function setIndexManager(address _manager) external onlyOwner {
        require(_manager != address(0), "P10: zero manager");
        emit IndexManagerUpdated(indexManager, _manager);
        indexManager = _manager;
    }

    function mint(address to, uint256 amount) external onlyIndexManager {
        _mint(to, amount);
    }

    function burn(address from, uint256 amount) external onlyIndexManager {
        _burn(from, amount);
    }
}
