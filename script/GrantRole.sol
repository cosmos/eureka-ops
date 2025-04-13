// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

// solhint-disable gas-custom-errors,no-global-import

import "forge-std/console.sol";

import { Script } from "forge-std/Script.sol";
import { Deployments } from "solidity-ibc-eureka/scripts/helpers/Deployments.sol";
import { ICS20Transfer } from "solidity-ibc-eureka/contracts/ICS20Transfer.sol";
import { AccessControlUpgradeable } from "@openzeppelin-upgradeable/access/AccessControlUpgradeable.sol";
import { Strings } from "@openzeppelin-contracts/utils/Strings.sol";
import { stdJson } from "forge-std/StdJson.sol";

contract GrantRole is Script, Deployments {
    using stdJson for string;

    function run() public {
        string memory root = vm.projectRoot();
        string memory deployEnv = vm.envString("DEPLOYMENT_ENV");
        string memory path = string.concat(root, DEPLOYMENT_DIR, "/", deployEnv, "/", Strings.toString(block.chainid), ".json");
        string memory json = vm.readFile(path);

        ProxiedICS26RouterDeployment memory ics26RouterDeployment = loadProxiedICS26RouterDeployment(vm, json);
        ProxiedICS20TransferDeployment memory ics20TransferDeployment = loadProxiedICS20TransferDeployment(vm, json);

        bytes32 role = vm.envBytes32("GRANT_ROLE");
        address contractAddress = vm.envAddress("GRANT_CONTRACT_ADDRESS");
        address grantee = vm.promptAddress("Grantee address");

        vm.startBroadcast();

        if (contractAddress == ics26RouterDeployment.proxy) {
            grantGenericRole(role, contractAddress, grantee);
        } else if (contractAddress == ics20TransferDeployment.proxy) {
            grantICS20Role(role, contractAddress, grantee);
        } else {
            revert("Invalid/unimplemented contract");
        }

        vm.stopBroadcast();

        console.log("Grantee address: ", grantee);
        console.log("Role: ", vm.toString(role));
        console.log("Contract address: ", contractAddress);
    }

    function grantGenericRole(bytes32 role, address contractAddress, address grantee) public {
        AccessControlUpgradeable accessControl = AccessControlUpgradeable(contractAddress);
        accessControl.grantRole(role, grantee);
    }

    function grantICS20Role(bytes32 role, address contractAddress, address grantee) public {
        ICS20Transfer ics20Transfer = ICS20Transfer(contractAddress);

        if (role == ics20Transfer.PAUSER_ROLE()) {
            ics20Transfer.grantPauserRole(grantee);
        } else if (role == ics20Transfer.UNPAUSER_ROLE()) {
            ics20Transfer.grantUnpauserRole(grantee);
        } else if (role == ics20Transfer.TOKEN_OPERATOR_ROLE()) {
            ics20Transfer.grantTokenOperatorRole(grantee);
        } else if (role == ics20Transfer.DELEGATE_SENDER_ROLE()) {
            ics20Transfer.grantDelegateSenderRole(grantee);
        } else {
            revert("Invalid/unimplemented role");
        }
    }
}
