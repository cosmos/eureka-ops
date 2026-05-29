// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import "forge-std/console.sol";

import { Script } from "forge-std/Script.sol";
import { Deployments } from "./helpers/Deployments.sol";
import { IAccessManager } from "@openzeppelin-contracts/access/manager/IAccessManager.sol";
import { Strings } from "@openzeppelin-contracts/utils/Strings.sol";
import { IBCRolesLib } from "solidity-ibc-eureka/contracts/utils/IBCRolesLib.sol";

interface IAccessManagerMulticall {
    function multicall(bytes[] calldata data) external returns (bytes[] memory results);
}

/// @dev See the Solidity Scripting tutorial: https://book.getfoundry.sh/guides/scripting-with-solidity
contract ReplaceTimelockAdmin is Script, Deployments {
    function run() public {
        string memory root = vm.projectRoot();
        string memory deployEnv = vm.envString("DEPLOYMENT_ENV");
        string memory path = string.concat(root, DEPLOYMENT_DIR, "/", deployEnv, "/", Strings.toString(block.chainid), ".json");
        string memory json = vm.readFile(path);

        address newTimelockAdmin = vm.promptAddress("New timelock admin");

        ProxiedICS26RouterDeployment memory deployment = loadProxiedICS26RouterDeployment(vm, json);
        AccessManagerDeployment memory accessManagerDeployment = loadAccessManagerDeployment(json);
        vm.assertNotEq(accessManagerDeployment.accessManager, address(0), "AccessManager address must not be zero");
        vm.assertNotEq(newTimelockAdmin, address(0), "New timelock admin must not be zero");
        vm.assertNotEq(newTimelockAdmin, deployment.timelockAdmin, "New timelock admin must be different");

        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeCall(IAccessManager.grantRole, (IBCRolesLib.ADMIN_ROLE, newTimelockAdmin, 0));
        calls[1] = abi.encodeCall(IAccessManager.revokeRole, (IBCRolesLib.ADMIN_ROLE, deployment.timelockAdmin));

        vm.startBroadcast();

        IAccessManagerMulticall(accessManagerDeployment.accessManager).multicall(calls);

        vm.stopBroadcast();

        // Update the deployment JSON
        vm.writeJson(vm.toString(address(newTimelockAdmin)), path, ".ics26Router.timelockAdmin");
    }
}
