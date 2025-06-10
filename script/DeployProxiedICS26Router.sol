// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

// solhint-disable custom-errors,gas-custom-errors

import { Deployments } from "./helpers/Deployments.sol";
import { DeploymentVerifier } from "./VerifyDeployment.sol";
import { stdJson } from "forge-std/StdJson.sol";
import { ICS26Router } from "solidity-ibc-eureka/contracts/ICS26Router.sol";
import { IIBCUUPSUpgradeable } from "solidity-ibc-eureka/contracts/interfaces/IIBCUUPSUpgradeable.sol";
import { Strings } from "@openzeppelin-contracts/utils/Strings.sol";
import { ERC1967Proxy } from "@openzeppelin-contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { ERC1967Utils } from "@openzeppelin-contracts/proxy/ERC1967/ERC1967Utils.sol";
import { Script } from "forge-std/Script.sol";

contract DeployProxiedICS26RouterScript is DeploymentVerifier {
    using stdJson for string;

    function run() public returns (address){
        string memory root = vm.projectRoot();
        string memory deployEnv = vm.envString("DEPLOYMENT_ENV");
        string memory path = string.concat(root, DEPLOYMENT_DIR, deployEnv, "/", Strings.toString(block.chainid), ".json");
        string memory json = vm.readFile(path);

        ProxiedICS26RouterDeployment memory deployment = loadProxiedICS26RouterDeployment(vm, json);

        vm.assertEq(deployment.implementation, address(0), "Implementation address must be zero for deployment");
        vm.assertEq(deployment.proxy, address(0), "Proxy address must be zero for deployment");

        vm.startBroadcast();

        deployment.implementation = address(new ICS26Router());

        ERC1967Proxy routerProxy = deployProxiedICS26Router(deployment);
        deployment.proxy = payable(address(routerProxy));

        vm.stopBroadcast();

        verifyICS26Router(deployment);

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

    
    function deployProxiedICS26Router(Deployments.ProxiedICS26RouterDeployment memory deployment) public returns (ERC1967Proxy) {
        require(msg.sender == deployment.timelockAdmin, "sender must be timelockAdmin");

        ERC1967Proxy routerProxy = new ERC1967Proxy(
            deployment.implementation,
            abi.encodeCall(ICS26Router.initialize, (deployment.timelockAdmin))
        );

        ICS26Router ics26Router = ICS26Router(address(routerProxy));

        for (uint256 i = 0; i < deployment.relayers.length; i++) {
            ics26Router.grantRole(ics26Router.RELAYER_ROLE(), deployment.relayers[i]);
        }

        ics26Router.grantRole(ics26Router.PORT_CUSTOMIZER_ROLE(), deployment.portCustomizer);
        ics26Router.grantRole(ics26Router.CLIENT_ID_CUSTOMIZER_ROLE(), deployment.clientIdCustomizer);

        return routerProxy;
    }
}

