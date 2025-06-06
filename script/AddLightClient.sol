// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

// solhint-disable custom-errors,gas-custom-errors

import "forge-std/console.sol";
import { Deployments } from "./helpers/Deployments.sol";
import { SP1ICS07Tendermint } from "solidity-ibc-eureka/contracts/light-clients/SP1ICS07Tendermint.sol";
import { ISP1ICS07Tendermint } from "solidity-ibc-eureka/contracts/light-clients/ISP1ICS07Tendermint.sol";
import { stdJson } from "forge-std/StdJson.sol";
import { IICS02ClientMsgs } from "solidity-ibc-eureka/contracts/msgs/IICS02ClientMsgs.sol";
import { IICS02Client } from "solidity-ibc-eureka/contracts/interfaces/IICS02Client.sol";
import { IICS07TendermintMsgs } from "solidity-ibc-eureka/contracts/light-clients/msgs/IICS07TendermintMsgs.sol";
import { Strings } from "@openzeppelin-contracts/utils/Strings.sol";
import { Script } from "forge-std/Script.sol";
import { DeploymentVerifier } from "./VerifyDeployment.sol";

contract AddLightClient is DeploymentVerifier {
    function run() public {
        string memory root = vm.projectRoot();
        string memory deployEnv = vm.envString("DEPLOYMENT_ENV");
        string memory path = string.concat(root, DEPLOYMENT_DIR, "/", deployEnv, "/", Strings.toString(block.chainid), ".json");
        string memory json = vm.readFile(path);

        ProxiedICS26RouterDeployment memory ics26RouterDeployment = loadProxiedICS26RouterDeployment(vm, json);
        SP1ICS07TendermintDeployment[] memory deployments = loadSP1ICS07TendermintDeployments(vm, json, ics26RouterDeployment.proxy);

        IICS02Client ics26Router = IICS02Client(ics26RouterDeployment.proxy);

        uint256 deploymentIndex = UINT256_MAX;
        for (uint256 i = 0; i < deployments.length; i++) {
            if (Strings.equal(deployments[i].clientId, "")) {
                deploymentIndex = uint256(i);
                break;
            }
        }
        vm.assertNotEq(deploymentIndex, UINT256_MAX, "No deployment found with empty clientId");
        SP1ICS07TendermintDeployment memory deployment = deployments[deploymentIndex];

        string memory clientID = vm.prompt("Client ID to add (leave empty for generated client id):");
        deployment.clientId = clientID;

        vm.assertNotEq(deployment.merklePrefix.length, 0, "Merkle prefix must not be empty");

        bytes[] memory merklePrefix = new bytes[](deployment.merklePrefix.length);
        for (uint256 j = 0; j < deployment.merklePrefix.length; j++) {
            merklePrefix[j] = bytes(deployment.merklePrefix[j]);
        }

        vm.startBroadcast();

        IICS02ClientMsgs.CounterpartyInfo memory counterPartyInfo = IICS02ClientMsgs.CounterpartyInfo(deployment.counterpartyClientId, merklePrefix);
        if (bytes(deployment.clientId).length == 0) {
            deployment.clientId = ics26Router.addClient(counterPartyInfo, deployment.implementation);
        } else {
            ics26Router.addClient(deployment.clientId, counterPartyInfo, deployment.implementation);
        }

        vm.stopBroadcast();

        verifyICS07Tendermint(deployment, ics26RouterDeployment);

        string memory idx = Strings.toString(deploymentIndex);
        string memory key = string.concat(".light_clients['", idx, "']");

        vm.writeJson(deployment.clientId, path, string.concat(key, ".clientId"));
    }
}
