// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

// solhint-disable custom-errors,gas-custom-errors

import { Deployments } from "./helpers/Deployments.sol";
import { DeploymentVerifier } from "./VerifyDeployment.sol";
import { stdJson } from "forge-std/StdJson.sol";
import { ICS26Router } from "solidity-ibc-eureka/contracts/ICS26Router.sol";
import { Strings } from "@openzeppelin-contracts/utils/Strings.sol";
import { ERC1967Proxy } from "@openzeppelin-contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract DeployProxiedICS26RouterScript is DeploymentVerifier {
    using stdJson for string;

    function run() public returns (address){
        string memory root = vm.projectRoot();
        string memory deployEnv = vm.envString("DEPLOYMENT_ENV");
        string memory path = string.concat(root, DEPLOYMENT_DIR, deployEnv, "/", Strings.toString(block.chainid), ".json");
        string memory json = vm.readFile(path);

        ProxiedICS26RouterDeployment memory deployment = loadProxiedICS26RouterDeployment(vm, json);
        AccessManagerDeployment memory accessManagerDeployment = loadAccessManagerDeployment(json);

        vm.assertEq(deployment.implementation, address(0), "Implementation address must be zero for deployment");
        vm.assertEq(deployment.proxy, address(0), "Proxy address must be zero for deployment");
        vm.assertNotEq(accessManagerDeployment.accessManager, address(0), "AccessManager address must not be zero");

        vm.startBroadcast();

        deployment.implementation = address(new ICS26Router());

        ERC1967Proxy routerProxy = deployProxiedICS26Router(deployment, accessManagerDeployment.accessManager);
        deployment.proxy = payable(address(routerProxy));

        vm.stopBroadcast();

        verifyICS26Router(deployment, accessManagerDeployment);

        vm.serializeAddress("ics26Router", "proxy", address(routerProxy));
        vm.serializeAddress("ics26Router", "implementation", deployment.implementation);
        vm.serializeAddress("ics26Router", "timelockAdmin", deployment.timelockAdmin);
        vm.serializeAddress("ics26Router", "clientIdCustomizer", deployment.clientIdCustomizer);
        vm.serializeAddress("ics26Router", "portCustomizer", deployment.portCustomizer);
        vm.serializeAddress("ics26Router", "relayers", deployment.relayers);
        string memory output = vm.serializeAddress("ics26Router", "portCustomizer", deployment.portCustomizer);

        vm.writeJson(output, path, ".ics26Router");
        vm.writeJson(vm.toString(address(routerProxy)), path, ".ics20Transfer.ics26Router");

        return address(routerProxy);
    }


    function deployProxiedICS26Router(Deployments.ProxiedICS26RouterDeployment memory deployment, address accessManager) public returns (ERC1967Proxy) {
        ERC1967Proxy routerProxy = new ERC1967Proxy(
            deployment.implementation,
            abi.encodeCall(ICS26Router.initialize, (accessManager))
        );

        return routerProxy;
    }
}

