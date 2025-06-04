// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import "forge-std/console.sol";

import { Script } from "forge-std/Script.sol";
import { Deployments } from "./helpers/Deployments.sol";
import { Strings } from "@openzeppelin-contracts/utils/Strings.sol";
import { ICS26Router } from "solidity-ibc-eureka/contracts/ICS26Router.sol";
import { ICS20Transfer } from "solidity-ibc-eureka/contracts/ICS20Transfer.sol";
import { Escrow } from "solidity-ibc-eureka/contracts/utils/Escrow.sol"; 
import { stdJson } from "forge-std/StdJson.sol";
import { TimelockController } from "@openzeppelin-contracts/governance/TimelockController.sol";

library ScriptHelperConstants {
     string public constant ICS26_ROUTER_NAME = "ICS26Router";
     string public constant ICS20_TRANSFER_NAME = "ICS20Transfer";
     string public constant ESCROW_NAME = "Escrow";
     string public constant IBCERC20_NAME = "IBCERC20";
}

contract GenerateScriptHelperJSON is Script, Deployments {
    using stdJson for string;


    function run() public {
        string memory root = vm.projectRoot();
        string memory deployEnv = vm.envString("DEPLOYMENT_ENV");
        string memory path = string.concat(root, DEPLOYMENT_DIR, "/", deployEnv, "/", Strings.toString(block.chainid), ".json");
        string memory json = vm.readFile(path);

        bytes memory preCalldata = vm.envOr("PRE_CALLDATA", bytes(""));
        if (preCalldata.length > 0) {
            address preCallAddress = vm.envAddress("PRE_CALL_CONTRACT_ADDRESS");
            address preCaller = vm.envAddress("PRE_CALLER_ADDRESS");
            vm.prank(preCaller);
            (bool success,) = preCallAddress.call(preCalldata);
            require(success, "Pre-call failed");
        }


        ProxiedICS26RouterDeployment memory ics26RouterDeployment = loadProxiedICS26RouterDeployment(vm, json);
        SP1ICS07TendermintDeployment[] memory lightClientDeployments = loadSP1ICS07TendermintDeployments(vm, json, ics26RouterDeployment.proxy);
        ProxiedICS20TransferDeployment memory ics20TransferDeployment = loadProxiedICS20TransferDeployment(vm, json);

        ICS26Router ics26Router = ICS26Router(ics26RouterDeployment.proxy);
        ICS20Transfer ics20Transfer = ICS20Transfer(ics20TransferDeployment.proxy);

        // These keys are not used in the JSON output itself, but are used to keep track of the internal structure created by the `serialize*` functions.
        string memory deploymentsKey = "deploymentsKey";
        string memory settingsKey = "settingsKey";
        string memory ics26Key = "ics26Key";
        string memory ics26RolesKey = "ics26RolesKey";
        string memory ics20Key = "ics20Key";
        string memory ics20RolesKey = "ics20RolesKey";

        // Settings
        bool isTimelockController = false;
        // If the address is an EOA, the code length will be 0. Otherwise, we can assume it's a timelock controller.
        if (ics26RouterDeployment.timelockAdmin.code.length != 0) {
            isTimelockController = true;

            TimelockController timelockController = TimelockController(payable(ics26RouterDeployment.timelockAdmin));
            uint256 delay = timelockController.getMinDelay();
            vm.serializeUint(settingsKey, "timelock_delay", delay);

        }
        string memory settings = vm.serializeBool(settingsKey, "admin_is_timelock_controller", isTimelockController);

        // Implementations
        string[] memory implementations = new string[](4);
        implementations[0] = ScriptHelperConstants.ICS26_ROUTER_NAME;
        implementations[1] = ScriptHelperConstants.ICS20_TRANSFER_NAME;
        implementations[2] = ScriptHelperConstants.ESCROW_NAME;
        implementations[3] = ScriptHelperConstants.IBCERC20_NAME;

        // Deployed Contracts

        // ICS26
        vm.serializeAddress(ics26Key, "contract_address", ics26RouterDeployment.proxy);
        vm.serializeBool(ics26Key, "uups_upgradeable", true);

        string memory ics26Roles;
        vm.serializeBytes32(ics26RolesKey, "Client ID Customizer role", ics26Router.CLIENT_ID_CUSTOMIZER_ROLE());
        vm.serializeBytes32(ics26RolesKey, "Port Customizer role", ics26Router.PORT_CUSTOMIZER_ROLE());
        vm.serializeBytes32(ics26RolesKey, "Relayer role", ics26Router.RELAYER_ROLE());

        for (uint256 i = 0; i < lightClientDeployments.length; i++) {
            bytes32 role = ics26Router.getLightClientMigratorRole(lightClientDeployments[i].clientId);
            ics26Roles = vm.serializeBytes32(ics26RolesKey, string.concat("Light Client Migrator role: ", lightClientDeployments[i].clientId), role);
        }
        string memory ics26Json = vm.serializeString(ics26Key, "roles", ics26Roles);

        // ICS20
        vm.serializeAddress(ics20Key, "contract_address", ics20TransferDeployment.proxy);
        vm.serializeBool(ics20Key, "uups_upgradeable", true);

        vm.serializeBytes32(ics20RolesKey, "Pauser role", ics20Transfer.PAUSER_ROLE());
        vm.serializeBytes32(ics20RolesKey, "Unpauser role", ics20Transfer.UNPAUSER_ROLE());
        vm.serializeBytes32(ics20RolesKey, "Token Operator role", ics20Transfer.TOKEN_OPERATOR_ROLE());
        ICS20Transfer newIcs20Transfer = new ICS20Transfer();
        vm.serializeBytes32(ics20RolesKey, "ERC20 Customizer role", newIcs20Transfer.ERC20_CUSTOMIZER_ROLE());
        
        string memory ics20Roles = vm.serializeBytes32(ics20RolesKey, "Delegate Sender role", ics20Transfer.DELEGATE_SENDER_ROLE());
        string memory ics20Json = vm.serializeString(ics20Key, "roles", ics20Roles);

        // Collect deployments
        vm.serializeString(deploymentsKey, ScriptHelperConstants.ICS26_ROUTER_NAME, ics26Json);
        string memory deployments = vm.serializeString(deploymentsKey, ScriptHelperConstants.ICS20_TRANSFER_NAME, ics20Json);

        vm.serializeString("root", "settings", settings);
        vm.serializeString("root", "implementations", implementations);
        string memory finalJson = vm.serializeString("root", "deployments", deployments);
        vm.writeJson(finalJson, "out/scriptHelper.json");
    }
}
