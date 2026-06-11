// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { Test } from "forge-std/Test.sol";
import { ICS26Router } from "solidity-ibc-eureka/contracts/ICS26Router.sol";
import { ICS20Transfer } from "solidity-ibc-eureka/contracts/ICS20Transfer.sol";
import { Escrow } from "solidity-ibc-eureka/contracts/utils/Escrow.sol";
import { UUPSUpgradeable } from "@openzeppelin-contracts/proxy/utils/UUPSUpgradeable.sol";
import { IICS02ClientAccessControlled } from "solidity-ibc-eureka/contracts/interfaces/IICS02Client.sol";
import { IICS20TransferAccessControlled } from "solidity-ibc-eureka/contracts/interfaces/IICS20Transfer.sol";
import { IICS27GMP } from "solidity-ibc-eureka/contracts/interfaces/IICS27GMP.sol";

/// @notice Guards the function-signature string constants in `consts.just` against drift from the v3 contracts.
/// @dev The shadow rehearsal builds upgrade transactions in Solidity (abi.encodeCall), while the production
/// timelock calldata is assembled in bash from the `consts.just` signature strings; the rehearsal therefore
/// never exercises those strings. These assertions fail if a signature string stops matching the selector the
/// deployed contract actually exposes. The string literals below MUST be kept identical to `consts.just`.
contract ConstSignaturesTest is Test {
    function test_upgradeToAndCallSignature() public pure {
        // consts.just: UPGRADE_TO_AND_CALL_SIG
        assertEq(bytes4(keccak256("upgradeToAndCall(address,bytes)")), UUPSUpgradeable.upgradeToAndCall.selector);
    }

    function test_initializeV2Signature() public pure {
        // consts.just: INITIALIZE_V2_SIG (both core proxies expose the same selector)
        assertEq(bytes4(keccak256("initializeV2(address)")), ICS26Router.initializeV2.selector);
        assertEq(bytes4(keccak256("initializeV2(address)")), ICS20Transfer.initializeV2.selector);
    }

    function test_initializeEscrowV2Signature() public pure {
        // consts.just: INITIALIZE_ESCROW_V2_SIG
        assertEq(bytes4(keccak256("initializeV2()")), Escrow.initializeV2.selector);
    }

    function test_migrateClientSignature() public pure {
        // consts.just: MIGRATE_CLIENT_V3_SIG
        assertEq(
            bytes4(keccak256("migrateClient(string,(string,bytes[]),address)")),
            IICS02ClientAccessControlled.migrateClient.selector
        );
    }

    function test_beaconUpgradeSignatures() public pure {
        // consts.just: UPGRADE_ESCROW_SIG / UPGRADE_IBC_ERC20_SIG / UPGRADE_ACCOUNT_SIG
        assertEq(bytes4(keccak256("upgradeEscrowTo(address)")), IICS20TransferAccessControlled.upgradeEscrowTo.selector);
        assertEq(
            bytes4(keccak256("upgradeIBCERC20To(address)")), IICS20TransferAccessControlled.upgradeIBCERC20To.selector
        );
        assertEq(bytes4(keccak256("upgradeAccountTo(address)")), IICS27GMP.upgradeAccountTo.selector);
    }
}
