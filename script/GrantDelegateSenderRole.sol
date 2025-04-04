// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import "forge-std/console.sol";

import { Script } from "forge-std/Script.sol";
import { Deployments } from "solidity-ibc-eureka/scripts/helpers/Deployments.sol";
import { ICS20Transfer } from "solidity-ibc-eureka/contracts/ICS20Transfer.sol";
import { Strings } from "@openzeppelin-contracts/utils/Strings.sol";

/// @dev See the Solidity Scripting tutorial: https://book.getfoundry.sh/guides/scripting-with-solidity
contract GrantDelegateSenderRole is Script, Deployments {
    function run() public {
        string memory root = vm.projectRoot();
        string memory deployEnv = vm.envString("DEPLOYMENT_ENV");
        string memory path = string.concat(root, DEPLOYMENT_DIR, "/", deployEnv, "/", Strings.toString(block.chainid), ".json");
        string memory json = vm.readFile(path);

        address delegateSenderAddress = vm.promptAddress("Delegate sender address");

        ProxiedICS20TransferDeployment memory deployment = loadProxiedICS20TransferDeployment(vm, json);
        ICS20Transfer ics20Transfer = ICS20Transfer(deployment.proxy);

        vm.startBroadcast();

        ics20Transfer.grantDelegateSenderRole(delegateSenderAddress);

        vm.stopBroadcast();
    }
}
