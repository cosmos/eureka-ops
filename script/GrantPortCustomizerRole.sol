// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import "forge-std/console.sol";

import { Script } from "forge-std/Script.sol";
import { Deployments } from "solidity-ibc-eureka/scripts/helpers/Deployments.sol";
import { Strings } from "@openzeppelin-contracts/utils/Strings.sol";
import { ICS26Router } from "solidity-ibc-eureka/contracts/ICS26Router.sol";
import { Escrow } from "solidity-ibc-eureka/contracts/utils/Escrow.sol"; 

/// @dev See the Solidity Scripting tutorial: https://book.getfoundry.sh/guides/scripting-with-solidity
contract GrantPortCustomizerRole is Script, Deployments {
    function run() public {
        string memory root = vm.projectRoot();
        string memory deployEnv = vm.envString("DEPLOYMENT_ENV");
        string memory path = string.concat(root, DEPLOYMENT_DIR, "/", deployEnv, "/", Strings.toString(block.chainid), ".json");
        string memory json = vm.readFile(path);

        address portCustomizerRole = vm.promptAddress("Port customizer address");

        ProxiedICS26RouterDeployment memory deployment = loadProxiedICS26RouterDeployment(vm, json);
        ICS26Router ics26Router = ICS26Router(deployment.proxy);

        vm.startBroadcast();

        ics26Router.grantRole(ics26Router.PORT_CUSTOMIZER_ROLE(), portCustomizerRole);

        vm.stopBroadcast();
    }
}
