// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

// solhint-disable custom-errors,gas-custom-errors

import "forge-std/console.sol";
import { Deployments } from "./helpers/Deployments.sol";
import { SP1ICS07Tendermint } from "solidity-ibc-eureka/contracts/light-clients/SP1ICS07Tendermint.sol";
import { ISP1ICS07Tendermint } from "solidity-ibc-eureka/contracts/light-clients/ISP1ICS07Tendermint.sol";
import { stdJson } from "forge-std/StdJson.sol";
import { SP1Verifier as SP1VerifierPlonk } from "@sp1-contracts/v4.0.0-rc.3/SP1VerifierPlonk.sol";
import { SP1Verifier as SP1VerifierGroth16 } from "@sp1-contracts/v4.0.0-rc.3/SP1VerifierGroth16.sol";
import { SP1MockVerifier } from "@sp1-contracts/SP1MockVerifier.sol";
import { IICS02ClientMsgs } from "solidity-ibc-eureka/contracts/msgs/IICS02ClientMsgs.sol";
import { IICS02Client } from "solidity-ibc-eureka/contracts/interfaces/IICS02Client.sol";
import { IICS07TendermintMsgs } from "solidity-ibc-eureka/contracts/light-clients/msgs/IICS07TendermintMsgs.sol";
import { Strings } from "@openzeppelin-contracts/utils/Strings.sol";
import { Script } from "forge-std/Script.sol";
import { DeploymentVerifier } from "./VerifyDeployment.sol";

contract DeploySP1ICS07TendermintScript is DeploymentVerifier {
    function run() public {
        string memory root = vm.projectRoot();
        string memory deployEnv = vm.envString("DEPLOYMENT_ENV");
        string memory path = string.concat(root, DEPLOYMENT_DIR, "/", deployEnv, "/", Strings.toString(block.chainid), ".json");
        string memory json = vm.readFile(path);

        ProxiedICS26RouterDeployment memory ics26RouterDeployment = loadProxiedICS26RouterDeployment(vm, json);
        SP1ICS07TendermintDeployment[] memory deployments = loadSP1ICS07TendermintDeployments(vm, json, ics26RouterDeployment.proxy);

        string memory clientID = vm.prompt("Client ID to deploy (leave empty for a new deployment)");

        uint256 deploymentIndex = UINT256_MAX;
        for (uint256 i = 0; i < deployments.length; i++) {
            if (Strings.equal(deployments[i].clientId, clientID)) {
                deploymentIndex = uint256(i);
                break;
            }
        }
        vm.assertNotEq(deploymentIndex, UINT256_MAX, "No deployment found with empty implementation address");

        SP1ICS07TendermintDeployment memory deployment = deployments[deploymentIndex];

        if (deployment.implementation != address(0)) {
            string memory confirm = vm.prompt(
                string.concat("Deployment address already exists for client ID '", deployment.clientId, "'. Do you want to deploy a copy? Type 'y' to confirm: ")
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

        vm.startBroadcast();
        SP1ICS07Tendermint ics07Tendermint = deploySP1ICS07Tendermint(deployment);

        deployment.implementation = address(ics07Tendermint);
        deployment.verifier = vm.toString(address(ics07Tendermint.VERIFIER()));

        vm.stopBroadcast();

        string memory idx = Strings.toString(deploymentIndex);
        string memory key = string.concat(".light_clients['", idx, "']");

        vm.writeJson(vm.toString(deployment.implementation), path, string.concat(key, ".implementation"));
        vm.writeJson(deployment.verifier, path, string.concat(key, ".verifier"));
    }

    function deploySP1ICS07Tendermint(SP1ICS07TendermintDeployment memory deployment)
        public
        returns (SP1ICS07Tendermint)
    {
        IICS07TendermintMsgs.ClientState memory trustedClientState =
            abi.decode(deployment.trustedClientState, (IICS07TendermintMsgs.ClientState));

        address verifier = address(0);

        if (keccak256(bytes(deployment.verifier)) == keccak256(bytes("mock"))) {
            verifier = address(new SP1MockVerifier());
        } else if (bytes(deployment.verifier).length > 0) {
            (bool success, address verifierAddr) = Strings.tryParseAddress(deployment.verifier);
            require(success, string.concat("Invalid verifier address: ", deployment.verifier));

            if (verifierAddr == address(0)) {
                revert("Verifier address is zero");
            }

            verifier = verifierAddr;
        } else if (trustedClientState.zkAlgorithm == IICS07TendermintMsgs.SupportedZkAlgorithm.Plonk) {
            verifier = address(new SP1VerifierPlonk());
        } else if (trustedClientState.zkAlgorithm == IICS07TendermintMsgs.SupportedZkAlgorithm.Groth16) {
            verifier = address(new SP1VerifierGroth16());
        } else {
            revert("Unsupported zk algorithm");
        }

        // Deploy the SP1 ICS07 Tendermint light client
        SP1ICS07Tendermint ics07Tendermint = new SP1ICS07Tendermint(
            deployment.updateClientVkey,
            deployment.membershipVkey,
            deployment.ucAndMembershipVkey,
            deployment.misbehaviourVkey,
            verifier,
            deployment.trustedClientState,
            deployment.trustedConsensusStateHash,
            deployment.proofSubmitter
        );

        return ics07Tendermint;
    }
}
