// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { IICS02ClientAccessControlled } from "solidity-ibc-eureka/contracts/interfaces/IICS02Client.sol";
import { IICS27GMP } from "solidity-ibc-eureka/contracts/interfaces/IICS27GMP.sol";

/// @notice Selector lists that the v3 upgrade wires to ADMIN_ROLE but that IBCRolesLib does not yet expose.
/// @dev Kept in one place so the configurator that wires the target function roles and the verifier that
/// asserts them cannot drift. Remove once these are added to IBCRolesLib upstream
/// (cosmos/solidity-ibc-eureka#1046).
library V3UpgradeSelectors {
    function ics26MigrationSelectors() internal pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](1);
        selectors[0] = IICS02ClientAccessControlled.migrateClient.selector;
    }

    function ics27BeaconSelectors() internal pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](1);
        selectors[0] = IICS27GMP.upgradeAccountTo.selector;
    }
}
