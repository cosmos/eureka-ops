// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import "forge-std/console.sol";

import { Script } from "forge-std/Script.sol";
import { Deployments } from "./helpers/Deployments.sol";
import { AccessManager } from "@openzeppelin-contracts/access/manager/AccessManager.sol";
import { IAccessManager } from "@openzeppelin-contracts/access/manager/IAccessManager.sol";
import { Strings } from "@openzeppelin-contracts/utils/Strings.sol";
import { ICS20Transfer } from "solidity-ibc-eureka/contracts/ICS20Transfer.sol";
import { IBCRolesLib } from "solidity-ibc-eureka/contracts/utils/IBCRolesLib.sol";

/// @dev See the Solidity Scripting tutorial: https://book.getfoundry.sh/guides/scripting-with-solidity
contract GrantRateLimiterRole is Script, Deployments {
    function run() public {
        string memory root = vm.projectRoot();
        string memory deployEnv = vm.envString("DEPLOYMENT_ENV");
        string memory path =
            string.concat(root, DEPLOYMENT_DIR, deployEnv, "/", Strings.toString(block.chainid), ".json");
        string memory json = vm.readFile(path);

        string memory clientId = vm.prompt("Client ID of the escrow address to grant the role to");
        address rateLimiterAddress = vm.promptAddress("Rate limiter address");

        ProxiedICS20TransferDeployment memory deployment = loadProxiedICS20TransferDeployment(vm, json);
        AccessManagerDeployment memory accessManagerDeployment = loadAccessManagerDeployment(json);
        vm.assertNotEq(accessManagerDeployment.accessManager, address(0), "AccessManager address must not be zero");

        ICS20Transfer ics20Transfer = ICS20Transfer(deployment.proxy);
        address escrow = ics20Transfer.getEscrow(clientId);
        vm.assertNotEq(escrow, address(0), "Escrow address must not be zero");

        // NOTE: RATE_LIMITER_ROLE is a single manager-wide role, while the restriction is configured per escrow
        // target. Once multiple escrows have had their target function role configured, every RATE_LIMITER_ROLE
        // holder can set rate limits on all of them — there is no per-escrow isolation.
        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeCall(
            IAccessManager.setTargetFunctionRole,
            (escrow, IBCRolesLib.rateLimiterSelectors(), IBCRolesLib.RATE_LIMITER_ROLE)
        );
        calls[1] = abi.encodeCall(IAccessManager.grantRole, (IBCRolesLib.RATE_LIMITER_ROLE, rateLimiterAddress, 0));

        vm.startBroadcast();
        (, address sender,) = vm.readCallers();
        _requireAccessManagerAdmin(accessManagerDeployment.accessManager, sender);

        AccessManager(accessManagerDeployment.accessManager).multicall(calls);

        vm.stopBroadcast();
    }
}
