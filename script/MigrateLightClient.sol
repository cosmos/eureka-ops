

// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { Deployments } from "solidity-ibc-eureka/scripts/helpers/Deployments.sol";
import { Strings } from "@openzeppelin-contracts/utils/Strings.sol";
import { Script } from "forge-std/Script.sol";
import { Strings } from "@openzeppelin-contracts/utils/Strings.sol";
import { SP1ICS07Tendermint } from "solidity-ibc-eureka/contracts/light-clients/SP1ICS07Tendermint.sol";
import { IICS07TendermintMsgs } from "solidity-ibc-eureka/contracts/light-clients/msgs/IICS07TendermintMsgs.sol";
import { IICS02Client } from "solidity-ibc-eureka/contracts/interfaces/IICS02Client.sol";
import { IICS02ClientMsgs } from "solidity-ibc-eureka/contracts/msgs/IICS02ClientMsgs.sol";

contract MigrateSP1ICS07Tendermint is Script, Deployments {
    function run() public {
        string memory root = vm.projectRoot();
        string memory deployEnv = vm.envString("DEPLOYMENT_ENV");
        string memory path = string.concat(root, DEPLOYMENT_DIR, "/", deployEnv, "/", Strings.toString(block.chainid), ".json");
        string memory deploymentJson = vm.readFile(path);

        string memory clientIDToMigrate = vm.prompt("Client ID to migrate");
        string memory substituteClientID = vm.prompt("Client ID to migrate to");

        ProxiedICS26RouterDeployment memory ics26RouterDeployment = loadProxiedICS26RouterDeployment(vm, deploymentJson);
        SP1ICS07TendermintDeployment[] memory deployments = loadSP1ICS07TendermintDeployments(vm, deploymentJson, ics26RouterDeployment.proxy);

        uint256 deploymentIndex = UINT256_MAX;
        for (uint256 i = 0; i < deployments.length; i++) {
            if (Strings.equal(deployments[i].clientId, clientIDToMigrate)) {
                deploymentIndex = uint256(i);
                break;
            }
        }
        vm.assertNotEq(deploymentIndex, UINT256_MAX, "Client ID not found");

        uint256 deploymentIndexToMigrateTo = UINT256_MAX;
        for (uint256 i = 0; i < deployments.length; i++) {
            if (Strings.equal(deployments[i].clientId, substituteClientID)) {
                deploymentIndexToMigrateTo = uint256(i);
                break;
            }
        }
        vm.assertNotEq(deploymentIndexToMigrateTo, UINT256_MAX, "Client ID not found");
        SP1ICS07TendermintDeployment memory deploymentToMigrateTo = deployments[deploymentIndexToMigrateTo];
        address replacementLightClient = deploymentToMigrateTo.implementation;

        vm.startBroadcast();

        IICS02Client ics26Router = IICS02Client(ics26RouterDeployment.proxy);

        // TODO: Make this an output that can be used as a multisig prop
        ics26Router.migrateClient(clientIDToMigrate, substituteClientID);

        vm.stopBroadcast();

        // Update the deployment JSON
        vm.writeJson(vm.toString(address(replacementLightClient)), path, string.concat(".light_clients['", Strings.toString(deploymentIndex), "'].implementation"));
        vm.writeJson(deploymentToMigrateTo.verifier, path, string.concat(".light_clients['", Strings.toString(deploymentIndex), "'].verifier"));
        vm.writeJson(deploymentToMigrateTo.counterpartyClientId, path, string.concat(".light_clients['", Strings.toString(deploymentIndex), "'].counterpartyClientId"));
        for (uint256 i = 0; i < deploymentToMigrateTo.merklePrefix.length; i++) {
            vm.writeJson(deploymentToMigrateTo.merklePrefix[i], path, string.concat(".light_clients['", Strings.toString(deploymentIndex), "'].merklePrefix[", Strings.toString(i), "]"));
        }
        vm.writeJson(vm.toString(deploymentToMigrateTo.trustedClientState), path, string.concat(".light_clients['", Strings.toString(deploymentIndex), "'].trustedClientState"));
        vm.writeJson(vm.toString(deploymentToMigrateTo.trustedConsensusState), path, string.concat(".light_clients['", Strings.toString(deploymentIndex), "'].trustedConsensusState"));
        vm.writeJson(vm.toString(deploymentToMigrateTo.updateClientVkey), path, string.concat(".light_clients['", Strings.toString(deploymentIndex), "'].updateClientVkey"));
        vm.writeJson(vm.toString(deploymentToMigrateTo.membershipVkey), path, string.concat(".light_clients['", Strings.toString(deploymentIndex), "'].membershipVkey"));
        vm.writeJson(vm.toString(deploymentToMigrateTo.ucAndMembershipVkey), path, string.concat(".light_clients['", Strings.toString(deploymentIndex), "'].ucAndMembershipVkey"));
        vm.writeJson(vm.toString(deploymentToMigrateTo.misbehaviourVkey), path, string.concat(".light_clients['", Strings.toString(deploymentIndex), "'].misbehaviourVkey"));
    }
}
