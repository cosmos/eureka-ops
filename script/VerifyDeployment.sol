// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

// solhint-disable custom-errors,gas-custom-errors

import "forge-std/console.sol";
import { Deployments } from "./helpers/Deployments.sol";
import { ICS26Router } from "solidity-ibc-eureka/contracts/ICS26Router.sol";
import { ICS20Transfer } from "solidity-ibc-eureka/contracts/ICS20Transfer.sol";
import { ICS20Lib } from "solidity-ibc-eureka/contracts/utils/ICS20Lib.sol";
import { IBCRolesLib } from "solidity-ibc-eureka/contracts/utils/IBCRolesLib.sol";
import { IAccessManaged } from "@openzeppelin-contracts/access/manager/IAccessManaged.sol";
import { IAccessManager } from "@openzeppelin-contracts/access/manager/IAccessManager.sol";
import { IBeacon } from "@openzeppelin-contracts/proxy/beacon/IBeacon.sol";
import { IICS26Router } from "solidity-ibc-eureka/contracts/interfaces/IICS26Router.sol";
import { ERC1967Proxy } from "@openzeppelin-contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { ERC1967Utils } from "@openzeppelin-contracts/proxy/ERC1967/ERC1967Utils.sol";
import {
    ISP1ICS07Tendermint
} from "solidity-ibc-eureka/contracts/light-clients/sp1-ics07/interfaces/ISP1ICS07Tendermint.sol";
import { stdJson } from "forge-std/StdJson.sol";
import { IICS02ClientMsgs } from "solidity-ibc-eureka/contracts/msgs/IICS02ClientMsgs.sol";
import { IICS02Client, IICS02ClientAccessControlled } from "solidity-ibc-eureka/contracts/interfaces/IICS02Client.sol";
import { Strings } from "@openzeppelin-contracts/utils/Strings.sol";
import { Script } from "forge-std/Script.sol";

