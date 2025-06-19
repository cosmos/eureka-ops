// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

// solhint-disable custom-errors,gas-custom-errors

import "forge-std/console.sol";
import { Deployments } from "./helpers/Deployments.sol";
import { ICS26Router } from "solidity-ibc-eureka/contracts/ICS26Router.sol";
import { IBCPausableUpgradeable } from "solidity-ibc-eureka/contracts/utils/IBCPausableUpgradeable.sol";
import { IIBCUUPSUpgradeable } from "solidity-ibc-eureka/contracts/interfaces/IIBCUUPSUpgradeable.sol";
import { ICS20Transfer } from "solidity-ibc-eureka/contracts/ICS20Transfer.sol";
import { ICS20Lib } from "solidity-ibc-eureka/contracts/utils/ICS20Lib.sol";
import { IBeacon } from "@openzeppelin-contracts/proxy/beacon/IBeacon.sol";
import { IICS26Router } from "solidity-ibc-eureka/contracts/interfaces/IICS26Router.sol";
import { SP1ICS07Tendermint } from "solidity-ibc-eureka/contracts/light-clients/SP1ICS07Tendermint.sol";
import { ERC1967Proxy } from "@openzeppelin-contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { ERC1967Utils } from "@openzeppelin-contracts/proxy/ERC1967/ERC1967Utils.sol";
import { ISP1ICS07Tendermint } from "solidity-ibc-eureka/contracts/light-clients/ISP1ICS07Tendermint.sol";
import { stdJson } from "forge-std/StdJson.sol";
import { SP1Verifier as SP1VerifierPlonk } from "@sp1-contracts/v5.0.0/SP1VerifierPlonk.sol";
import { SP1Verifier as SP1VerifierGroth16 } from "@sp1-contracts/v5.0.0/SP1VerifierGroth16.sol";
import { SP1MockVerifier } from "@sp1-contracts/SP1MockVerifier.sol";
import { IICS02ClientMsgs } from "solidity-ibc-eureka/contracts/msgs/IICS02ClientMsgs.sol";
import { IICS02Client } from "solidity-ibc-eureka/contracts/interfaces/IICS02Client.sol";
import { IICS07TendermintMsgs } from "solidity-ibc-eureka/contracts/light-clients/msgs/IICS07TendermintMsgs.sol";
import { Strings } from "@openzeppelin-contracts/utils/Strings.sol";
import { Script } from "forge-std/Script.sol";


