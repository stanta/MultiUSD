// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.13;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Mintable.sol";

contract USDM is ERC20, ERC20Mintable, ERC20Burnable {
    constructor() ERC20("MultiUSD", "USDM") {
    }

}