abstract contract DeploymentVerifier is Deployments, Script {
    function getImplementation(address proxy) internal view returns (address) {
        return address(uint160(uint256(vm.load(proxy, ERC1967Utils.IMPLEMENTATION_SLOT))));
    }

    function verifyICS26Router(
        ProxiedICS26RouterDeployment memory deployment,
        AccessManagerDeployment memory accessManagerDeployment
    )
        internal
        view
    {
        ERC1967Proxy routerProxy = ERC1967Proxy(payable(deployment.proxy));
        IAccessManager accessManager = IAccessManager(accessManagerDeployment.accessManager);

        vm.assertEq(
            getImplementation(address(routerProxy)), deployment.implementation, "implementation addresses don't match"
        );

        vm.assertEq(
            IAccessManaged(address(routerProxy)).authority(),
            accessManagerDeployment.accessManager,
            "ICS26Router authority doesn't match AccessManager"
        );

        _assertTargetRoles(
            accessManager,
            address(routerProxy),
            IBCRolesLib.ics26IdCustomizerSelectors(),
            IBCRolesLib.ID_CUSTOMIZER_ROLE
        );
        _assertTargetRoles(
            accessManager, address(routerProxy), IBCRolesLib.ics26RelayerSelectors(), IBCRolesLib.RELAYER_ROLE
        );
        _assertTargetRoles(
            accessManager, address(routerProxy), IBCRolesLib.uupsUpgradeSelectors(), IBCRolesLib.ADMIN_ROLE
        );
        _assertTargetRoles(accessManager, address(routerProxy), _ics26MigrationRoleSelectors(), IBCRolesLib.ADMIN_ROLE);
        _assertRole(accessManager, IBCRolesLib.ADMIN_ROLE, deployment.timelockAdmin, "timelock admin");

        if (deployment.portCustomizer != address(0)) {
            _assertRole(accessManager, IBCRolesLib.ID_CUSTOMIZER_ROLE, deployment.portCustomizer, "portCustomizer");
        }

        if (deployment.clientIdCustomizer != address(0) && deployment.clientIdCustomizer != deployment.portCustomizer) {
            _assertRole(
                accessManager, IBCRolesLib.ID_CUSTOMIZER_ROLE, deployment.clientIdCustomizer, "clientIdCustomizer"
            );
        }

        if (deployment.relayers.length != 0) {
            for (uint32 i = 0; i < deployment.relayers.length; i++) {
                _assertRole(accessManager, IBCRolesLib.RELAYER_ROLE, deployment.relayers[i], "relayer");
            }
        }
    }

    function verifyICS20Transfer(
        ProxiedICS20TransferDeployment memory deployment,
        AccessManagerDeployment memory accessManagerDeployment
    )
        internal
        view
    {
        ERC1967Proxy transferProxy = ERC1967Proxy(payable(deployment.proxy));
        IAccessManager accessManager = IAccessManager(accessManagerDeployment.accessManager);

        vm.assertEq(
            getImplementation(address(transferProxy)), deployment.implementation, "implementation addresses don't match"
        );

        ICS20Transfer ics20Transfer = ICS20Transfer(deployment.proxy);

        vm.assertEq(
            IAccessManaged(address(transferProxy)).authority(),
            accessManagerDeployment.accessManager,
            "ICS20Transfer authority doesn't match AccessManager"
        );

        vm.assertEq(ics20Transfer.ics26(), deployment.ics26Router, "ics26Router addresses don't match");

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

        vm.assertEq(ics20Transfer.getPermit2(), deployment.permit2, "permit2 addresses don't match");

        IICS26Router ics26Router = IICS26Router(deployment.ics26Router);
        address transferApp = address(ics26Router.getIBCApp(ICS20Lib.DEFAULT_PORT_ID));
        vm.assertEq(transferApp, deployment.proxy, "transfer app address doesn't match with the one in ics26Router");

        _assertTargetRoles(
            accessManager, address(transferProxy), IBCRolesLib.pauserSelectors(), IBCRolesLib.PAUSER_ROLE
        );
        _assertTargetRoles(
            accessManager, address(transferProxy), IBCRolesLib.unpauserSelectors(), IBCRolesLib.UNPAUSER_ROLE
        );
        _assertTargetRoles(
            accessManager,
            address(transferProxy),
            IBCRolesLib.erc20CustomizerSelectors(),
            IBCRolesLib.ERC20_CUSTOMIZER_ROLE
        );
        _assertTargetRoles(
            accessManager,
            address(transferProxy),
            IBCRolesLib.delegateSenderSelectors(),
            IBCRolesLib.DELEGATE_SENDER_ROLE
        );
        _assertTargetRoles(
            accessManager, address(transferProxy), IBCRolesLib.beaconUpgradeSelectors(), IBCRolesLib.ADMIN_ROLE
        );
        _assertTargetRoles(
            accessManager, address(transferProxy), IBCRolesLib.uupsUpgradeSelectors(), IBCRolesLib.ADMIN_ROLE
        );

        if (deployment.pausers.length != 0) {
            for (uint32 i = 0; i < deployment.pausers.length; i++) {
                _assertRole(accessManager, IBCRolesLib.PAUSER_ROLE, deployment.pausers[i], "pauser");
            }
        }

        if (deployment.unpausers.length != 0) {
            for (uint32 i = 0; i < deployment.unpausers.length; i++) {
                _assertRole(accessManager, IBCRolesLib.UNPAUSER_ROLE, deployment.unpausers[i], "unpauser");
            }
        }

        if (deployment.delegateSenders.length != 0) {
            for (uint32 i = 0; i < deployment.delegateSenders.length; i++) {
                _assertRole(
                    accessManager, IBCRolesLib.DELEGATE_SENDER_ROLE, deployment.delegateSenders[i], "delegateSender"
                );
            }
        }

        if (deployment.tokenOperator != address(0)) {
            _assertRole(accessManager, IBCRolesLib.ERC20_CUSTOMIZER_ROLE, deployment.tokenOperator, "tokenOperator");
        }
    }

    function verifyKnownEscrows(
        ProxiedICS20TransferDeployment memory deployment,
        AccessManagerDeployment memory accessManagerDeployment,
        SP1ICS07TendermintDeployment[] memory ics07Deployments
    )
        internal
        view
    {
        ICS20Transfer ics20Transfer = ICS20Transfer(deployment.proxy);

        for (uint256 i = 0; i < ics07Deployments.length; ++i) {
            address escrow = ics20Transfer.getEscrow(ics07Deployments[i].clientId);
            if (escrow == address(0)) {
                continue;
            }

            vm.assertEq(
                IAccessManaged(escrow).authority(),
                accessManagerDeployment.accessManager,
                string.concat("escrow authority doesn't match AccessManager for ", ics07Deployments[i].clientId)
            );
        }
    }

    function _assertTargetRoles(
        IAccessManager accessManager,
        address target,
        bytes4[] memory selectors,
        uint64 role
    )
        internal
        view
    {
        for (uint256 i = 0; i < selectors.length; ++i) {
            vm.assertEq(
                accessManager.getTargetFunctionRole(target, selectors[i]), role, "target function role mismatch"
            );
        }
    }

    function _ics26MigrationRoleSelectors() internal pure returns (bytes4[] memory) {
        bytes4[] memory migrationSelectors = new bytes4[](1);
        migrationSelectors[0] = IICS02ClientAccessControlled.migrateClient.selector;
        return migrationSelectors;
    }

    function _assertRole(
        IAccessManager accessManager,
        uint64 role,
        address account,
        string memory label
    )
        internal
        view
    {
        (bool isMember,) = accessManager.hasRole(role, account);
        vm.assertTrue(isMember, string.concat(label, " role not granted to ", Strings.toHexString(account)));
    }

    function verifyICS07Tendermint(
        SP1ICS07TendermintDeployment memory deployment,
        ProxiedICS26RouterDeployment memory ics26RouterDeployment
    )
        internal
        view
    {
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

        vm.assertEq(actualVerifierAddress, verifierAddr, "verifier address doesn't match");

        vm.assertEq(
            ics07Tendermint.MEMBERSHIP_PROGRAM_VKEY(), deployment.membershipVkey, "membershipVkey doesn't match"
        );

        vm.assertEq(
            ics07Tendermint.MISBEHAVIOUR_PROGRAM_VKEY(), deployment.misbehaviourVkey, "misbehaviourVkey doesn't match"
        );

        vm.assertEq(
            ics07Tendermint.UPDATE_CLIENT_PROGRAM_VKEY(), deployment.updateClientVkey, "updateClientVkey doesn't match"
        );
        vm.assertEq(
            ics07Tendermint.UPDATE_CLIENT_AND_MEMBERSHIP_PROGRAM_VKEY(),
            deployment.ucAndMembershipVkey,
            "ucAndMembershipVkey doesn't match"
        );

        IICS02ClientMsgs.CounterpartyInfo memory counterparty = router.getCounterparty(deployment.clientId);

        for (uint256 i = 0; i < counterparty.merklePrefix.length; i++) {
            vm.assertEq(counterparty.merklePrefix[i], bytes(deployment.merklePrefix[i]), "merklePrefix doesn't match");
        }

        vm.assertEq(counterparty.clientId, deployment.counterpartyClientId, "counterpartyClientId doesn't match");
    }
}

