// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract MockEURC is ERC20, Ownable {
    constructor() ERC20("Euro Coin", "EURC") {
        _mint(msg.sender, 1000000 * 10**6); // Initial supply of 1,000,000 EURC (with 6 decimals)
    }

    function mint(address to, uint256 amount) public onlyOwner {
        _mint(to, amount);
    }

    function decimals() public view virtual override returns (uint8) {
        return 6;
    }
}