// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import "forge-std/console.sol";

import { Script } from "forge-std/Script.sol";
import { Deployments } from "./helpers/Deployments.sol";
import { IBCERC20 } from "solidity-ibc-eureka/contracts/utils/IBCERC20.sol";
import { IIBCERC20 } from "solidity-ibc-eureka/contracts/interfaces/IIBCERC20.sol";
import { Strings } from "@openzeppelin-contracts/utils/Strings.sol";

/// @dev See the Solidity Scripting tutorial: https://book.getfoundry.sh/guides/scripting-with-solidity
contract GrantMetadataRole is Script, Deployments {
    function run() public {
        address ibcERC20Address = vm.promptAddress("IBCERC20 address");
        address metadataCustomizerAddress = vm.promptAddress("Grantee to grant metadata customizer role");

        bytes memory cData = abi.encodeCall(IIBCERC20.grantMetadataCustomizerRole, (metadataCustomizerAddress));

        console.log("calldata", vm.toString(cData));

        vm.startBroadcast();

        (bool success,) = address(ibcERC20Address).call(cData);
        require(success, "Failed to grant metadata customizer role");

        vm.stopBroadcast();
    }
}
