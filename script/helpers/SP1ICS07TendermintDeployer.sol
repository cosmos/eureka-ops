// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { Deployments } from "./Deployments.sol";
import { SP1ICS07Tendermint } from "solidity-ibc-eureka/contracts/light-clients/sp1-ics07/SP1ICS07Tendermint.sol";
import {
    IICS07TendermintMsgs
} from "solidity-ibc-eureka/contracts/light-clients/sp1-ics07/msgs/IICS07TendermintMsgs.sol";
import { SP1Verifier as SP1VerifierPlonk } from "@sp1-contracts/v6.1.0/SP1VerifierPlonk.sol";
import { SP1Verifier as SP1VerifierGroth16 } from "@sp1-contracts/v6.1.0/SP1VerifierGroth16.sol";
import { SP1MockVerifier } from "@sp1-contracts/SP1MockVerifier.sol";
import { Strings } from "@openzeppelin-contracts/utils/Strings.sol";

abstract contract SP1ICS07TendermintDeployer is Deployments {
    function _canDeployVerifier(string memory deployEnv) internal pure returns (bool) {
        return Strings.equal(deployEnv, "local") || Strings.equal(deployEnv, "shadow-mainnet")
            || Strings.equal(deployEnv, "shadow-sepolia");
    }

    function deploySP1ICS07Tendermint(
        SP1ICS07TendermintDeployment memory deployment,
        bool canDeployVerifier
    )
        internal
        returns (SP1ICS07Tendermint)
    {
        IICS07TendermintMsgs.ClientState memory trustedClientState =
            abi.decode(deployment.trustedClientState, (IICS07TendermintMsgs.ClientState));

        address verifier = address(0);

        if (keccak256(bytes(deployment.verifier)) == keccak256(bytes("mock"))) {
            if (!canDeployVerifier) {
                revert("Mock SP1 verifier only allowed for local/default shadow deployments");
            }
            verifier = address(new SP1MockVerifier());
        } else if (bytes(deployment.verifier).length > 0) {
            (bool success, address verifierAddr) = Strings.tryParseAddress(deployment.verifier);
            require(success, string.concat("Invalid verifier address: ", deployment.verifier));

            if (verifierAddr == address(0)) {
                revert("Verifier address is zero");
            }

            verifier = verifierAddr;
        } else if (!canDeployVerifier) {
            revert("SP1 verifier address required for non-local deployments");
        } else if (trustedClientState.zkAlgorithm == IICS07TendermintMsgs.SupportedZkAlgorithm.Plonk) {
            verifier = address(new SP1VerifierPlonk());
        } else if (trustedClientState.zkAlgorithm == IICS07TendermintMsgs.SupportedZkAlgorithm.Groth16) {
            verifier = address(new SP1VerifierGroth16());
        } else {
            revert("Unsupported zk algorithm");
        }

        return new SP1ICS07Tendermint(
            deployment.updateClientVkey,
            deployment.membershipVkey,
            deployment.ucAndMembershipVkey,
            deployment.misbehaviourVkey,
            verifier,
            deployment.trustedClientState,
            deployment.trustedConsensusStateHash,
            deployment.proofSubmitter
        );
    }
}
