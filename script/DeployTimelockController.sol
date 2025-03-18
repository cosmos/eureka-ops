// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { Script } from "forge-std/Script.sol";
import { TimelockController } from "@openzeppelin-contracts/governance/TimelockController.sol";

contract DeployTimelockController is Script{
    function runAddAdmin() public returns (address) {
        TimelockController tlc = TimelockController(payable(address(0x098692EdFDb0b584c4B54F252eCaC432230F14C4)));
        address gnosis = address(0xdeec336F932494DEC4b7924cf9A610edE1044E03);

        vm.startBroadcast();
        tlc.grantRole(tlc.DEFAULT_ADMIN_ROLE(), gnosis);
        tlc.grantRole(tlc.PROPOSER_ROLE(), gnosis);
        tlc.grantRole(tlc.CANCELLER_ROLE(), gnosis);
        tlc.grantRole(tlc.EXECUTOR_ROLE(), gnosis);
        vm.stopBroadcast();

        return address(0);
    }

    function run() public returns (address){
        address safe = address(0xdbeA281e021F4986106e6b377ba22cB7A32eA9dB);
        address[] memory proposers = new address[](1);
        proposers[0] = safe;

        vm.startBroadcast();
        TimelockController tlc = new TimelockController(60, proposers, proposers, safe);
        vm.stopBroadcast();

        return address(tlc);
    }
}
