// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

// solhint-disable custom-errors,gas-custom-errors

import "forge-std/console.sol";

import { UUPSUpgradeable } from "@openzeppelin-contracts/proxy/utils/UUPSUpgradeable.sol";
import { Strings } from "@openzeppelin-contracts/utils/Strings.sol";
import { ICS20Transfer } from "solidity-ibc-eureka/contracts/ICS20Transfer.sol";
import { IICS02Client } from "solidity-ibc-eureka/contracts/interfaces/IICS02Client.sol";
import { IICS02ClientMsgs } from "solidity-ibc-eureka/contracts/msgs/IICS02ClientMsgs.sol";
import { IICS20TransferAccessControlled } from "solidity-ibc-eureka/contracts/interfaces/IICS20Transfer.sol";
import { IICS26Router } from "solidity-ibc-eureka/contracts/interfaces/IICS26Router.sol";
import { ICS26Router } from "solidity-ibc-eureka/contracts/ICS26Router.sol";
import { SP1ICS07Tendermint } from "solidity-ibc-eureka/contracts/light-clients/sp1-ics07/SP1ICS07Tendermint.sol";
import { Escrow } from "solidity-ibc-eureka/contracts/utils/Escrow.sol";
import { IBCERC20 } from "solidity-ibc-eureka/contracts/utils/IBCERC20.sol";
import { ICS27Lib } from "solidity-ibc-eureka/contracts/utils/ICS27Lib.sol";
import { V3AccessManagerBootstrap } from "./DeployV3AccessManager.sol";
import { DeploymentVerifier } from "./VerifyDeployment.sol";
import { SP1ICS07TendermintDeployer } from "./helpers/SP1ICS07TendermintDeployer.sol";

