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
        string memory path =
            string.concat(root, DEPLOYMENT_DIR, deployEnv, "/", Strings.toString(block.chainid), ".json");
        string memory json = vm.readFile(path);

        AccessManagerDeployment memory accessManagerDeployment = loadAccessManagerDeployment(json);
        vm.assertNotEq(accessManagerDeployment.accessManager, address(0), "AccessManager address must not be zero");

        uint256 roleValue = vm.envUint("REVOKE_ROLE");
        // v3 roles are AccessManager uint64 role ids; a value this large is most likely a v2 bytes32 role hash.
        require(roleValue <= type(uint64).max, "REVOKE_ROLE does not fit in uint64");
        // casting to 'uint64' is safe because the require above bounds-checks the value
        // forge-lint: disable-next-line(unsafe-typecast)
        uint64 role = uint64(roleValue);
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
