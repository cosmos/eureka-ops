// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import "forge-std/console.sol";

import { AccessManager } from "@openzeppelin-contracts/access/manager/AccessManager.sol";
import { ERC1967Proxy } from "@openzeppelin-contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { IAccessManager } from "@openzeppelin-contracts/access/manager/IAccessManager.sol";
import { Strings } from "@openzeppelin-contracts/utils/Strings.sol";
import { Script } from "forge-std/Script.sol";
import { Deployments } from "./helpers/Deployments.sol";
import { V3UpgradeSelectors } from "./helpers/V3UpgradeSelectors.sol";
import { IBCRolesLib } from "solidity-ibc-eureka/contracts/utils/IBCRolesLib.sol";
import { ICS27GMP } from "solidity-ibc-eureka/contracts/ICS27GMP.sol";
import { ICS27Account } from "solidity-ibc-eureka/contracts/utils/ICS27Account.sol";
import { DeployAccessManagerWithRoles } from "solidity-ibc-eureka/scripts/deployments/DeployAccessManagerWithRoles.sol";

/// @notice Shared AccessManager wiring for the v3 IBC contracts.
/// @dev Mixed into both the bootstrap below and other scripts (e.g. DeployV3Core, shadow rehearsals) so that
/// every flow configures the same target function roles and role grants on a manager it currently administers.
/// The base target-function-role wiring is inherited from the upstream `DeployAccessManagerWithRoles` helper so
/// it stays in lockstep with the contracts; only the two selectors not yet exposed by IBCRolesLib are added here.
abstract contract V3AccessManagerConfigurator is DeployAccessManagerWithRoles {
    function _setTargetRoles(IAccessManager manager, address ics26, address ics20, address ics27) internal {
        accessManagerSetTargetRoles(manager, ics26, ics20, ics27, false);
        manager.setTargetFunctionRole(ics26, V3UpgradeSelectors.ics26MigrationSelectors(), IBCRolesLib.ADMIN_ROLE);
        manager.setTargetFunctionRole(ics27, V3UpgradeSelectors.ics27BeaconSelectors(), IBCRolesLib.ADMIN_ROLE);
    }

    /// @notice Deploys the raw ICS27GMP contracts (account implementation, GMP implementation, initialized proxy).
    /// @dev Shared low-level helper used by both the bootstrap and the fresh-deploy path (the latter via
    /// `DeployV3Core._deployICS27Stack`) so both initialize the proxy identically.
    function _deployICS27GmpContracts(
        address ics26Proxy,
        address accessManager
    )
        internal
        returns (address implementation, address accountImplementation, address proxy)
    {
        accountImplementation = address(new ICS27Account());
        implementation = address(new ICS27GMP());
        proxy = address(
            new ERC1967Proxy(
                implementation, abi.encodeCall(ICS27GMP.initialize, (ics26Proxy, accountImplementation, accessManager))
            )
        );
    }

    function _grantRoles(IAccessManager manager, Deployments.AccessManagerDeployment memory deployment) internal {
        for (uint256 i = 0; i < deployment.relayers.length; ++i) {
            manager.grantRole(IBCRolesLib.RELAYER_ROLE, deployment.relayers[i], 0);
        }
        for (uint256 i = 0; i < deployment.pausers.length; ++i) {
            manager.grantRole(IBCRolesLib.PAUSER_ROLE, deployment.pausers[i], 0);
        }
        for (uint256 i = 0; i < deployment.unpausers.length; ++i) {
            manager.grantRole(IBCRolesLib.UNPAUSER_ROLE, deployment.unpausers[i], 0);
        }
        for (uint256 i = 0; i < deployment.delegateSenders.length; ++i) {
            manager.grantRole(IBCRolesLib.DELEGATE_SENDER_ROLE, deployment.delegateSenders[i], 0);
        }
        for (uint256 i = 0; i < deployment.idCustomizers.length; ++i) {
            manager.grantRole(IBCRolesLib.ID_CUSTOMIZER_ROLE, deployment.idCustomizers[i], 0);
        }
        for (uint256 i = 0; i < deployment.erc20Customizers.length; ++i) {
            manager.grantRole(IBCRolesLib.ERC20_CUSTOMIZER_ROLE, deployment.erc20Customizers[i], 0);
        }
    }
}

