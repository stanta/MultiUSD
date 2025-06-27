// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.24;

import "@openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin-contracts/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import "@openzeppelin-contracts/contracts/access/Ownable.sol";

contract USDM is ERC20, ERC20Burnable, Ownable {
    constructor() ERC20("MultiUSD", "USDM") Ownable(msg.sender) {
        // Initial minting to the owner
        _mint(msg.sender, 1000000 * 10 ** decimals()); // Mint 1 million tokens
    }
    function mint (address to, uint256 amount) public onlyOwner {
        _mint(to, amount);
    }

    //todo add to transfer() some fee to owner ))
}
