// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Test, console} from "forge-std/Test.sol";
import {USDM} from "../src/USDM.sol";

contract USDMTest is Test {
    USDM public usdm;

    function setUp() public {
        usdm = new USDM();
        // usdm.setNumber(0);
    }
    function testMint() public {
        uint256 initialBalance = usdm.balanceOf(address(this));
        usdm.mint(address(this), 1000);
        uint256 newBalance = usdm.balanceOf(address(this));
        assertEq(newBalance, initialBalance + 1000, "Minting failed");
    }
    function testBurn() public {
        usdm.mint(address(this), 1000);
        uint256 initialBalance = usdm.balanceOf(address(this));
        usdm.burn(500);
        uint256 newBalance = usdm.balanceOf(address(this));
        assertEq(newBalance, initialBalance - 500, "Burning failed");   
    }
}
