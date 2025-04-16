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

library UserInputConstants {
     string public constant ICS26_ROUTER_IMPL = "ICS26Router";
     string public constant ICS20_TRANSFER_IMPL = "ICS20Transfer";
     string public constant ESCROW_IMPL = "Escrow";
     string public constant IBCERC20_IMPL = "IBCERC20";
}

/// @dev See the Solidity Scripting tutorial: https://book.getfoundry.sh/guides/scripting-with-solidity
contract GenerateUserInputJSON is Script, Deployments {
    using stdJson for string;


    function run() public {
        string memory root = vm.projectRoot();
        string memory deployEnv = vm.envString("DEPLOYMENT_ENV");
        string memory path = string.concat(root, DEPLOYMENT_DIR, "/", deployEnv, "/", Strings.toString(block.chainid), ".json");
        string memory json = vm.readFile(path);

        ProxiedICS26RouterDeployment memory ics26RouterDeployment = loadProxiedICS26RouterDeployment(vm, json);
        SP1ICS07TendermintDeployment[] memory lightClientDeployments = loadSP1ICS07TendermintDeployments(vm, json, ics26RouterDeployment.proxy);
        ProxiedICS20TransferDeployment memory ics20TransferDeployment = loadProxiedICS20TransferDeployment(vm, json);

        ICS26Router ics26Router = ICS26Router(ics26RouterDeployment.proxy);
        ICS20Transfer ics20Transfer = ICS20Transfer(ics20TransferDeployment.proxy);

        // These keys are not used in the JSON output itself, but are used to keep track of the internal structure created by the `serialize*` functions.
        string memory ics26RootKey = "ics26root";
        string memory ics26RoleRootKey = "ics26roles";
        string memory ics20RootKey = "ics20root";
        string memory ics20RoleRootKey = "ics20roles";

        // Implementations
        string[] memory implementations = new string[](4);
        implementations[0] = UserInputConstants.ICS26_ROUTER_IMPL;
        implementations[1] = UserInputConstants.ICS20_TRANSFER_IMPL;
        implementations[2] = UserInputConstants.ESCROW_IMPL;
        implementations[3] = UserInputConstants.IBCERC20_IMPL;

        // ICS26 Roles
        vm.serializeAddress(ics26RootKey, "contract_address", ics26RouterDeployment.proxy);

        string memory ics26Roles;
        vm.serializeBytes32(ics26RoleRootKey, "Client ID Customizer role", ics26Router.CLIENT_ID_CUSTOMIZER_ROLE());
        vm.serializeBytes32(ics26RoleRootKey, "Port Customizer role", ics26Router.PORT_CUSTOMIZER_ROLE());
        vm.serializeBytes32(ics26RoleRootKey, "Relayer role", ics26Router.RELAYER_ROLE());

        for (uint256 i = 0; i < lightClientDeployments.length; i++) {
            bytes32 role = ics26Router.getLightClientMigratorRole(lightClientDeployments[i].clientId);
            ics26Roles = vm.serializeBytes32(ics26RoleRootKey, string.concat("Light Client Migrator role: ", lightClientDeployments[i].clientId), role);
        }
        string memory ics26Json = vm.serializeString(ics26RootKey, "roles", ics26Roles);

        // ICS20 Roles
        vm.serializeAddress(ics20RootKey, "contract_address", ics20TransferDeployment.proxy);

        vm.serializeBytes32(ics20RoleRootKey, "Pauser role", ics20Transfer.PAUSER_ROLE());
        vm.serializeBytes32(ics20RoleRootKey, "Unpauser role", ics20Transfer.UNPAUSER_ROLE());
        vm.serializeBytes32(ics20RoleRootKey, "Token Operator role", ics20Transfer.TOKEN_OPERATOR_ROLE());
        string memory ics20Roles = vm.serializeBytes32(ics20RoleRootKey, "Delegate Sender role", ics20Transfer.DELEGATE_SENDER_ROLE());
        string memory ics20Json = vm.serializeString(ics20RootKey, "roles", ics20Roles);

        vm.serializeString("root", "implementations", implementations);
        vm.serializeString("root", "ICS26 Router", ics26Json);
        string memory finalJson = vm.serializeString("root", "ICS20 Transfer", ics20Json);
        vm.writeJson(finalJson, "out/userinput.json");
    }
}
