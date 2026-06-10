// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { Vm } from "forge-std/Vm.sol";
import { stdJson } from "forge-std/StdJson.sol";

abstract contract Deployments {
    using stdJson for string;

    string internal constant DEPLOYMENT_DIR = "/deployments/";

    struct AccessManagerDeployment {
        address accessManager;
        address admin;
        address[] relayers;
        address[] pausers;
        address[] unpausers;
        address[] delegateSenders;
        address[] idCustomizers;
        address[] erc20Customizers;
    }

    function loadAccessManagerDeployment(string memory json) public view returns (AccessManagerDeployment memory) {
        address[] memory empty = new address[](0);
        address[] memory idCustomizers = json.keyExists(".accessManagerRoles.idCustomizers")
            ? json.readAddressArrayOr(".accessManagerRoles.idCustomizers", empty)
            : _legacyIdCustomizers(json);
        address[] memory erc20Customizers = json.keyExists(".accessManagerRoles.erc20Customizers")
            ? json.readAddressArrayOr(".accessManagerRoles.erc20Customizers", empty)
            : _singleNonZero(json.readAddressOr(".ics20Transfer.tokenOperator", address(0)));

        return AccessManagerDeployment({
            accessManager: json.readAddressOr(".accessManager", address(0)),
            admin: json.readAddressOr(
                ".accessManagerRoles.admin", json.readAddressOr(".ics26Router.timelockAdmin", address(0))
            ),
            relayers: json.readAddressArrayOr(
                ".accessManagerRoles.relayers", json.readAddressArrayOr(".ics26Router.relayers", empty)
            ),
            pausers: json.readAddressArrayOr(
                ".accessManagerRoles.pausers", json.readAddressArrayOr(".ics20Transfer.pausers", empty)
            ),
            unpausers: json.readAddressArrayOr(
                ".accessManagerRoles.unpausers", json.readAddressArrayOr(".ics20Transfer.unpausers", empty)
            ),
            delegateSenders: json.readAddressArrayOr(
                ".accessManagerRoles.delegateSenders", json.readAddressArrayOr(".ics20Transfer.delegateSenders", empty)
            ),
            idCustomizers: idCustomizers,
            erc20Customizers: erc20Customizers
        });
    }

    function _writeAccessManagerRoles(Vm vm, string memory path, AccessManagerDeployment memory deployment) internal {
        vm.serializeAddress("accessManagerRoles", "admin", deployment.admin);
        vm.serializeAddress("accessManagerRoles", "relayers", deployment.relayers);
        vm.serializeAddress("accessManagerRoles", "pausers", deployment.pausers);
        vm.serializeAddress("accessManagerRoles", "unpausers", deployment.unpausers);
        vm.serializeAddress("accessManagerRoles", "delegateSenders", deployment.delegateSenders);
        vm.serializeAddress("accessManagerRoles", "idCustomizers", deployment.idCustomizers);
        string memory rolesJson =
            vm.serializeAddress("accessManagerRoles", "erc20Customizers", deployment.erc20Customizers);
        vm.writeJson(rolesJson, path, ".accessManagerRoles");
    }

    function _legacyIdCustomizers(string memory json) private view returns (address[] memory) {
        address clientIdCustomizer = json.readAddressOr(".ics26Router.clientIdCustomizer", address(0));
        address portCustomizer = json.readAddressOr(".ics26Router.portCustomizer", address(0));

        if (clientIdCustomizer == address(0)) {
            return _singleNonZero(portCustomizer);
        }
        if (portCustomizer == address(0) || portCustomizer == clientIdCustomizer) {
            return _singleNonZero(clientIdCustomizer);
        }

        address[] memory customizers = new address[](2);
        customizers[0] = clientIdCustomizer;
        customizers[1] = portCustomizer;
        return customizers;
    }

    function _singleNonZero(address value) private pure returns (address[] memory values) {
        if (value == address(0)) {
            return new address[](0);
        }

        values = new address[](1);
        values[0] = value;
    }

    struct ICS27GMPDeployment {
        address implementation;
        address accountImplementation;
        address proxy;
    }

    function loadICS27GMPDeployment(string memory json) public view returns (ICS27GMPDeployment memory) {
        return ICS27GMPDeployment({
            implementation: json.readAddressOr(".ics27Gmp.implementation", address(0)),
            accountImplementation: json.readAddressOr(".ics27Gmp.accountImplementation", address(0)),
            proxy: json.readAddressOr(".ics27Gmp.proxy", address(0))
        });
    }

    struct SP1ICS07TendermintDeployment {
        // The verifier address can be set in the environment variables.
        // If not set, then the verifier is set based on the zkAlgorithm.
        // If set to "mock", then the verifier is set to a mock verifier.
        address implementation;
        string clientId;
        string counterpartyClientId;
        string verifier;
        string[] merklePrefix;
        bytes trustedClientState;
        bytes32 trustedConsensusStateHash;
        bytes32 updateClientVkey;
        bytes32 membershipVkey;
        bytes32 ucAndMembershipVkey;
        bytes32 misbehaviourVkey;
        address proofSubmitter;
    }

    function loadSP1ICS07TendermintDeployment(
        string memory json,
        string memory key,
        address defaultProofSubmitter
    )
        public
        view
        returns (SP1ICS07TendermintDeployment memory)
    {
        return SP1ICS07TendermintDeployment({
            clientId: json.readStringOr(string.concat(key, ".clientId"), ""),
            verifier: json.readStringOr(string.concat(key, ".verifier"), ""),
            merklePrefix: json.readStringArrayOr(string.concat(key, ".merklePrefix"), new string[](0)),
            counterpartyClientId: json.readStringOr(string.concat(key, ".counterpartyClientId"), ""),
            implementation: json.readAddressOr(string.concat(key, ".implementation"), address(0)),
            trustedClientState: json.readBytes(string.concat(key, ".trustedClientState")),
            trustedConsensusStateHash: json.readBytes32(string.concat(key, ".trustedConsensusStateHash")),
            updateClientVkey: json.readBytes32(string.concat(key, ".updateClientVkey")),
            membershipVkey: json.readBytes32(string.concat(key, ".membershipVkey")),
            ucAndMembershipVkey: json.readBytes32(string.concat(key, ".ucAndMembershipVkey")),
            misbehaviourVkey: json.readBytes32(string.concat(key, ".misbehaviourVkey")),
            proofSubmitter: json.readAddressOr(string.concat(key, ".proofSubmitter"), defaultProofSubmitter)
        });
    }

    // TODO: Move these to ops repo
    function loadSP1ICS07TendermintDeployments(
        Vm vm,
        string memory json,
        address defaultProofSubmitter
    )
        public
        view
        returns (SP1ICS07TendermintDeployment[] memory)
    {
        string[] memory keys = vm.parseJsonKeys(json, "$.light_clients");
        SP1ICS07TendermintDeployment[] memory deployments = new SP1ICS07TendermintDeployment[](keys.length);

        for (uint256 i = 0; i < keys.length; i++) {
            string memory key = string.concat(".light_clients['", keys[i], "']");
            deployments[i] = loadSP1ICS07TendermintDeployment(json, key, defaultProofSubmitter);
        }

        return deployments;
    }

    struct ProxiedICS26RouterDeployment {
        address implementation;
        address proxy;
        address timelockAdmin;
        address portCustomizer;
        address clientIdCustomizer;
        address[] relayers;
    }

    function loadProxiedICS26RouterDeployment(
        Vm vm,
        string memory json
    )
        public
        pure
        returns (ProxiedICS26RouterDeployment memory)
    {
        ProxiedICS26RouterDeployment memory fixture = ProxiedICS26RouterDeployment({
            implementation: vm.parseJsonAddress(json, ".ics26Router.implementation"),
            proxy: vm.parseJsonAddress(json, ".ics26Router.proxy"),
            timelockAdmin: vm.parseJsonAddress(json, ".ics26Router.timelockAdmin"),
            portCustomizer: vm.parseJsonAddress(json, ".ics26Router.portCustomizer"),
            clientIdCustomizer: vm.parseJsonAddress(json, ".ics26Router.clientIdCustomizer"),
            relayers: vm.parseJsonAddressArray(json, ".ics26Router.relayers")
        });

        return fixture;
    }

    struct ProxiedICS20TransferDeployment {
        // transparant proxies
        address ics26Router;

        // implementation addresses
        address implementation;
        address escrowImplementation;
        address ibcERC20Implementation;

        // admin control
        address[] pausers;
        address[] unpausers;
        address[] delegateSenders;
        address tokenOperator;
        address permit2;
        address proxy;
    }

    // TODO: Move these to ops repo
    function loadProxiedICS20TransferDeployment(
        Vm vm,
        string memory json
    )
        public
        view
        returns (ProxiedICS20TransferDeployment memory)
    {
        address[] memory defaultDelegateSenders = new address[](0);

        // abi.decode(vm.parseJson(json, ".ics20Transfer"), (ProxiedICS20TransferDeployment));
        ProxiedICS20TransferDeployment memory fixture = ProxiedICS20TransferDeployment({
            escrowImplementation: vm.parseJsonAddress(json, ".ics20Transfer.escrowImplementation"),
            ibcERC20Implementation: vm.parseJsonAddress(json, ".ics20Transfer.ibcERC20Implementation"),
            ics26Router: vm.parseJsonAddress(json, ".ics20Transfer.ics26Router"),
            implementation: vm.parseJsonAddress(json, ".ics20Transfer.implementation"),
            pausers: vm.parseJsonAddressArray(json, ".ics20Transfer.pausers"),
            unpausers: vm.parseJsonAddressArray(json, ".ics20Transfer.unpausers"),
            delegateSenders: json.readAddressArrayOr(".ics20Transfer.delegateSenders", defaultDelegateSenders),
            tokenOperator: vm.parseJsonAddress(json, ".ics20Transfer.tokenOperator"),
            permit2: vm.parseJsonAddress(json, ".ics20Transfer.permit2"),
            proxy: vm.parseJsonAddress(json, ".ics20Transfer.proxy")
        });

        return fixture;
    }
}
