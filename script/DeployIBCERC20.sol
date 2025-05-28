// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { Script } from "forge-std/Script.sol";
import { TimelockController } from "@openzeppelin-contracts/governance/TimelockController.sol";
import { Deployments } from "./helpers/Deployments.sol";
import { Strings } from "@openzeppelin-contracts/utils/Strings.sol";
import { IBCERC20 } from "solidity-ibc-eureka/contracts/utils/IBCERC20.sol";
import { IIBCERC20 } from "solidity-ibc-eureka/contracts/interfaces/IIBCERC20.sol";
import { IEscrow } from "solidity-ibc-eureka/contracts/interfaces/IEscrow.sol";
import { BeaconProxy } from "@openzeppelin-contracts/proxy/beacon/BeaconProxy.sol";
import { ICS20Transfer } from "solidity-ibc-eureka/contracts/ICS20Transfer.sol";
import { ERC1967Proxy } from "@openzeppelin-contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { ICS20Lib } from "solidity-ibc-eureka/contracts/utils/ICS20Lib.sol";
import "forge-std/console.sol";

contract DeployIBCERC20 is Script, Deployments {
    function run() public {
        string memory root = vm.projectRoot();
        string memory deployEnv = vm.envString("DEPLOYMENT_ENV");
        string memory path = string.concat(root, DEPLOYMENT_DIR, "/", deployEnv, "/", Strings.toString(block.chainid), ".json");
        string memory json = vm.readFile(path);

        ProxiedICS20TransferDeployment memory ics20TransferDeployment = loadProxiedICS20TransferDeployment(vm, json);

        string memory denom = vm.prompt("Base Denom on Cosmos side (e.g. uatom, transfer/channel-69/herpderp)");
        string memory clientId = vm.prompt("Client ID on Ethereum (destination client ID when sending from Cosmos)");

        // TODO: Ensure client ID exists

        ICS20Transfer ics20Transfer = ICS20Transfer(ics20TransferDeployment.proxy);

        bytes memory denomPrefix = abi.encodePacked(ICS20Lib.DEFAULT_PORT_ID, "/", clientId, "/");
        bytes memory fullDenomPath = abi.encodePacked(denomPrefix, bytes(denom));
        address escrow = ics20Transfer.getEscrow(clientId);

        bytes memory initCalldata =  abi.encodeCall(IIBCERC20.initialize, (ics20TransferDeployment.proxy, escrow, string(fullDenomPath)));

        ERC1967Proxy ibcerc20Proxy = new ERC1967Proxy(ics20TransferDeployment.ibcERC20Implementation, initCalldata);

        console.log("Deployed IBCERC20 with ERC1967 Proxy at: ", address(ibcerc20Proxy));
        console.log("Implementation address used: ", ics20TransferDeployment.ibcERC20Implementation);
    }
}
