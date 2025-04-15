// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

// solhint-disable custom-errors,gas-custom-errors

import "forge-std/console.sol";

import { Deployments } from "./helpers/Deployments.sol";
import { ICS26Router } from "solidity-ibc-eureka/contracts/ICS26Router.sol";
import { ICS20Transfer } from "solidity-ibc-eureka/contracts/ICS20Transfer.sol";
import { Escrow } from "solidity-ibc-eureka/contracts/utils/Escrow.sol";
import { IBCERC20 } from "solidity-ibc-eureka/contracts/utils/IBCERC20.sol";
import { IIBCUUPSUpgradeable } from "solidity-ibc-eureka/contracts/interfaces/IIBCUUPSUpgradeable.sol";
import { Strings } from "@openzeppelin-contracts/utils/Strings.sol";
import { ERC1967Proxy } from "@openzeppelin-contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { ERC1967Utils } from "@openzeppelin-contracts/proxy/ERC1967/ERC1967Utils.sol";
import { Script } from "forge-std/Script.sol";
import { UserInputConstants } from "./GenerateUserInputJSON.sol";

contract DeployImplementation is Script, Deployments {
    using Strings for string;

    function run() public returns (address){
        string memory contractToDeploy = vm.envString("LOGIC_CONTRACT");

        address implementation;

        vm.startBroadcast();
        if (contractToDeploy.equal(UserInputConstants.ICS26_ROUTER_IMPL)) {
            console.log("Deploying ICS26Router implementation");
            implementation = address(new ICS26Router());
        } else if (contractToDeploy.equal(UserInputConstants.ICS20_TRANSFER_IMPL)) {
            console.log("Deploying ICS20Transfer implementation");
            implementation = address(new ICS20Transfer());
        } else if (contractToDeploy.equal(UserInputConstants.ESCROW_IMPL)) {
            console.log("Deploying Escrow implementation");
            implementation = address(new Escrow());
        } else if (contractToDeploy.equal(UserInputConstants.IBCERC20_IMPL)) {
            console.log("Deploying IBCERC20 implementation");
            implementation = address(new IBCERC20());
        }
        else {
            revert("Unknown contract to deploy");
        }
        vm.stopBroadcast();

        console.log("Deployed %s implementation at %s", contractToDeploy, implementation);

        return implementation;
    }
}