/// @notice Deploys and fully configures the v3 AccessManager plus the new ICS27GMP stack in one transaction.
/// @dev The constructor makes this contract the initial AccessManager admin so it can configure target function
/// roles and role grants permissionlessly, including for the freshly deployed ICS27GMP proxy. ICS27 is deployed
/// here (and not in a separate script) because its restrictions can only be wired up before this contract hands
/// `ADMIN_ROLE` to the timelock admin and renounces; doing it later would require timelocked admin operations.
/// The resulting addresses are exposed as immutables because everything happens inside the constructor — they
/// are read back by the deploy script to record the deployment JSON.
contract V3AccessManagerBootstrap is V3AccessManagerConfigurator {
    address public immutable accessManager;
    address public immutable ics27GmpImplementation;
    address public immutable ics27AccountImplementation;
    address public immutable ics27Gmp;

    constructor(
        Deployments.AccessManagerDeployment memory accessManagerDeployment,
        Deployments.ProxiedICS26RouterDeployment memory ics26,
        Deployments.ProxiedICS20TransferDeployment memory ics20
    ) {
        require(accessManagerDeployment.admin != address(0), "timelock admin must be set");

        AccessManager manager = new AccessManager(address(this));
        (address implementation, address accountImplementation, address proxy) =
            _deployICS27GmpContracts(ics26.proxy, address(manager));

        _setTargetRoles(manager, ics26.proxy, ics20.proxy, proxy);
        _grantRoles(manager, accessManagerDeployment);

        manager.grantRole(IBCRolesLib.ADMIN_ROLE, accessManagerDeployment.admin, 0);
        manager.renounceRole(IBCRolesLib.ADMIN_ROLE, address(this));

        accessManager = address(manager);
        ics27GmpImplementation = implementation;
        ics27AccountImplementation = accountImplementation;
        ics27Gmp = proxy;
    }
}

/// @notice Step 2 of the v2-to-v3 upgrade: deploys the AccessManager and ICS27GMP stack via
/// V3AccessManagerBootstrap and records the addresses and role holders in the deployment JSON.
contract DeployV3AccessManager is Script, Deployments {
    function run() public returns (address) {
        string memory root = vm.projectRoot();
        string memory deployEnv = vm.envString("DEPLOYMENT_ENV");
        string memory path =
            string.concat(root, DEPLOYMENT_DIR, deployEnv, "/", Strings.toString(block.chainid), ".json");
        string memory json = vm.readFile(path);

        AccessManagerDeployment memory accessManagerDeployment = loadAccessManagerDeployment(json);
        vm.assertEq(accessManagerDeployment.accessManager, address(0), "accessManager already set in deployment JSON");
        vm.assertNotEq(accessManagerDeployment.admin, address(0), "timelock admin must be set");

        ProxiedICS26RouterDeployment memory ics26 = loadProxiedICS26RouterDeployment(vm, json);
        ProxiedICS20TransferDeployment memory ics20 = loadProxiedICS20TransferDeployment(vm, json);
        ICS27GMPDeployment memory ics27 = loadICS27GMPDeployment(json);
        vm.assertNotEq(ics26.proxy, address(0), "ICS26Router proxy must be set");
        vm.assertNotEq(ics20.proxy, address(0), "ICS20Transfer proxy must be set");
        vm.assertEq(ics27.proxy, address(0), "ICS27GMP proxy already set in deployment JSON");
        vm.assertEq(
            accessManagerDeployment.admin,
            ics26.timelockAdmin,
            "accessManagerRoles.admin must match ics26Router.timelockAdmin"
        );

        vm.startBroadcast();
        V3AccessManagerBootstrap bootstrap = new V3AccessManagerBootstrap(accessManagerDeployment, ics26, ics20);
        address manager = bootstrap.accessManager();
        ics27 = ICS27GMPDeployment({
            implementation: bootstrap.ics27GmpImplementation(),
            accountImplementation: bootstrap.ics27AccountImplementation(),
            proxy: bootstrap.ics27Gmp()
        });
        vm.stopBroadcast();

        vm.writeJson(vm.toString(manager), path, ".accessManager");
        _writeICS27GMP(vm, path, ics27);
        _writeAccessManagerRoles(vm, path, accessManagerDeployment);
        console.log("AccessManager deployed at: ", manager);
        console.log("ICS27GMP deployed at: ", ics27.proxy);
        return manager;
    }
}
