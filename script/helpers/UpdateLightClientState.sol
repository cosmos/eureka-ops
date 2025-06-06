// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { Deployments } from "./Deployments.sol";
import { Strings } from "@openzeppelin-contracts/utils/Strings.sol";
import { Script } from "forge-std/Script.sol";
import { Strings } from "@openzeppelin-contracts/utils/Strings.sol";
import { SP1ICS07Tendermint } from "solidity-ibc-eureka/contracts/light-clients/SP1ICS07Tendermint.sol";
import { IICS07TendermintMsgs } from "solidity-ibc-eureka/contracts/light-clients/msgs/IICS07TendermintMsgs.sol";
import { IICS02Client } from "solidity-ibc-eureka/contracts/interfaces/IICS02Client.sol";
import { IICS02ClientMsgs } from "solidity-ibc-eureka/contracts/msgs/IICS02ClientMsgs.sol";

contract UpdateLightClientState is Script, Deployments {
    function run() public {
        string memory root = vm.projectRoot();
        string memory deployEnv = vm.envString("DEPLOYMENT_ENV");
        string memory path = string.concat(root, DEPLOYMENT_DIR, "/", deployEnv, "/", Strings.toString(block.chainid), ".json");
        string memory deploymentJson = vm.readFile(path);

        string memory clientID = vm.prompt("Client ID to update state for in the JSON file");

        ProxiedICS26RouterDeployment memory ics26RouterDeployment = loadProxiedICS26RouterDeployment(vm, deploymentJson);
        SP1ICS07TendermintDeployment[] memory deployments = loadSP1ICS07TendermintDeployments(vm, deploymentJson, ics26RouterDeployment.proxy);

        uint256 deploymentIndex = UINT256_MAX;
        for (uint256 i = 0; i < deployments.length; i++) {
            if (Strings.equal(deployments[i].clientId, clientID)) {
                deploymentIndex = uint256(i);
                break;
            }
        }
        vm.assertNotEq(deploymentIndex, UINT256_MAX, "Client ID not found");

        SP1ICS07TendermintDeployment memory deployment = deployments[deploymentIndex];
        SP1ICS07Tendermint ics07Tendermint = SP1ICS07Tendermint(deployment.implementation);

        bytes memory clientStateBz = ics07Tendermint.getClientState();
        IICS07TendermintMsgs.ClientState memory clientState = abi.decode(clientStateBz, (IICS07TendermintMsgs.ClientState));

        bytes32 consensusStateHash = ics07Tendermint.getConsensusStateHash(clientState.latestHeight.revisionHeight);

                // Update the deployment JSON
        vm.writeJson(vm.toString(clientStateBz), path, string.concat(".light_clients['", Strings.toString(deploymentIndex), "'].trustedClientState"));
        vm.writeJson(vm.toString(consensusStateHash), path, string.concat(".light_clients['", Strings.toString(deploymentIndex), "'].trustedConsensusStateHash"));
    }
}