abstract contract DeploymentVerifier is Deployments, Script {
    function getImplementation(address proxy) internal view returns (address) {
        return address(uint160(uint256(vm.load(proxy, ERC1967Utils.IMPLEMENTATION_SLOT))));
    }

    function verifyICS26Router(ProxiedICS26RouterDeployment memory deployment) internal view {
        ERC1967Proxy routerProxy = ERC1967Proxy(payable(deployment.proxy));

        vm.assertEq(
            getImplementation(address(routerProxy)),
            deployment.implementation,
            "implementation addresses don't match"
        );

        IIBCUUPSUpgradeable uups = IIBCUUPSUpgradeable(address(routerProxy));
        ICS26Router ics26Router = ICS26Router(address(routerProxy));

        vm.assertEq(
            uups.getTimelockedAdmin(),
            deployment.timelockAdmin,
            "timelockAdmin addresses don't match"
        );

        if (deployment.portCustomizer != address(0)) {
            vm.assertTrue(
                ics26Router.hasRole(
                    ics26Router.PORT_CUSTOMIZER_ROLE(),
                    deployment.portCustomizer
                ),
                "portCustomizer role not granted"
            );
        }

        if (deployment.clientIdCustomizer != address(0)) {
            vm.assertTrue(
                ics26Router.hasRole(
                    ics26Router.CLIENT_ID_CUSTOMIZER_ROLE(),
                    deployment.clientIdCustomizer
                ),
                "clientIdCustomizer role not granted"
            );
        }

        if (deployment.relayers.length != 0) {
            for (uint32 i = 0; i < deployment.relayers.length; i++) {
                vm.assertTrue(
                    ics26Router.hasRole(
                        ics26Router.RELAYER_ROLE(),
                        deployment.relayers[i]
                    ),
                    string.concat("relayer role not granted to ", vm.toString(deployment.relayers[i]))
                );
            }
        }
    }

    function verifyICS20Transfer(ProxiedICS20TransferDeployment memory deployment) internal view {
        ERC1967Proxy transferProxy = ERC1967Proxy(payable(deployment.proxy));

        vm.assertEq(
            getImplementation(address(transferProxy)),
            deployment.implementation,
            "implementation addresses don't match"
        );

        ICS20Transfer ics20Transfer = ICS20Transfer(deployment.proxy);

        vm.assertEq(
            ics20Transfer.ics26(),
            deployment.ics26Router,
            "ics26Router addresses don't match"
        );

        vm.assertEq(
            IBeacon(ics20Transfer.getEscrowBeacon()).implementation(),
            deployment.escrowImplementation,
            "escrow addresses don't match"
        );

        vm.assertEq(
            IBeacon(ics20Transfer.getIBCERC20Beacon()).implementation(),
            deployment.ibcERC20Implementation,
            "ibcERC20 addresses don't match"
        );

        vm.assertEq(
            ics20Transfer.getPermit2(),
            deployment.permit2,
            "permit2 addresses don't match"
        );

        IICS26Router ics26Router = IICS26Router(deployment.ics26Router);
        address transferApp = address(ics26Router.getIBCApp(ICS20Lib.DEFAULT_PORT_ID));
        vm.assertEq(
            transferApp,
            deployment.proxy,
            "transfer app address doesn't match with the one in ics26Router"
        );

        if (deployment.pausers.length != 0) {
            for (uint32 i = 0; i < deployment.pausers.length; i++) {
                address pauser = deployment.pausers[i];

                IBCPausableUpgradeable ipu = IBCPausableUpgradeable(address(transferProxy));

                vm.assertTrue(
                    ipu.hasRole(ipu.PAUSER_ROLE(), pauser),
                    string.concat("pauser address (", Strings.toHexString(pauser), ") doesn't have pauser role")
                );
            }
        }

        if (deployment.unpausers.length != 0) {
            for (uint32 i = 0; i < deployment.unpausers.length; i++) {
                address unpauser = deployment.unpausers[i];

                IBCPausableUpgradeable ipu = IBCPausableUpgradeable(address(transferProxy));

                vm.assertTrue(
                    ipu.hasRole(ipu.UNPAUSER_ROLE(), unpauser),
                    string.concat("unpauser address (", Strings.toHexString(unpauser), ") doesn't have unpauser role")
                );
            }
        }

        if (deployment.tokenOperator != address(0)) {
            IBCPausableUpgradeable ipu = IBCPausableUpgradeable(address(transferProxy));

            vm.assertTrue(
                ipu.hasRole(ics20Transfer.TOKEN_OPERATOR_ROLE(), deployment.tokenOperator),
                string.concat("tokenOperator address (", Strings.toHexString(deployment.tokenOperator), ") doesn't have tokenOperator role")
            );
        }
    }



    function verifyICS07Tendermint(
        SP1ICS07TendermintDeployment memory deployment,
        ProxiedICS26RouterDeployment memory ics26RouterDeployment
    ) internal view {
        vm.assertNotEq(deployment.implementation, address(0), "implementation address is zero");

        ISP1ICS07Tendermint ics07Tendermint = ISP1ICS07Tendermint(deployment.implementation);
        address actualVerifierAddress = address(ics07Tendermint.VERIFIER());

        (bool success, address verifierAddr) = Strings.tryParseAddress(deployment.verifier);

        IICS02Client router = IICS02Client(ics26RouterDeployment.proxy);

        vm.assertEq(
            address(router.getClient(deployment.clientId)),
            deployment.implementation,
            "address of clientId in ics26Router doesn't match implementation address"
        );

        vm.assertTrue(
            success,
            string.concat(
                "Invalid verifier address: ",
                deployment.verifier,
                " (actual address: ",
                vm.toString(actualVerifierAddress),
                ")"
            )
        );

        vm.assertEq(
            actualVerifierAddress,
            verifierAddr,
            "verifier address doesn't match"
        );

        vm.assertEq(
            ics07Tendermint.MEMBERSHIP_PROGRAM_VKEY(),
            deployment.membershipVkey,
            "membershipVkey doesn't match"
        );

        vm.assertEq(
            ics07Tendermint.MISBEHAVIOUR_PROGRAM_VKEY(),
            deployment.misbehaviourVkey,
            "misbehaviourVkey doesn't match"
        );

        vm.assertEq(
            ics07Tendermint.UPDATE_CLIENT_PROGRAM_VKEY(),
            deployment.updateClientVkey,
            "updateClientVkey doesn't match"
        );
        vm.assertEq(
            ics07Tendermint.UPDATE_CLIENT_AND_MEMBERSHIP_PROGRAM_VKEY(),
            deployment.ucAndMembershipVkey,
            "ucAndMembershipVkey doesn't match"
        );

        IICS02ClientMsgs.CounterpartyInfo memory counterparty = router.getCounterparty(deployment.clientId);

        for (uint256 i = 0; i < counterparty.merklePrefix.length; i++) {
            vm.assertEq(
                counterparty.merklePrefix[i],
                bytes(deployment.merklePrefix[i]),
                "merklePrefix doesn't match"
            );
        }

        vm.assertEq(
            counterparty.clientId,
            deployment.counterpartyClientId,
            "counterpartyClientId doesn't match"
        );
    }

}

contract VerifyDeployment is DeploymentVerifier {
    function run() view public {
        string memory root = vm.projectRoot();
        string memory deployEnv = vm.envString("DEPLOYMENT_ENV");
        string memory path = string.concat(root, DEPLOYMENT_DIR, "/", deployEnv, "/", Strings.toString(block.chainid), ".json");
        string memory json = vm.readFile(path);


        ProxiedICS26RouterDeployment memory ics26RouterDeployment = loadProxiedICS26RouterDeployment(vm, json);
        ProxiedICS20TransferDeployment memory ics20TransferDeployment = loadProxiedICS20TransferDeployment(vm, json);
        SP1ICS07TendermintDeployment[] memory ics07Deployments = loadSP1ICS07TendermintDeployments(vm, json, ics26RouterDeployment.proxy);

        console.log("Verifying deployment at path: %s", path);

        console.log("Verifying ICS26Router...");
        verifyICS26Router(ics26RouterDeployment);
        console.log("Verifying ICS20Transfer...");
        verifyICS20Transfer(ics20TransferDeployment);

        for (uint256 i = 0; i < ics07Deployments.length; i++) {
            console.log("Verifying ICS07Tendermint deployment %s...", ics07Deployments[i].clientId);
            verifyICS07Tendermint(ics07Deployments[i], ics26RouterDeployment);
        }
    }
}

