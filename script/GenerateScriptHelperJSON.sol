// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import "forge-std/console.sol";

import { Script } from "forge-std/Script.sol";
import { Deployments } from "./helpers/Deployments.sol";
import { Strings } from "@openzeppelin-contracts/utils/Strings.sol";
import { IBCRolesLib } from "solidity-ibc-eureka/contracts/utils/IBCRolesLib.sol";
import { stdJson } from "forge-std/StdJson.sol";
import { TimelockController } from "@openzeppelin-contracts/governance/TimelockController.sol";

library ScriptHelperConstants {
    string public constant ICS26_ROUTER_NAME = "ICS26Router";
    string public constant ICS20_TRANSFER_NAME = "ICS20Transfer";
    string public constant ICS27_GMP_NAME = "ICS27GMP";
    string public constant ICS27_ACCOUNT_NAME = "ICS27Account";
    string public constant ESCROW_NAME = "Escrow";
    string public constant IBCERC20_NAME = "IBCERC20";
}

contract GenerateScriptHelperJSON is Script, Deployments {
    using stdJson for string;

    function run() public {
        string memory root = vm.projectRoot();
        string memory deployEnv = vm.envString("DEPLOYMENT_ENV");
        string memory path =
            string.concat(root, DEPLOYMENT_DIR, "/", deployEnv, "/", Strings.toString(block.chainid), ".json");
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
        ProxiedICS20TransferDeployment memory ics20TransferDeployment = loadProxiedICS20TransferDeployment(vm, json);
        ICS27GMPDeployment memory ics27GmpDeployment = loadICS27GMPDeployment(json);
        AccessManagerDeployment memory accessManagerDeployment = loadAccessManagerDeployment(json);

        // These keys are not used in the JSON output itself, but are used to keep track of the internal structure
        // created by the `serialize*` functions.
        string memory deploymentsKey = "deploymentsKey";
        string memory settingsKey = "settingsKey";
        string memory ics26Key = "ics26Key";
        string memory ics26RolesKey = "ics26RolesKey";
        string memory ics20Key = "ics20Key";
        string memory ics20RolesKey = "ics20RolesKey";
        string memory accessManagerKey = "accessManagerKey";
        string memory accessManagerRolesKey = "accessManagerRolesKey";

        // Settings
        bool isTimelockController = false;
        // If the address is an EOA, the code length will be 0. Otherwise, we can assume it's a timelock controller.
        if (accessManagerDeployment.admin.code.length != 0) {
            isTimelockController = true;

            TimelockController timelockController = TimelockController(payable(accessManagerDeployment.admin));
            uint256 delay = timelockController.getMinDelay();
            vm.serializeUint(settingsKey, "timelock_delay", delay);
        }
        string memory settings = vm.serializeBool(settingsKey, "admin_is_timelock_controller", isTimelockController);

        // Implementations
        string[] memory implementations = new string[](6);
        implementations[0] = ScriptHelperConstants.ICS26_ROUTER_NAME;
        implementations[1] = ScriptHelperConstants.ICS20_TRANSFER_NAME;
        implementations[2] = ScriptHelperConstants.ESCROW_NAME;
        implementations[3] = ScriptHelperConstants.IBCERC20_NAME;
        implementations[4] = ScriptHelperConstants.ICS27_GMP_NAME;
        implementations[5] = ScriptHelperConstants.ICS27_ACCOUNT_NAME;

        // Deployed Contracts

        // ICS26
        vm.serializeAddress(ics26Key, "contract_address", ics26RouterDeployment.proxy);
        vm.serializeBool(ics26Key, "uups_upgradeable", true);

        string memory ics26Roles;
        vm.serializeUint(ics26RolesKey, "ID Customizer role", IBCRolesLib.ID_CUSTOMIZER_ROLE);
        ics26Roles = vm.serializeUint(ics26RolesKey, "Relayer role", IBCRolesLib.RELAYER_ROLE);
        string memory ics26Json = vm.serializeString(ics26Key, "roles", ics26Roles);

        // ICS20
        vm.serializeAddress(ics20Key, "contract_address", ics20TransferDeployment.proxy);
        vm.serializeBool(ics20Key, "uups_upgradeable", true);

        vm.serializeUint(ics20RolesKey, "Pauser role", IBCRolesLib.PAUSER_ROLE);
        vm.serializeUint(ics20RolesKey, "Unpauser role", IBCRolesLib.UNPAUSER_ROLE);
        vm.serializeUint(ics20RolesKey, "ERC20 Customizer role", IBCRolesLib.ERC20_CUSTOMIZER_ROLE);
        string memory ics20Roles =
            vm.serializeUint(ics20RolesKey, "Delegate Sender role", IBCRolesLib.DELEGATE_SENDER_ROLE);
        string memory ics20Json = vm.serializeString(ics20Key, "roles", ics20Roles);

        // ICS27
        string memory ics27Key = "ics27Key";
        string memory ics27RolesKey = "ics27RolesKey";
        vm.serializeAddress(ics27Key, "contract_address", ics27GmpDeployment.proxy);
        vm.serializeBool(ics27Key, "uups_upgradeable", true);

        vm.serializeUint(ics27RolesKey, "Pauser role", IBCRolesLib.PAUSER_ROLE);
        string memory ics27Roles = vm.serializeUint(ics27RolesKey, "Unpauser role", IBCRolesLib.UNPAUSER_ROLE);
        string memory ics27Json = vm.serializeString(ics27Key, "roles", ics27Roles);

        vm.serializeAddress(accessManagerKey, "contract_address", accessManagerDeployment.accessManager);
        string memory accessManagerRoles = vm.serializeUint(accessManagerRolesKey, "Admin role", IBCRolesLib.ADMIN_ROLE);
        string memory accessManagerJson = vm.serializeString(accessManagerKey, "roles", accessManagerRoles);

        // Collect deployments
        vm.serializeString(deploymentsKey, ScriptHelperConstants.ICS26_ROUTER_NAME, ics26Json);
        vm.serializeString(deploymentsKey, ScriptHelperConstants.ICS20_TRANSFER_NAME, ics20Json);
        vm.serializeString(deploymentsKey, ScriptHelperConstants.ICS27_GMP_NAME, ics27Json);
        string memory deployments = vm.serializeString(deploymentsKey, "AccessManager", accessManagerJson);

        vm.serializeString("root", "settings", settings);
        vm.serializeString("root", "implementations", implementations);
        string memory finalJson = vm.serializeString("root", "deployments", deployments);
        vm.writeJson(finalJson, "out/scriptHelper.json");
    }
}
