
// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

// solhint-disable gas-custom-errors,no-global-import

import "forge-std/console.sol";

import { Script } from "forge-std/Script.sol";
import { Deployments } from "./helpers/Deployments.sol";
import { Strings } from "@openzeppelin-contracts/utils/Strings.sol";
import { stdJson } from "forge-std/StdJson.sol";
import { UUPSUpgradeable } from "@openzeppelin-contracts/proxy/utils/UUPSUpgradeable.sol";
import { ERC1967Utils } from "@openzeppelin-contracts/proxy/ERC1967/ERC1967Utils.sol";

contract UpgradeProxy is Script, Deployments {
    using stdJson for string;

    function run() public {
        string memory root = vm.projectRoot();
        string memory deployEnv = vm.envString("DEPLOYMENT_ENV");
        string memory path = string.concat(root, DEPLOYMENT_DIR, "/", deployEnv, "/", Strings.toString(block.chainid), ".json");
        string memory json = vm.readFile(path);

        ProxiedICS26RouterDeployment memory ics26RouterDeployment = loadProxiedICS26RouterDeployment(vm, json);
        ProxiedICS20TransferDeployment memory ics20TransferDeployment = loadProxiedICS20TransferDeployment(vm, json);

        address ics26ActualImpl = address(uint160(uint256(vm.load(ics26RouterDeployment.proxy, ERC1967Utils.IMPLEMENTATION_SLOT))));
        bool ics26Changed = ics26ActualImpl != ics26RouterDeployment.implementation;

        address ics20ActualImpl = address(uint160(uint256(vm.load(ics20TransferDeployment.proxy, ERC1967Utils.IMPLEMENTATION_SLOT))));
        bool ics20Changed = ics20ActualImpl != ics20TransferDeployment.implementation;

        // Ensure that only one of the contracts has changed
        require(ics26Changed != ics20Changed, "One (and only one) of the uups upgradable contract implementations should have changed in the deployment json to run this script");

        vm.startBroadcast();
        if (ics26Changed) {
            UUPSUpgradeable(ics26RouterDeployment.proxy).upgradeToAndCall(
                ics26RouterDeployment.implementation,
                bytes("") // TODO: if we need new initialization parameters, we need to find a way to pass them here
            );
            console.log("ICS26 Router upgraded to: ", ics26RouterDeployment.implementation);
        } else if (ics20Changed) {
            UUPSUpgradeable(ics20TransferDeployment.proxy).upgradeToAndCall(
                ics20TransferDeployment.implementation,
                bytes("") // TODO: if we need new initialization parameters, we need to find a way to pass them here
            );
            console.log("ICS20 Transfer upgraded to: ", ics20TransferDeployment.implementation);
        } else {
            revert("Should not reach here, one of the contracts should have changed");
        }
        vm.stopBroadcast();
    }
}
