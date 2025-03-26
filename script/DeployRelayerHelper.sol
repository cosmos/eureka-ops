// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import "forge-std/console.sol";

import { Script } from "forge-std/Script.sol";
import { Deployments } from "solidity-ibc-eureka/scripts/helpers/Deployments.sol";
import { RelayerHelper } from "solidity-ibc-eureka/contracts/utils/RelayerHelper.sol";
import { Strings } from "@openzeppelin-contracts/utils/Strings.sol";

/// @dev See the Solidity Scripting tutorial: https://book.getfoundry.sh/guides/scripting-with-solidity
contract UpgradeICS26 is Script, Deployments {
    function run() public {
        string memory root = vm.projectRoot();
        string memory deployEnv = vm.envString("DEPLOYMENT_ENV");
        string memory path = string.concat(root, DEPLOYMENT_DIR, "/", deployEnv, "/", Strings.toString(block.chainid), ".json");
        string memory json = vm.readFile(path);

        ProxiedICS26RouterDeployment memory deployment = loadProxiedICS26RouterDeployment(vm, json);

        vm.startBroadcast();

        // Deploy new Relayer Helper
        address relayerHelper = address(new RelayerHelper(deployment.proxy));

        vm.stopBroadcast();

        console.log("Deployed Realyer Helper", relayerHelper);
    }
}
