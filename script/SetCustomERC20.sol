// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import "forge-std/console.sol";

import { Script } from "forge-std/Script.sol";
import { Deployments } from "./helpers/Deployments.sol";
import { Strings } from "@openzeppelin-contracts/utils/Strings.sol";
import { ICS20Transfer } from "solidity-ibc-eureka/contracts/ICS20Transfer.sol";
import { ICS20Lib } from "solidity-ibc-eureka/contracts/utils/ICS20Lib.sol";
import "@openzeppelin/contracts/utils/math/SafeCast.sol";

/// @dev See the Solidity Scripting tutorial: https://book.getfoundry.sh/guides/scripting-with-solidity
contract SetCustomERC20 is Script, Deployments {
    using SafeCast for uint256;

    function run() public {
        string memory root = vm.projectRoot();
        string memory deployEnv = vm.envString("DEPLOYMENT_ENV");
        string memory path = string.concat(root, DEPLOYMENT_DIR, "/", deployEnv, "/", Strings.toString(block.chainid), ".json");
        string memory json = vm.readFile(path);

        ProxiedICS20TransferDeployment memory ics20TransferDeployment = loadProxiedICS20TransferDeployment(vm, json);
        ICS20Transfer ics20Transfer = ICS20Transfer(ics20TransferDeployment.proxy);

        address customERC20Address = vm.promptAddress("Custom ERC20 Address");
        string memory denom = vm.prompt("Base Denom on Cosmos side (e.g. uatom, transfer/channel-42/uderp)");
        string memory clientId = vm.prompt("Client ID on Ethereum (destination client ID when sending from Cosmos)");

        bytes memory denomPrefix = abi.encodePacked(ICS20Lib.DEFAULT_PORT_ID, "/", clientId, "/");
        bytes memory fullDenomPath = abi.encodePacked(denomPrefix, bytes(denom));


        vm.startBroadcast();

        ics20Transfer.setCustomERC20(string(fullDenomPath), customERC20Address);

        vm.stopBroadcast();
    }
}
