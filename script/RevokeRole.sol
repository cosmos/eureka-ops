// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

// solhint-disable gas-custom-errors,no-global-import

import "forge-std/console.sol";

import { Script } from "forge-std/Script.sol";
import { Deployments } from "./helpers/Deployments.sol";
import { IAccessManager } from "@openzeppelin-contracts/access/manager/IAccessManager.sol";
import { Strings } from "@openzeppelin-contracts/utils/Strings.sol";
import { stdJson } from "forge-std/StdJson.sol";

contract RevokeRole is Script, Deployments {
    using stdJson for string;

    function run() public {
        string memory root = vm.projectRoot();
        string memory deployEnv = vm.envString("DEPLOYMENT_ENV");
        string memory path = string.concat(root, DEPLOYMENT_DIR, "/", deployEnv, "/", Strings.toString(block.chainid), ".json");
        string memory json = vm.readFile(path);

        AccessManagerDeployment memory accessManagerDeployment = loadAccessManagerDeployment(json);
        vm.assertNotEq(accessManagerDeployment.accessManager, address(0), "AccessManager address must not be zero");

        uint64 role = uint64(vm.envUint("REVOKE_ROLE"));
        address grantee = vm.promptAddress("Grantee to revoke address");

        vm.startBroadcast();

        IAccessManager(accessManagerDeployment.accessManager).revokeRole(role, grantee);

        vm.stopBroadcast();

        console.log("Grantee address revoked: ", grantee);
        console.log("Role: ", role);
        console.log("AccessManager: ", accessManagerDeployment.accessManager);
    }
}
