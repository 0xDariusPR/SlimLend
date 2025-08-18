// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Script, console} from "forge-std/Script.sol";
import {SlimLend} from "../src/SlimLend.sol";

contract SlimLendScript is Script {
    SlimLend public c;

    function setUp() public {}

    function run() public {
        vm.startBroadcast();

        // counter = new Counter();

        vm.stopBroadcast();
    }
}
