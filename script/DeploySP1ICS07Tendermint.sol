// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

// solhint-disable custom-errors,gas-custom-errors

import "forge-std/console.sol";
import { SP1ICS07Tendermint } from "solidity-ibc-eureka/contracts/light-clients/sp1-ics07/SP1ICS07Tendermint.sol";
import { Strings } from "@openzeppelin-contracts/utils/Strings.sol";
import { DeploymentVerifier } from "./VerifyDeployment.sol";
import { SP1ICS07TendermintDeployer } from "./helpers/SP1ICS07TendermintDeployer.sol";

contract DeploySP1ICS07TendermintScript is DeploymentVerifier, SP1ICS07TendermintDeployer {
    function run() public {
        string memory root = vm.projectRoot();
        string memory deployEnv = vm.envString("DEPLOYMENT_ENV");
        string memory path =
            string.concat(root, DEPLOYMENT_DIR, "/", deployEnv, "/", Strings.toString(block.chainid), ".json");
        string memory json = vm.readFile(path);

        ProxiedICS26RouterDeployment memory ics26RouterDeployment = loadProxiedICS26RouterDeployment(vm, json);
        SP1ICS07TendermintDeployment[] memory deployments =
            loadSP1ICS07TendermintDeployments(vm, json, ics26RouterDeployment.proxy);

        // CLIENT_ID env var allows non-interactive runs (e.g. CI); fall back to prompting when unset.
        string memory clientID;
        if (vm.envExists("CLIENT_ID")) {
            clientID = vm.envString("CLIENT_ID");
        } else {
            clientID = vm.prompt("Client ID to deploy (leave empty for a new deployment)");
        }

        uint256 deploymentIndex = UINT256_MAX;
        for (uint256 i = 0; i < deployments.length; i++) {
            if (Strings.equal(deployments[i].clientId, clientID)) {
                deploymentIndex = uint256(i);
                break;
            }
        }
        vm.assertNotEq(deploymentIndex, UINT256_MAX, "No deployment found with empty implementation address");

        SP1ICS07TendermintDeployment memory deployment = deployments[deploymentIndex];

        if (deployment.implementation != address(0) && !vm.envOr("SP1_DEPLOY_COPY", false)) {
            string memory confirm = vm.prompt(
                string.concat(
                    "Deployment address already exists for client ID '",
                    deployment.clientId,
                    "'. Do you want to deploy a copy? Type 'y' to confirm: "
                )
            );
            if (!Strings.equal(confirm, "y")) {
                console.log("Deployment cancelled.");
                return;
            }
        }
        vm.assertNotEq(deployment.merklePrefix.length, 0, "Merkle prefix must not be empty");

        bytes[] memory merklePrefix = new bytes[](deployment.merklePrefix.length);
        for (uint256 j = 0; j < deployment.merklePrefix.length; j++) {
            merklePrefix[j] = bytes(deployment.merklePrefix[j]);
        }
        bool canDeployVerifier = _canDeployVerifier(deployEnv);

        vm.startBroadcast();
        SP1ICS07Tendermint ics07Tendermint = deploySP1ICS07Tendermint(deployment, canDeployVerifier);

        deployment.implementation = address(ics07Tendermint);
        deployment.verifier = vm.toString(address(ics07Tendermint.VERIFIER()));

        vm.stopBroadcast();

        string memory idx = Strings.toString(deploymentIndex);
        // NOTE: vm.writeJson only resolves dot-path segments; bracket syntax (".light_clients['0']")
        // is NOT parsed and instead creates a junk top-level key. Use dot notation for the object key.
        string memory key = string.concat(".light_clients.", idx);

        vm.writeJson(vm.toString(deployment.implementation), path, string.concat(key, ".implementation"));
        vm.writeJson(deployment.verifier, path, string.concat(key, ".verifier"));
    }
}
