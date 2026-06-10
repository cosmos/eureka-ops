// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { Test } from "forge-std/Test.sol";
import { Deployments } from "../../script/helpers/Deployments.sol";

contract DeploymentsTest is Test, Deployments {
    function test_accessManagerRolesPreserveExplicitEmptyCustomizerLists() public view {
        string memory json = string.concat(
            "{",
            '"accessManagerRoles":{"idCustomizers":[],"erc20Customizers":[]},',
            '"ics26Router":{',
            '"clientIdCustomizer":"0x0000000000000000000000000000000000000001",',
            '"portCustomizer":"0x0000000000000000000000000000000000000002"',
            "},",
            '"ics20Transfer":{"tokenOperator":"0x0000000000000000000000000000000000000003"}',
            "}"
        );

        AccessManagerDeployment memory deployment = loadAccessManagerDeployment(json);

        assertEq(deployment.idCustomizers.length, 0);
        assertEq(deployment.erc20Customizers.length, 0);
    }

    function test_accessManagerRolesFallbackToLegacyCustomizersWhenKeysMissing() public view {
        string memory json = string.concat(
            "{",
            '"ics26Router":{',
            '"clientIdCustomizer":"0x0000000000000000000000000000000000000001",',
            '"portCustomizer":"0x0000000000000000000000000000000000000002"',
            "},",
            '"ics20Transfer":{"tokenOperator":"0x0000000000000000000000000000000000000003"}',
            "}"
        );

        AccessManagerDeployment memory deployment = loadAccessManagerDeployment(json);

        assertEq(deployment.idCustomizers.length, 2);
        assertEq(deployment.idCustomizers[0], address(1));
        assertEq(deployment.idCustomizers[1], address(2));
        assertEq(deployment.erc20Customizers.length, 1);
        assertEq(deployment.erc20Customizers[0], address(3));
    }
}
