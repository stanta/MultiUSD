// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.13;

import "@openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin-contracts/contracts/token/ERC20/extensions/ERC20Burnable.sol";

contract USDM is ERC20, ERC20Burnable {
    constructor() ERC20("MultiUSD", "USDM") {
    }
    function mint (address to, uint256 amount) public {
        _mint(to, amount);
    }

}
