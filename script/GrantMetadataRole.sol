// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import "forge-std/console.sol";

import { Script } from "forge-std/Script.sol";
import { Deployments } from "./helpers/Deployments.sol";

/// @dev See the Solidity Scripting tutorial: https://book.getfoundry.sh/guides/scripting-with-solidity
contract GrantMetadataRole is Script, Deployments {
    function run() public pure {
        revert("IBCERC20 metadata customizer role was removed in solidity-ibc-eureka v3");
    }
}
