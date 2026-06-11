// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

// solhint-disable gas-custom-errors,no-global-import

import "forge-std/console.sol";

import { Script } from "forge-std/Script.sol";
import { Deployments } from "./helpers/Deployments.sol";
import { Strings } from "@openzeppelin-contracts/utils/Strings.sol";
import { stdJson } from "forge-std/StdJson.sol";
import { UUPSUpgradeable } from "@openzeppelin-contracts/proxy/utils/UUPSUpgradeable.sol";
import { ERC1967Utils } from "@openzeppelin-contracts/proxy/ERC1967/ERC1967Utils.sol";
import { IAccessManaged } from "@openzeppelin-contracts/access/manager/IAccessManaged.sol";

contract UpgradeProxy is Script, Deployments {
    using stdJson for string;

    function run() public {
        string memory root = vm.projectRoot();
        string memory deployEnv = vm.envString("DEPLOYMENT_ENV");
        string memory path =
            string.concat(root, DEPLOYMENT_DIR, deployEnv, "/", Strings.toString(block.chainid), ".json");
        string memory json = vm.readFile(path);

        ProxiedICS26RouterDeployment memory ics26RouterDeployment = loadProxiedICS26RouterDeployment(vm, json);
        ProxiedICS20TransferDeployment memory ics20TransferDeployment = loadProxiedICS20TransferDeployment(vm, json);
        ICS27GMPDeployment memory ics27GmpDeployment = loadICS27GMPDeployment(json);
        address accessManager = json.readAddressOr(".accessManager", address(0));

        bool ics26Changed = getImplementation(ics26RouterDeployment.proxy) != ics26RouterDeployment.implementation;
        bool ics20Changed = getImplementation(ics20TransferDeployment.proxy) != ics20TransferDeployment.implementation;
        // ICS27GMP is only present in v3 deployments; treat it as unchanged when the proxy is not set.
        bool ics27Changed = ics27GmpDeployment.proxy != address(0)
            && getImplementation(ics27GmpDeployment.proxy) != ics27GmpDeployment.implementation;

        uint256 changedCount = (ics26Changed ? 1 : 0) + (ics20Changed ? 1 : 0) + (ics27Changed ? 1 : 0);
        require(
            changedCount == 1,
            "One (and only one) of the uups upgradable contract implementations should have changed in the deployment json to run this script"
        );

        vm.startBroadcast();
        if (ics26Changed) {
            _requireAlreadyAccessManaged(ics26RouterDeployment.proxy, accessManager);
            UUPSUpgradeable(ics26RouterDeployment.proxy)
                .upgradeToAndCall(ics26RouterDeployment.implementation, bytes(""));
            console.log("ICS26 Router upgraded to: ", ics26RouterDeployment.implementation);
        } else if (ics20Changed) {
            _requireAlreadyAccessManaged(ics20TransferDeployment.proxy, accessManager);
            UUPSUpgradeable(ics20TransferDeployment.proxy)
                .upgradeToAndCall(ics20TransferDeployment.implementation, bytes(""));
            console.log("ICS20 Transfer upgraded to: ", ics20TransferDeployment.implementation);
        } else {
            // ICS27GMP has no initializeV2, so an empty-calldata upgrade is correct for it.
            UUPSUpgradeable(ics27GmpDeployment.proxy).upgradeToAndCall(ics27GmpDeployment.implementation, bytes(""));
            console.log("ICS27GMP upgraded to: ", ics27GmpDeployment.implementation);
        }
        vm.stopBroadcast();
    }

    /// @dev This script upgrades with empty calldata. During the v2-to-v3 migration `ICS26Router`/`ICS20Transfer`
    /// must instead be upgraded with `initializeV2(accessManager)` calldata via the `schedule-v3-*-upgrade-params`
    /// recipes; an empty-calldata upgrade there would leave the proxy without an AccessManager authority and brick
    /// every restricted function. Refuse unless the proxy is already AccessManaged by the recorded AccessManager
    /// (i.e. initializeV2 already ran), which is the case for routine post-v3 implementation upgrades.
    function _requireAlreadyAccessManaged(address proxy, address accessManager) private view {
        if (accessManager == address(0)) {
            // Pre-v3 deployment (no AccessManager): legacy empty-calldata upgrade is the intended behavior.
            return;
        }

        address authority = address(0);
        try IAccessManaged(proxy).authority() returns (address current) {
            authority = current;
        } catch {
            authority = address(0);
        }

        require(
            authority == accessManager,
            "proxy is not yet AccessManaged by the recorded AccessManager; use the schedule-v3-*-upgrade-params recipes that call initializeV2 (see runbooks/upgrade-v2-to-v3.md)"
        );
    }

    function getImplementation(address proxy) internal view returns (address) {
        return address(uint160(uint256(vm.load(proxy, ERC1967Utils.IMPLEMENTATION_SLOT))));
    }
}
