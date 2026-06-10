// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

// solhint-disable custom-errors,gas-custom-errors

import "forge-std/console.sol";

import { IICS26Router } from "solidity-ibc-eureka/contracts/interfaces/IICS26Router.sol";
import { ICS27Lib } from "solidity-ibc-eureka/contracts/utils/ICS27Lib.sol";
import { Strings } from "@openzeppelin-contracts/utils/Strings.sol";
import { DeploymentVerifier } from "./VerifyDeployment.sol";

contract RegisterICS27GMP is DeploymentVerifier {
    function run() public {
        string memory root = vm.projectRoot();
        string memory deployEnv = vm.envString("DEPLOYMENT_ENV");
        string memory path =
            string.concat(root, DEPLOYMENT_DIR, "/", deployEnv, "/", Strings.toString(block.chainid), ".json");
        string memory json = vm.readFile(path);

        AccessManagerDeployment memory accessManagerDeployment = loadAccessManagerDeployment(json);
        ProxiedICS26RouterDeployment memory ics26 = loadProxiedICS26RouterDeployment(vm, json);
        ICS27GMPDeployment memory ics27 = loadICS27GMPDeployment(json);

        vm.assertNotEq(accessManagerDeployment.accessManager, address(0), "AccessManager address must not be zero");
        vm.assertNotEq(ics26.proxy, address(0), "ICS26Router proxy must not be zero");
        vm.assertNotEq(ics27.proxy, address(0), "ICS27GMP proxy must not be zero");

        vm.startBroadcast();
        IICS26Router(ics26.proxy).addIBCApp(ICS27Lib.DEFAULT_PORT_ID, ics27.proxy);
        vm.stopBroadcast();

        verifyICS27GMP(ics27, ics26, accessManagerDeployment);
        console.log("Registered ICS27GMP at %s on port %s", ics27.proxy, ICS27Lib.DEFAULT_PORT_ID);
    }
}