contract VerifyDeployment is DeploymentVerifier {
    function run() public view {
        string memory root = vm.projectRoot();
        string memory deployEnv = vm.envString("DEPLOYMENT_ENV");
        string memory path =
            string.concat(root, DEPLOYMENT_DIR, "/", deployEnv, "/", Strings.toString(block.chainid), ".json");
        string memory json = vm.readFile(path);

        ProxiedICS26RouterDeployment memory ics26RouterDeployment = loadProxiedICS26RouterDeployment(vm, json);
        ProxiedICS20TransferDeployment memory ics20TransferDeployment = loadProxiedICS20TransferDeployment(vm, json);
        AccessManagerDeployment memory accessManagerDeployment = loadAccessManagerDeployment(json);
        SP1ICS07TendermintDeployment[] memory ics07Deployments =
            loadSP1ICS07TendermintDeployments(vm, json, ics26RouterDeployment.proxy);

        console.log("Verifying deployment at path: %s", path);

        console.log("Verifying ICS26Router...");
        verifyICS26Router(ics26RouterDeployment, accessManagerDeployment);
        console.log("Verifying ICS20Transfer...");
        verifyICS20Transfer(ics20TransferDeployment, accessManagerDeployment);
        console.log("Verifying known escrows...");
        verifyKnownEscrows(ics20TransferDeployment, accessManagerDeployment, ics07Deployments);

        for (uint256 i = 0; i < ics07Deployments.length; i++) {
            console.log("Verifying ICS07Tendermint deployment %s...", ics07Deployments[i].clientId);
            verifyICS07Tendermint(ics07Deployments[i], ics26RouterDeployment);
        }
    }
}
