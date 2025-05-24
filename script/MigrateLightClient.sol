// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { Deployments } from "./helpers/Deployments.sol";
import { DeploySP1ICS07Tendermint } from "./DeploySP1ICS07Tendermint.sol";
import { Strings } from "@openzeppelin-contracts/utils/Strings.sol";
import { Script } from "forge-std/Script.sol";
import { Strings } from "@openzeppelin-contracts/utils/Strings.sol";
import { SP1ICS07Tendermint } from "solidity-ibc-eureka/contracts/light-clients/SP1ICS07Tendermint.sol";
import { IICS07TendermintMsgs } from "solidity-ibc-eureka/contracts/light-clients/msgs/IICS07TendermintMsgs.sol";
import { IICS02Client } from "solidity-ibc-eureka/contracts/interfaces/IICS02Client.sol";
import { IICS02ClientMsgs } from "solidity-ibc-eureka/contracts/msgs/IICS02ClientMsgs.sol";

contract MigrateSP1ICS07Tendermint is Script, DeploySP1ICS07Tendermint {
    function run() public {
        string memory root = vm.projectRoot();
        string memory deployEnv = vm.envString("DEPLOYMENT_ENV");
        string memory path = string.concat(root, DEPLOYMENT_DIR, "/", deployEnv, "/", Strings.toString(block.chainid), ".json");
        string memory deploymentJson = vm.readFile(path);

        string memory clientIDToMigrate = vm.prompt("Client ID to migrate");

        ProxiedICS26RouterDeployment memory ics26RouterDeployment = loadProxiedICS26RouterDeployment(vm, deploymentJson);
        SP1ICS07TendermintDeployment[] memory deployments = loadSP1ICS07TendermintDeployments(vm, deploymentJson, ics26RouterDeployment.proxy);
        IICS02Client ics26Router = IICS02Client(ics26RouterDeployment.proxy);

        uint256 deploymentIndex = UINT256_MAX;
        for (uint256 i = 0; i < deployments.length; i++) {
            if (Strings.equal(deployments[i].clientId, clientIDToMigrate)) {
                deploymentIndex = uint256(i);
                break;
            }
        }
        vm.assertNotEq(deploymentIndex, UINT256_MAX, "Client ID not found");

        SP1ICS07TendermintDeployment memory deployment = deployments[deploymentIndex];

        vm.startBroadcast();
        SP1ICS07Tendermint ics07Tendermint = deploySP1ICS07Tendermint(deployment);
        deployment.implementation = address(ics07Tendermint);

        bytes[] memory merklePrefix = new bytes[](deployment.merklePrefix.length);
        for (uint256 j = 0; j < deployment.merklePrefix.length; j++) {
            merklePrefix[j] = bytes(deployment.merklePrefix[j]);
        }
        IICS02ClientMsgs.CounterpartyInfo memory counterPartyInfo = IICS02ClientMsgs.CounterpartyInfo(deployment.counterpartyClientId, merklePrefix);

        ics26Router.migrateClient(clientIDToMigrate, counterPartyInfo, address(ics07Tendermint));
        // TODO: Make this an output that can be used as a multisig prop

        vm.stopBroadcast();

        // Update the deployment JSON
        vm.writeJson(vm.toString(deployment.implementation), path, string.concat(".light_clients['", Strings.toString(deploymentIndex), "'].implementation"));
    }
}
