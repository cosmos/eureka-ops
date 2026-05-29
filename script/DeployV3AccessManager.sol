// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import "forge-std/console.sol";

import { AccessManager } from "@openzeppelin-contracts/access/manager/AccessManager.sol";
import { IAccessManager } from "@openzeppelin-contracts/access/manager/IAccessManager.sol";
import { Strings } from "@openzeppelin-contracts/utils/Strings.sol";
import { Script } from "forge-std/Script.sol";
import { Deployments } from "./helpers/Deployments.sol";
import { IBCRolesLib } from "solidity-ibc-eureka/contracts/utils/IBCRolesLib.sol";
import { IICS02ClientAccessControlled } from "solidity-ibc-eureka/contracts/interfaces/IICS02Client.sol";

abstract contract V3AccessManagerConfigurator {
    function _setTargetRoles(IAccessManager manager, address ics26, address ics20) internal {
        manager.setTargetFunctionRole(ics26, IBCRolesLib.ics26IdCustomizerSelectors(), IBCRolesLib.ID_CUSTOMIZER_ROLE);
        manager.setTargetFunctionRole(ics26, IBCRolesLib.ics26RelayerSelectors(), IBCRolesLib.RELAYER_ROLE);
        manager.setTargetFunctionRole(ics20, IBCRolesLib.pauserSelectors(), IBCRolesLib.PAUSER_ROLE);
        manager.setTargetFunctionRole(ics20, IBCRolesLib.unpauserSelectors(), IBCRolesLib.UNPAUSER_ROLE);
        manager.setTargetFunctionRole(ics20, IBCRolesLib.erc20CustomizerSelectors(), IBCRolesLib.ERC20_CUSTOMIZER_ROLE);
        manager.setTargetFunctionRole(ics20, IBCRolesLib.delegateSenderSelectors(), IBCRolesLib.DELEGATE_SENDER_ROLE);
        manager.setTargetFunctionRole(ics20, IBCRolesLib.beaconUpgradeSelectors(), IBCRolesLib.ADMIN_ROLE);
        manager.setTargetFunctionRole(ics20, IBCRolesLib.uupsUpgradeSelectors(), IBCRolesLib.ADMIN_ROLE);
        manager.setTargetFunctionRole(ics26, IBCRolesLib.uupsUpgradeSelectors(), IBCRolesLib.ADMIN_ROLE);
        manager.setTargetFunctionRole(ics26, _ics26MigrationSelectors(), IBCRolesLib.ADMIN_ROLE);
    }

    function _ics26MigrationSelectors() internal pure returns (bytes4[] memory) {
        bytes4[] memory migrationSelectors = new bytes4[](1);
        migrationSelectors[0] = IICS02ClientAccessControlled.migrateClient.selector;
        return migrationSelectors;
    }

    function _grantRoles(
        IAccessManager manager,
        Deployments.ProxiedICS26RouterDeployment memory ics26,
        Deployments.ProxiedICS20TransferDeployment memory ics20
    )
        internal
    {
        for (uint256 i = 0; i < ics26.relayers.length; ++i) {
            manager.grantRole(IBCRolesLib.RELAYER_ROLE, ics26.relayers[i], 0);
        }
        for (uint256 i = 0; i < ics20.pausers.length; ++i) {
            manager.grantRole(IBCRolesLib.PAUSER_ROLE, ics20.pausers[i], 0);
        }
        for (uint256 i = 0; i < ics20.unpausers.length; ++i) {
            manager.grantRole(IBCRolesLib.UNPAUSER_ROLE, ics20.unpausers[i], 0);
        }
        for (uint256 i = 0; i < ics20.delegateSenders.length; ++i) {
            manager.grantRole(IBCRolesLib.DELEGATE_SENDER_ROLE, ics20.delegateSenders[i], 0);
        }
        if (ics26.clientIdCustomizer != address(0)) {
            manager.grantRole(IBCRolesLib.ID_CUSTOMIZER_ROLE, ics26.clientIdCustomizer, 0);
        }
        if (ics26.portCustomizer != address(0) && ics26.portCustomizer != ics26.clientIdCustomizer) {
            manager.grantRole(IBCRolesLib.ID_CUSTOMIZER_ROLE, ics26.portCustomizer, 0);
        }
        if (ics20.tokenOperator != address(0)) {
            manager.grantRole(IBCRolesLib.ERC20_CUSTOMIZER_ROLE, ics20.tokenOperator, 0);
        }
    }
}

contract V3AccessManagerBootstrap is V3AccessManagerConfigurator {
    address public immutable accessManager;

    constructor(
        Deployments.ProxiedICS26RouterDeployment memory ics26,
        Deployments.ProxiedICS20TransferDeployment memory ics20
    ) {
        AccessManager manager = new AccessManager(address(this));

        _setTargetRoles(manager, ics26.proxy, ics20.proxy);
        _grantRoles(manager, ics26, ics20);

        manager.grantRole(IBCRolesLib.ADMIN_ROLE, ics26.timelockAdmin, 0);
        manager.renounceRole(IBCRolesLib.ADMIN_ROLE, address(this));

        accessManager = address(manager);
    }
}

contract DeployV3AccessManager is Script, Deployments {
    function run() public returns (address) {
        string memory root = vm.projectRoot();
        string memory deployEnv = vm.envString("DEPLOYMENT_ENV");
        string memory path =
            string.concat(root, DEPLOYMENT_DIR, "/", deployEnv, "/", Strings.toString(block.chainid), ".json");
        string memory json = vm.readFile(path);

        AccessManagerDeployment memory accessManagerDeployment = loadAccessManagerDeployment(json);
        vm.assertEq(accessManagerDeployment.accessManager, address(0), "accessManager already set in deployment JSON");

        ProxiedICS26RouterDeployment memory ics26 = loadProxiedICS26RouterDeployment(vm, json);
        ProxiedICS20TransferDeployment memory ics20 = loadProxiedICS20TransferDeployment(vm, json);
        vm.assertNotEq(ics26.proxy, address(0), "ICS26Router proxy must be set");
        vm.assertNotEq(ics20.proxy, address(0), "ICS20Transfer proxy must be set");
        vm.assertNotEq(ics26.timelockAdmin, address(0), "timelock admin must be set");

        vm.startBroadcast();
        V3AccessManagerBootstrap bootstrap = new V3AccessManagerBootstrap(ics26, ics20);
        address manager = bootstrap.accessManager();
        vm.stopBroadcast();

        vm.writeJson(vm.toString(manager), path, ".accessManager");
        console.log("AccessManager deployed at: ", manager);
        return manager;
    }
}
