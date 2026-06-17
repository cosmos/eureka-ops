// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

// solhint-disable gas-custom-errors,no-global-import

import "forge-std/console.sol";

import { Script } from "forge-std/Script.sol";
import { Deployments } from "./helpers/Deployments.sol";
import { IAccessManager } from "@openzeppelin-contracts/access/manager/IAccessManager.sol";
import { SafeCast } from "@openzeppelin-contracts/utils/math/SafeCast.sol";
import { Strings } from "@openzeppelin-contracts/utils/Strings.sol";
import { stdJson } from "forge-std/StdJson.sol";

contract RevokeRole is Script, Deployments {
    using stdJson for string;

    function run() public {
        string memory root = vm.projectRoot();
        string memory deployEnv = vm.envString("DEPLOYMENT_ENV");
        string memory path =
            string.concat(root, DEPLOYMENT_DIR, deployEnv, "/", Strings.toString(block.chainid), ".json");
        string memory json = vm.readFile(path);

        AccessManagerDeployment memory accessManagerDeployment = loadAccessManagerDeployment(json);
        vm.assertNotEq(accessManagerDeployment.accessManager, address(0), "AccessManager address must not be zero");

        // v3 roles are AccessManager uint64 role ids; SafeCast reverts if a v2 bytes32 role hash is passed by mistake.
        uint64 role = SafeCast.toUint64(vm.envUint("REVOKE_ROLE"));

        // ADMIN_ROLE (id 0) is the AccessManager's self-administration root; revoking it from the timelock would
        // permanently brick governance (nobody could re-grant any role afterwards). Refuse by default and require an
        // explicit opt-in for the rare legitimate case (e.g. removing a stray admin flagged by validate-v3-roles.py).
        if (role == 0) {
            require(
                vm.envOr("ALLOW_REVOKE_ADMIN", false),
                "RevokeRole: refusing to revoke ADMIN_ROLE (0); set ALLOW_REVOKE_ADMIN=true to override"
            );
        }

        address grantee = vm.promptAddress("Grantee to revoke address");

        vm.startBroadcast();
        (, address sender,) = vm.readCallers();
        _requireAccessManagerAdmin(accessManagerDeployment.accessManager, sender);

        IAccessManager(accessManagerDeployment.accessManager).revokeRole(role, grantee);

        vm.stopBroadcast();

        console.log("Grantee address revoked: ", grantee);
        console.log("Role: ", role);
        console.log("AccessManager: ", accessManagerDeployment.accessManager);
    }
}
