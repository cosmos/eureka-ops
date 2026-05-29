// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

// solhint-disable custom-errors,gas-custom-errors

import "forge-std/console.sol";

import { AccessManager } from "@openzeppelin-contracts/access/manager/AccessManager.sol";
import { ERC1967Proxy } from "@openzeppelin-contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { Strings } from "@openzeppelin-contracts/utils/Strings.sol";
import { ICS20Transfer } from "solidity-ibc-eureka/contracts/ICS20Transfer.sol";
import { ICS26Router } from "solidity-ibc-eureka/contracts/ICS26Router.sol";
import { IICS26Router } from "solidity-ibc-eureka/contracts/interfaces/IICS26Router.sol";
import { Escrow } from "solidity-ibc-eureka/contracts/utils/Escrow.sol";
import { IBCERC20 } from "solidity-ibc-eureka/contracts/utils/IBCERC20.sol";
import { IBCRolesLib } from "solidity-ibc-eureka/contracts/utils/IBCRolesLib.sol";
import { ICS20Lib } from "solidity-ibc-eureka/contracts/utils/ICS20Lib.sol";
import { V3AccessManagerConfigurator } from "./DeployV3AccessManager.sol";
import { DeploymentVerifier } from "./VerifyDeployment.sol";

contract DeployV3Core is DeploymentVerifier, V3AccessManagerConfigurator {
    function run() public returns (address, address, address) {
        string memory root = vm.projectRoot();
        string memory deployEnv = vm.envString("DEPLOYMENT_ENV");
        string memory path =
            string.concat(root, DEPLOYMENT_DIR, deployEnv, "/", Strings.toString(block.chainid), ".json");
        string memory json = vm.readFile(path);

        AccessManagerDeployment memory accessManagerDeployment = loadAccessManagerDeployment(json);
        ProxiedICS26RouterDeployment memory ics26 = loadProxiedICS26RouterDeployment(vm, json);
        ProxiedICS20TransferDeployment memory ics20 = loadProxiedICS20TransferDeployment(vm, json);

        vm.assertEq(accessManagerDeployment.accessManager, address(0), "AccessManager must be zero for fresh deploy");
        vm.assertEq(ics26.implementation, address(0), "ICS26Router implementation must be zero for fresh deploy");
        vm.assertEq(ics26.proxy, address(0), "ICS26Router proxy must be zero for fresh deploy");
        vm.assertEq(ics20.implementation, address(0), "ICS20Transfer implementation must be zero for fresh deploy");
        vm.assertEq(ics20.proxy, address(0), "ICS20Transfer proxy must be zero for fresh deploy");
        vm.assertEq(ics20.ics26Router, address(0), "ICS20Transfer ICS26Router must be zero for fresh deploy");
        vm.assertEq(ics20.escrowImplementation, address(0), "Escrow implementation must be zero for fresh deploy");
        vm.assertEq(ics20.ibcERC20Implementation, address(0), "IBCERC20 implementation must be zero for fresh deploy");
        vm.assertNotEq(ics26.timelockAdmin, address(0), "timelock admin must be set");

        (accessManagerDeployment.accessManager, ics26, ics20) = _broadcastFreshDeploy(ics26, ics20);

        verifyICS26Router(ics26, accessManagerDeployment);
        verifyICS20Transfer(ics20, accessManagerDeployment);

        _writeDeployment(path, accessManagerDeployment, ics26, ics20);

        console.log("AccessManager deployed at: ", accessManagerDeployment.accessManager);
        console.log("ICS26Router deployed at: ", ics26.proxy);
        console.log("ICS20Transfer deployed at: ", ics20.proxy);

        return (accessManagerDeployment.accessManager, ics26.proxy, ics20.proxy);
    }

    function _broadcastFreshDeploy(
        ProxiedICS26RouterDeployment memory ics26,
        ProxiedICS20TransferDeployment memory ics20
    )
        private
        returns (
            address accessManagerAddress,
            ProxiedICS26RouterDeployment memory,
            ProxiedICS20TransferDeployment memory
        )
    {
        vm.startBroadcast();
        (, address temporaryAdmin,) = vm.readCallers();

        AccessManager accessManager = new AccessManager(temporaryAdmin);
        accessManagerAddress = address(accessManager);

        ics26 = _deployICS26Router(accessManager, ics26);
        ics20 = _deployICS20Transfer(accessManager, ics26.proxy, ics20);

        IICS26Router(ics26.proxy).addIBCApp(ICS20Lib.DEFAULT_PORT_ID, ics20.proxy);
        _setTargetRoles(accessManager, ics26.proxy, ics20.proxy);
        _grantRoles(accessManager, ics26, ics20);
        if (temporaryAdmin != ics26.timelockAdmin) {
            accessManager.grantRole(IBCRolesLib.ADMIN_ROLE, ics26.timelockAdmin, 0);
            accessManager.renounceRole(IBCRolesLib.ADMIN_ROLE, temporaryAdmin);
        }

        vm.stopBroadcast();

        return (accessManagerAddress, ics26, ics20);
    }

    function _deployICS26Router(
        AccessManager accessManager,
        ProxiedICS26RouterDeployment memory ics26
    )
        private
        returns (ProxiedICS26RouterDeployment memory)
    {
        ics26.implementation = address(new ICS26Router());
        ERC1967Proxy routerProxy =
            new ERC1967Proxy(ics26.implementation, abi.encodeCall(ICS26Router.initialize, (address(accessManager))));
        ics26.proxy = address(routerProxy);
        return ics26;
    }

    function _deployICS20Transfer(
        AccessManager accessManager,
        address ics26Proxy,
        ProxiedICS20TransferDeployment memory ics20
    )
        private
        returns (ProxiedICS20TransferDeployment memory)
    {
        ics20.implementation = address(new ICS20Transfer());
        ics20.escrowImplementation = address(new Escrow());
        ics20.ibcERC20Implementation = address(new IBCERC20());
        ics20.ics26Router = ics26Proxy;
        ERC1967Proxy transferProxy = new ERC1967Proxy(
            ics20.implementation,
            abi.encodeCall(
                ICS20Transfer.initialize,
                (
                    ics20.ics26Router,
                    ics20.escrowImplementation,
                    ics20.ibcERC20Implementation,
                    ics20.permit2,
                    address(accessManager)
                )
            )
        );
        ics20.proxy = address(transferProxy);
        return ics20;
    }

    function _writeDeployment(
        string memory path,
        AccessManagerDeployment memory accessManagerDeployment,
        ProxiedICS26RouterDeployment memory ics26,
        ProxiedICS20TransferDeployment memory ics20
    )
        private
    {
        vm.writeJson(vm.toString(accessManagerDeployment.accessManager), path, ".accessManager");

        vm.serializeAddress("ics26Router", "proxy", ics26.proxy);
        vm.serializeAddress("ics26Router", "implementation", ics26.implementation);
        vm.serializeAddress("ics26Router", "timelockAdmin", ics26.timelockAdmin);
        vm.serializeAddress("ics26Router", "clientIdCustomizer", ics26.clientIdCustomizer);
        vm.serializeAddress("ics26Router", "portCustomizer", ics26.portCustomizer);
        string memory ics26Json = vm.serializeAddress("ics26Router", "relayers", ics26.relayers);
        vm.writeJson(ics26Json, path, ".ics26Router");

        vm.serializeAddress("ics20Transfer", "proxy", ics20.proxy);
        vm.serializeAddress("ics20Transfer", "implementation", ics20.implementation);
        vm.serializeAddress("ics20Transfer", "escrowImplementation", ics20.escrowImplementation);
        vm.serializeAddress("ics20Transfer", "ibcERC20Implementation", ics20.ibcERC20Implementation);
        vm.serializeAddress("ics20Transfer", "ics26Router", ics20.ics26Router);
        vm.serializeAddress("ics20Transfer", "pausers", ics20.pausers);
        vm.serializeAddress("ics20Transfer", "unpausers", ics20.unpausers);
        vm.serializeAddress("ics20Transfer", "delegateSenders", ics20.delegateSenders);
        vm.serializeAddress("ics20Transfer", "tokenOperator", ics20.tokenOperator);
        string memory ics20Json = vm.serializeAddress("ics20Transfer", "permit2", ics20.permit2);
        vm.writeJson(ics20Json, path, ".ics20Transfer");
    }
}
