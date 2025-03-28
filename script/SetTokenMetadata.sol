// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import "forge-std/console.sol";

import { Script } from "forge-std/Script.sol";
import { Deployments } from "solidity-ibc-eureka/scripts/helpers/Deployments.sol";
import { IBCERC20 } from "solidity-ibc-eureka/contracts/utils/IBCERC20.sol";
import { Strings } from "@openzeppelin-contracts/utils/Strings.sol";
import "@openzeppelin/contracts/utils/math/SafeCast.sol";

/// @dev See the Solidity Scripting tutorial: https://book.getfoundry.sh/guides/scripting-with-solidity
contract GrantMetadataRole is Script, Deployments {
    using SafeCast for uint256;

    function run() public {
        address ibcERC20Address = vm.promptAddress("IBCERC20 address");
        uint256 customDecimals = vm.promptUint("Custom Decimals");
        string memory customName = vm.prompt("Custom Name");
        string memory customSymbol = vm.prompt("Custom Symbol");

        IBCERC20 ibcERC20 = IBCERC20(ibcERC20Address);

        vm.startBroadcast();

        ibcERC20.setMetadata(customDecimals.toUint8(), customName, customSymbol);

        vm.stopBroadcast();
    }
}
