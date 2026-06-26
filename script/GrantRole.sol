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

contract GrantRole is Script, Deployments {
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
        uint64 role = SafeCast.toUint64(vm.envUint("GRANT_ROLE"));
        address grantee = vm.promptAddress("Grantee address");

        vm.startBroadcast();
        (, address sender,) = vm.readCallers();
        _requireAccessManagerAdmin(accessManagerDeployment.accessManager, sender);
        bytes memory preCalldata = vm.envOr("PRE_CALLDATA", bytes(""));
        if (preCalldata.length > 0) {
            address preCallAddress = vm.envAddress("PRE_CALL_CONTRACT_ADDRESS");
            (bool success,) = preCallAddress.call(preCalldata);
            require(success, "Pre-call failed");
        }

        IAccessManager(accessManagerDeployment.accessManager).grantRole(role, grantee, 0);

        vm.stopBroadcast();

        console.log("Grantee address: ", grantee);
        console.log("Role: ", role);
        console.log("AccessManager: ", accessManagerDeployment.accessManager);
    }
}