contract ShadowForkV2ToV3Upgrade is DeploymentVerifier, SP1ICS07TendermintDeployer {
    function run() public {
        string memory root = vm.projectRoot();
        string memory deployEnv = vm.envString("DEPLOYMENT_ENV");
        string memory path =
            string.concat(root, DEPLOYMENT_DIR, "/", deployEnv, "/", Strings.toString(block.chainid), ".json");
        string memory json = vm.readFile(path);

        AccessManagerDeployment memory accessManagerDeployment = loadAccessManagerDeployment(json);
        ProxiedICS26RouterDeployment memory ics26 = loadProxiedICS26RouterDeployment(vm, json);
        ProxiedICS20TransferDeployment memory ics20 = loadProxiedICS20TransferDeployment(vm, json);
        ICS27GMPDeployment memory ics27 = loadICS27GMPDeployment(json);
        SP1ICS07TendermintDeployment[] memory ics07Deployments =
            loadSP1ICS07TendermintDeployments(vm, json, ics26.proxy);
        string[] memory sp1ClientIds = vm.envOr("SP1_CLIENT_IDS", ",", new string[](0));
        bool canDeployVerifier = _canDeployVerifier(deployEnv);

        vm.assertEq(accessManagerDeployment.accessManager, address(0), "deployment JSON already has accessManager");
        vm.assertNotEq(accessManagerDeployment.admin, address(0), "timelock admin must be set");
        vm.assertNotEq(ics26.proxy, address(0), "ICS26Router proxy must be set");
        vm.assertNotEq(ics20.proxy, address(0), "ICS20Transfer proxy must be set");
        vm.assertEq(ics27.proxy, address(0), "deployment JSON already has ICS27GMP");
        vm.assertNotEq(accessManagerDeployment.idCustomizers.length, 0, "ID customizer must be set");

        console.log("Using shadow deployment: %s", path);
        console.log("Impersonating upgrade admin: %s", accessManagerDeployment.admin);

        vm.startBroadcast();
        V3AccessManagerBootstrap bootstrap = new V3AccessManagerBootstrap(accessManagerDeployment, ics26, ics20);
        accessManagerDeployment.accessManager = bootstrap.accessManager();
        ics27 = ICS27GMPDeployment({
            implementation: bootstrap.ics27GmpImplementation(),
            accountImplementation: bootstrap.ics27AccountImplementation(),
            proxy: bootstrap.ics27Gmp()
        });

        ics20.implementation = address(new ICS20Transfer());
        ics26.implementation = address(new ICS26Router());
        ics20.escrowImplementation = address(new Escrow());
        ics20.ibcERC20Implementation = address(new IBCERC20());
        uint256 sp1Deployments = _deployPlannedLightClients(ics07Deployments, sp1ClientIds, canDeployVerifier);
        vm.stopBroadcast();
        _writePlannedLightClients(path, ics07Deployments, sp1ClientIds);

        vm.startBroadcast(accessManagerDeployment.admin);
        UUPSUpgradeable(ics20.proxy)
            .upgradeToAndCall(
                ics20.implementation,
                abi.encodeCall(ICS20Transfer.initializeV2, (accessManagerDeployment.accessManager))
            );
        UUPSUpgradeable(ics26.proxy)
            .upgradeToAndCall(
                ics26.implementation, abi.encodeCall(ICS26Router.initializeV2, (accessManagerDeployment.accessManager))
            );
        IICS20TransferAccessControlled(ics20.proxy).upgradeEscrowTo(ics20.escrowImplementation);
        IICS20TransferAccessControlled(ics20.proxy).upgradeIBCERC20To(ics20.ibcERC20Implementation);
        uint256 sp1Migrations = _migratePlannedLightClients(ics26, ics07Deployments);
        vm.stopBroadcast();

        address idCustomizer = accessManagerDeployment.idCustomizers[0];
        vm.deal(idCustomizer, 1 ether);
        vm.startBroadcast(idCustomizer);
        IICS26Router(ics26.proxy).addIBCApp(ICS27Lib.DEFAULT_PORT_ID, ics27.proxy);
        vm.stopBroadcast();

        uint256 expectedSp1Deployments = _nonEmptyStringCount(sp1ClientIds);
        if (expectedSp1Deployments != 0) {
            vm.assertEq(sp1Deployments, expectedSp1Deployments, "unexpected SP1 light client deployment count");
        }
        uint256 expectedSp1Migrations = vm.envOr("EXPECTED_SP1_MIGRATIONS", uint256(0));
        if (expectedSp1Migrations == 0) {
            expectedSp1Migrations = expectedSp1Deployments;
        }
        if (expectedSp1Migrations != 0) {
            vm.assertEq(sp1Migrations, expectedSp1Migrations, "unexpected SP1 light client migration count");
        }

        _initializeKnownEscrows(ics20, ics07Deployments);

        console.log("Verifying upgraded shadow deployment...");
        verifyICS26Router(ics26, accessManagerDeployment);
        verifyICS20Transfer(ics20, accessManagerDeployment);
        verifyICS27GMP(ics27, ics26, accessManagerDeployment);
        verifyKnownEscrows(ics20, accessManagerDeployment, ics07Deployments);
        for (uint256 i = 0; i < ics07Deployments.length; ++i) {
            verifyICS07Tendermint(ics07Deployments[i], ics26);
        }

        _writeDeployment(path, accessManagerDeployment, ics26, ics20, ics27);

        console.log("Shadow v2-to-v3 upgrade succeeded.");
        console.log("AccessManager: %s", accessManagerDeployment.accessManager);
        console.log("ICS20Transfer implementation: %s", ics20.implementation);
        console.log("ICS26Router implementation: %s", ics26.implementation);
        console.log("Escrow implementation: %s", ics20.escrowImplementation);
        console.log("IBCERC20 implementation: %s", ics20.ibcERC20Implementation);
        console.log("ICS27GMP implementation: %s", ics27.implementation);
        console.log("ICS27Account implementation: %s", ics27.accountImplementation);
        console.log("ICS27GMP proxy: %s", ics27.proxy);
        console.log("SP1 light-client deployments: %s", sp1Deployments);
        console.log("SP1 light-client migrations: %s", sp1Migrations);
    }

    function _deployPlannedLightClients(
        SP1ICS07TendermintDeployment[] memory ics07Deployments,
        string[] memory clientIds,
        bool canDeployVerifier
    )
        private
        returns (uint256 deployments)
    {
        for (uint256 i = 0; i < clientIds.length; ++i) {
            if (bytes(clientIds[i]).length == 0) {
                continue;
            }

            uint256 deploymentIndex = _findLightClientDeployment(ics07Deployments, clientIds[i]);
            SP1ICS07TendermintDeployment memory deployment = ics07Deployments[deploymentIndex];
            vm.assertNotEq(deployment.merklePrefix.length, 0, "Merkle prefix must not be empty");

            SP1ICS07Tendermint ics07Tendermint = deploySP1ICS07Tendermint(deployment, canDeployVerifier);
            deployment.implementation = address(ics07Tendermint);
            deployment.verifier = vm.toString(address(ics07Tendermint.VERIFIER()));
            ics07Deployments[deploymentIndex] = deployment;

            deployments++;
            console.log("Deployed planned SP1 light client %s: %s", deployment.clientId, deployment.implementation);
        }
    }

    function _migratePlannedLightClients(
        ProxiedICS26RouterDeployment memory ics26,
        SP1ICS07TendermintDeployment[] memory ics07Deployments
    )
        private
        returns (uint256 migrations)
    {
        IICS02Client router = IICS02Client(ics26.proxy);

        for (uint256 i = 0; i < ics07Deployments.length; ++i) {
            SP1ICS07TendermintDeployment memory deployment = ics07Deployments[i];
            if (bytes(deployment.clientId).length == 0 || deployment.implementation == address(0)) {
                continue;
            }

            address currentClient = address(router.getClient(deployment.clientId));
            if (currentClient == deployment.implementation) {
                continue;
            }

            bytes[] memory merklePrefix = new bytes[](deployment.merklePrefix.length);
            for (uint256 j = 0; j < deployment.merklePrefix.length; ++j) {
                merklePrefix[j] = bytes(deployment.merklePrefix[j]);
            }

            IICS02ClientMsgs.CounterpartyInfo memory counterpartyInfo =
                IICS02ClientMsgs.CounterpartyInfo(deployment.counterpartyClientId, merklePrefix);

            router.migrateClient(deployment.clientId, counterpartyInfo, deployment.implementation);
            migrations++;
            console.log("Migrated light client %s to %s", deployment.clientId, deployment.implementation);
        }
    }

    function _writePlannedLightClients(
        string memory path,
        SP1ICS07TendermintDeployment[] memory ics07Deployments,
        string[] memory clientIds
    )
        private
    {
        for (uint256 i = 0; i < clientIds.length; ++i) {
            if (bytes(clientIds[i]).length == 0) {
                continue;
            }

            uint256 deploymentIndex = _findLightClientDeployment(ics07Deployments, clientIds[i]);
            string memory idx = Strings.toString(deploymentIndex);
            // NOTE: vm.writeJson only resolves dot-path segments; bracket syntax (".light_clients['0']")
            // is NOT parsed and instead creates a junk top-level key. Use dot notation for the object key.
            string memory key = string.concat(".light_clients.", idx);

            vm.writeJson(
                vm.toString(ics07Deployments[deploymentIndex].implementation),
                path,
                string.concat(key, ".implementation")
            );
            vm.writeJson(ics07Deployments[deploymentIndex].verifier, path, string.concat(key, ".verifier"));
        }
    }

    function _findLightClientDeployment(
        SP1ICS07TendermintDeployment[] memory ics07Deployments,
        string memory clientId
    )
        private
        pure
        returns (uint256)
    {
        for (uint256 i = 0; i < ics07Deployments.length; ++i) {
            if (Strings.equal(ics07Deployments[i].clientId, clientId)) {
                return i;
            }
        }

        revert(string.concat("Client ID not found: ", clientId));
    }

    function _nonEmptyStringCount(string[] memory values) private pure returns (uint256 count) {
        for (uint256 i = 0; i < values.length; ++i) {
            if (bytes(values[i]).length != 0) {
                count++;
            }
        }
    }

    function _initializeKnownEscrows(
        ProxiedICS20TransferDeployment memory ics20,
        SP1ICS07TendermintDeployment[] memory ics07Deployments
    )
        private
    {
        ICS20Transfer transfer = ICS20Transfer(ics20.proxy);

        vm.startBroadcast();
        for (uint256 i = 0; i < ics07Deployments.length; ++i) {
            if (bytes(ics07Deployments[i].clientId).length == 0) {
                continue;
            }

            address escrow = transfer.getEscrow(ics07Deployments[i].clientId);
            if (escrow == address(0)) {
                continue;
            }

            Escrow(escrow).initializeV2();
            console.log("Initialized escrow for %s: %s", ics07Deployments[i].clientId, escrow);
        }
        vm.stopBroadcast();
    }

    function _writeDeployment(
        string memory path,
        AccessManagerDeployment memory accessManagerDeployment,
        ProxiedICS26RouterDeployment memory ics26,
        ProxiedICS20TransferDeployment memory ics20,
        ICS27GMPDeployment memory ics27
    )
        private
    {
        vm.writeJson(vm.toString(accessManagerDeployment.accessManager), path, ".accessManager");
        _writeAccessManagerRoles(vm, path, accessManagerDeployment);
        vm.writeJson(vm.toString(ics26.implementation), path, ".ics26Router.implementation");
        vm.writeJson(vm.toString(accessManagerDeployment.admin), path, ".ics26Router.timelockAdmin");
        vm.writeJson(vm.toString(ics20.implementation), path, ".ics20Transfer.implementation");
        vm.writeJson(vm.toString(ics20.escrowImplementation), path, ".ics20Transfer.escrowImplementation");
        vm.writeJson(vm.toString(ics20.ibcERC20Implementation), path, ".ics20Transfer.ibcERC20Implementation");
        vm.serializeAddress("ics27Gmp", "proxy", ics27.proxy);
        vm.serializeAddress("ics27Gmp", "implementation", ics27.implementation);
        string memory ics27Json = vm.serializeAddress("ics27Gmp", "accountImplementation", ics27.accountImplementation);
        vm.writeJson(ics27Json, path, ".ics27Gmp");
    }
}
