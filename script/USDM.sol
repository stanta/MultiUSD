// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Script, console} from "forge-std/Script.sol";
import {USDM} from "../src/USDM.sol";

contract USDMScript is Script {
    USDM public usdm;

    function setUp() public {}

    function run() public {
        vm.startBroadcast();

        usdm = new USDM();

        vm.stopBroadcast();
    }
}
