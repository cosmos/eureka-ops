// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

// solhint-disable custom-errors,gas-custom-errors

import { Script } from "forge-std/Script.sol";
import { Deployments } from "./helpers/Deployments.sol";
import { DeploymentVerifier } from "./VerifyDeployment.sol";
import { ERC1967Proxy } from "@openzeppelin-contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { IBeacon } from "@openzeppelin-contracts/proxy/beacon/IBeacon.sol";
import { ERC1967Utils } from "@openzeppelin-contracts/proxy/ERC1967/ERC1967Utils.sol";
import { ICS20Transfer } from "solidity-ibc-eureka/contracts/ICS20Transfer.sol";
import { IICS26Router } from "solidity-ibc-eureka/contracts/interfaces/IICS26Router.sol";
import { ICS20Lib } from "solidity-ibc-eureka/contracts/utils/ICS20Lib.sol";
import { stdJson } from "forge-std/StdJson.sol";
import { IBCERC20 } from "solidity-ibc-eureka/contracts/utils/IBCERC20.sol";
import { Escrow } from "solidity-ibc-eureka/contracts/utils/Escrow.sol";
import { IBCPausableUpgradeable } from "solidity-ibc-eureka/contracts/utils/IBCPausableUpgradeable.sol";
import { Strings } from "@openzeppelin-contracts/utils/Strings.sol";
import "forge-std/console.sol";

contract DeployProxiedICS20TransferScript is DeploymentVerifier {

    function run() public returns (address){
        string memory root = vm.projectRoot();
        string memory deployEnv = vm.envString("DEPLOYMENT_ENV");
        string memory path = string.concat(root, DEPLOYMENT_DIR, "/", deployEnv, "/", Strings.toString(block.chainid), ".json");
        string memory json = vm.readFile(path);

        ProxiedICS20TransferDeployment memory deployment = loadProxiedICS20TransferDeployment(vm, json);

        vm.assertEq(deployment.implementation, address(0), "Implementation address must be zero for deployment");
        vm.assertEq(deployment.proxy, address(0), "Proxy address must be zero for deployment");
        vm.assertEq(deployment.ibcERC20Implementation, address(0), "IBCERC20 implementation address must be zero for deployment");
        vm.assertEq(deployment.escrowImplementation, address(0), "Escrow implementation address must be zero for deployment");
        vm.assertNotEq(deployment.ics26Router, address(0), "ICS26Router address must not be zero for deployment");

        vm.startBroadcast();

        deployment.implementation = address(new ICS20Transfer());
        deployment.ibcERC20Implementation = address(new IBCERC20());
        deployment.escrowImplementation = address(new Escrow());

        ERC1967Proxy transferProxy = deployProxiedICS20Transfer(deployment);
    
        IICS26Router ics26Router = IICS26Router(deployment.ics26Router);
        ics26Router.addIBCApp(ICS20Lib.DEFAULT_PORT_ID, address(transferProxy));

        vm.stopBroadcast();

        deployment.proxy = payable(address(transferProxy));
        verifyICS20Transfer(deployment);

        vm.serializeAddress("ics20Transfer", "proxy", address(transferProxy));
        vm.serializeAddress("ics20Transfer", "implementation", deployment.implementation);
        vm.serializeAddress("ics20Transfer", "escrowImplementation", deployment.escrowImplementation);
        vm.serializeAddress("ics20Transfer", "ibcERC20Implementation", deployment.ibcERC20Implementation);
        vm.serializeAddress("ics20Transfer", "pausers", deployment.pausers);
        vm.serializeAddress("ics20Transfer", "unpausers", deployment.unpausers);
        vm.serializeAddress("ics20Transfer", "tokenOperator", deployment.tokenOperator);
        vm.serializeAddress("ics20Transfer", "ics26Router", deployment.ics26Router);
        string memory output = vm.serializeAddress("ics20Transfer", "permit2", deployment.permit2);

        vm.writeJson(output, path, ".ics20Transfer");

        return address(transferProxy);
    }

        function deployProxiedICS20Transfer(Deployments.ProxiedICS20TransferDeployment memory deployment) public returns (ERC1967Proxy) {
        ERC1967Proxy transferProxy = new ERC1967Proxy(
            deployment.implementation,
            abi.encodeCall(
                ICS20Transfer.initialize,
                (
                    deployment.ics26Router,
                    deployment.escrowImplementation,
                    deployment.ibcERC20Implementation,
                    deployment.permit2
                )
            )
        );

        console.log("Deployed ICS20Transfer at address: ", address(transferProxy));

        ICS20Transfer ics20Transfer = ICS20Transfer(address(transferProxy));

        if (deployment.pausers.length != 0) {
            for (uint32 i = 0; i < deployment.pausers.length; i++) {
                address pauser = deployment.pausers[i];
                console.log("Granting pauser role to: ", pauser);
                ics20Transfer.grantPauserRole(pauser);
            }
        }

        if (deployment.unpausers.length != 0) {
            for (uint32 i = 0; i < deployment.unpausers.length; i++) {
                address unpauser = deployment.unpausers[i];
                console.log("Granting unpauser role to: ", unpauser);
                ics20Transfer.grantUnpauserRole(unpauser);
            }
        }

        if (deployment.tokenOperator != address(0)) {
            address tokenOperator = deployment.tokenOperator;
            console.log("Granting tokenOperator role to: ", tokenOperator);
            ics20Transfer.grantTokenOperatorRole(tokenOperator);
        }

        return transferProxy;
    }
}
