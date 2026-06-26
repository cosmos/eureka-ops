// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { Test } from "forge-std/Test.sol";
import { TimelockController } from "@openzeppelin-contracts/governance/TimelockController.sol";
import { Safe } from "@safe-global/safe-smart-account/contracts/Safe.sol";
import { SafeProxyFactory } from "@safe-global/safe-smart-account/contracts/proxies/SafeProxyFactory.sol";
import { MultiSendCallOnly } from "@safe-global/safe-smart-account/contracts/libraries/MultiSendCallOnly.sol";
import { Enum } from "@safe-global/safe-smart-account/contracts/common/Enum.sol";

/// @dev Minimal call target standing in for an upgradeable proxy. It records how many times it was invoked so the
/// test can assert atomicity and ordering, and it can be flipped to revert so a single sub-call can be made to fail
/// inside a batch. In production the targets are the ICS20Transfer / ICS26Router / Escrow / IBCERC20 proxies and the
/// data is `upgradeToAndCall(newImplementation, ...)`.
contract UpgradeTarget {
    uint256 public calls;
    bool public reverts;

    function setReverts(bool value) external {
        reverts = value;
    }

    function upgrade() external {
        require(!reverts, "UpgradeTarget: forced revert");
        calls++;
    }
}

/// @notice Proves the atomic Safe MultiSend execute path: the four v3 core upgrades (plus SP1 light-client migrations,
/// here represented by the same `UpgradeTarget.upgrade` shape) can be executed atomically as ONE Safe MultiSend
/// transaction routed through a
/// real `TimelockController`, with all-or-nothing semantics and the recipe's predecessor ordering preserved.
///
/// The setup mirrors production: a 1-of-1 Safe proxy holds both PROPOSER and EXECUTOR roles on the timelock; the
/// batch is a `MultiSendCallOnly.multiSend` payload that the Safe runs via DELEGATECALL, so each `timelock.execute`
/// sub-call sees `msg.sender == safe` (the executor). The ICS26Router upgrade is scheduled with the ICS20Transfer
/// upgrade operation id as its `predecessor`, exactly as `schedule-v3-ics26router-upgrade-params` wires it, so the
/// timelock refuses the router upgrade until the transfer upgrade is done.
///
/// This guards the multisend batching strategy and the timelock semantics it depends on against drift. The
/// proxy/`initializeV2` internals and the v2-to-v3 admin coupling require v2 sources and are exercised by the
/// shadow-fork rehearsal, not here.
contract SafeMultiSendV3UpgradeTest is Test {
    /// @dev Fixed test key for the sole Safe owner; its address is the single 1-of-1 signer.
    uint256 internal constant OWNER_PK = 0xA11CE;
    uint256 internal constant DELAY = 100;

    Safe internal safe;
    MultiSendCallOnly internal ms;
    TimelockController internal timelock;

    UpgradeTarget internal ics20; // stands in for the ICS20Transfer proxy
    UpgradeTarget internal ics26; // stands in for the ICS26Router proxy
    UpgradeTarget internal escrow; // stands in for the Escrow proxy
    UpgradeTarget internal ibcerc20; // stands in for the IBCERC20 proxy

    bytes internal upgradeData;

    bytes32 internal ics20Op;
    bytes32 internal ics26Op;
    bytes32 internal escrowOp;
    bytes32 internal ibcerc20Op;

    function setUp() public {
        // Deploy a real 1-of-1 Safe via the canonical singleton + proxy factory flow.
        Safe singleton = new Safe();
        SafeProxyFactory factory = new SafeProxyFactory();

        address[] memory owners = new address[](1);
        owners[0] = vm.addr(OWNER_PK);
        bytes memory initializer =
            abi.encodeCall(Safe.setup, (owners, 1, address(0), "", address(0), address(0), 0, payable(address(0))));
        safe = Safe(payable(address(factory.createProxyWithNonce(address(singleton), initializer, 0))));

        ms = new MultiSendCallOnly();

        // The Safe is the only proposer and the only executor, mirroring production (admin renounced).
        address[] memory proposers = new address[](1);
        proposers[0] = address(safe);
        address[] memory executors = new address[](1);
        executors[0] = address(safe);
        timelock = new TimelockController(DELAY, proposers, executors, address(0));

        ics20 = new UpgradeTarget();
        ics26 = new UpgradeTarget();
        escrow = new UpgradeTarget();
        ibcerc20 = new UpgradeTarget();
        upgradeData = abi.encodeCall(UpgradeTarget.upgrade, ());

        ics20Op = timelock.hashOperation(address(ics20), 0, upgradeData, bytes32(0), bytes32(0));
        // The router upgrade carries the transfer upgrade as its predecessor, exactly as the recipe wires it.
        ics26Op = timelock.hashOperation(address(ics26), 0, upgradeData, ics20Op, bytes32(0));
        escrowOp = timelock.hashOperation(address(escrow), 0, upgradeData, bytes32(0), bytes32(0));
        ibcerc20Op = timelock.hashOperation(address(ibcerc20), 0, upgradeData, bytes32(0), bytes32(0));

        // Schedule all four operations through the Safe (the proposer), then warp past the delay.
        _scheduleViaSafe(address(ics20), bytes32(0));
        _scheduleViaSafe(address(ics26), ics20Op);
        _scheduleViaSafe(address(escrow), bytes32(0));
        _scheduleViaSafe(address(ibcerc20), bytes32(0));

        vm.warp(block.timestamp + DELAY + 1);
    }

    /// @dev The whole v3 upgrade runs as a single Safe MultiSend: one `execTransaction` executes all four timelock
    /// operations in order, every target upgrades exactly once, and the timelock marks every operation done.
    function test_atomicBatchExecutesAllInOrder() public {
        bytes[] memory calls = new bytes[](4);
        calls[0] = _executeCalldata(address(ics20), bytes32(0));
        calls[1] = _executeCalldata(address(ics26), ics20Op); // depends on ics20 being done first
        calls[2] = _executeCalldata(address(escrow), bytes32(0));
        calls[3] = _executeCalldata(address(ibcerc20), bytes32(0));

        _runBatchViaSafe(_packExecutes(calls));

        assertEq(ics20.calls(), 1, "ics20 upgrade must run exactly once");
        assertEq(ics26.calls(), 1, "ics26 upgrade must run exactly once");
        assertEq(escrow.calls(), 1, "escrow upgrade must run exactly once");
        assertEq(ibcerc20.calls(), 1, "ibcerc20 upgrade must run exactly once");

        assertTrue(timelock.isOperationDone(ics20Op), "ics20 op must be done");
        assertTrue(timelock.isOperationDone(ics26Op), "ics26 op must be done");
        assertTrue(timelock.isOperationDone(escrowOp), "escrow op must be done");
        assertTrue(timelock.isOperationDone(ibcerc20Op), "ibcerc20 op must be done");
    }

    /// @dev All-or-nothing: when a sub-call in the middle of the batch reverts, the `MultiSendCallOnly`
    /// `require(success)` rolls back the entire delegatecall, so the Safe transaction reverts and no target's state
    /// changed - not even the targets whose sub-calls preceded the failing one.
    function test_batchIsAtomic_allOrNothing() public {
        // The escrow upgrade (3rd in the batch) is forced to revert; ics20 and ics26 sit before it.
        escrow.setReverts(true);

        bytes[] memory calls = new bytes[](4);
        calls[0] = _executeCalldata(address(ics20), bytes32(0));
        calls[1] = _executeCalldata(address(ics26), ics20Op);
        calls[2] = _executeCalldata(address(escrow), bytes32(0));
        calls[3] = _executeCalldata(address(ibcerc20), bytes32(0));

        (bytes memory data, bytes memory sig) = _signBatch(_packExecutes(calls));

        // Safe wraps the failed delegatecall as Error("GS013") because safeTxGas == 0 && gasPrice == 0.
        vm.expectRevert(abi.encodeWithSignature("Error(string)", "GS013"));
        safe.execTransaction(
            address(ms), 0, data, Enum.Operation.DelegateCall, 0, 0, 0, address(0), payable(address(0)), sig
        );

        // Nothing executed: the earlier sub-calls were rolled back together with the failing one.
        assertEq(ics20.calls(), 0, "ics20 must be rolled back");
        assertEq(ics26.calls(), 0, "ics26 must be rolled back");
        assertEq(escrow.calls(), 0, "escrow never succeeded");
        assertEq(ibcerc20.calls(), 0, "ibcerc20 must not run");

        assertFalse(timelock.isOperationDone(ics20Op), "ics20 op must not be marked done");
        assertFalse(timelock.isOperationDone(ics26Op), "ics26 op must not be marked done");
    }

    /// @dev The in-batch predecessor is honored: executing the router op alone (transfer op not yet done) reverts,
    /// while a batch with the transfer op before the router op in the same MultiSend succeeds.
    function test_orderingPreservedInBatch() public {
        // Contrast: a MultiSend that tries the router upgrade before the transfer upgrade reverts (predecessor not
        // done), so the whole Safe transaction reverts and the router upgrade does not run.
        bytes[] memory routerOnly = new bytes[](1);
        routerOnly[0] = _executeCalldata(address(ics26), ics20Op);

        (bytes memory badData, bytes memory badSig) = _signBatch(_packExecutes(routerOnly));
        // Safe wraps the failed delegatecall as Error("GS013") because safeTxGas == 0 && gasPrice == 0.
        vm.expectRevert(abi.encodeWithSignature("Error(string)", "GS013"));
        safe.execTransaction(
            address(ms), 0, badData, Enum.Operation.DelegateCall, 0, 0, 0, address(0), payable(address(0)), badSig
        );
        assertEq(ics26.calls(), 0, "router upgrade must not run before the transfer upgrade");
        assertFalse(timelock.isOperationDone(ics26Op), "router op must not be done");

        // Correct order in one batch: transfer first, then router; the in-batch predecessor is satisfied.
        bytes[] memory ordered = new bytes[](2);
        ordered[0] = _executeCalldata(address(ics20), bytes32(0));
        ordered[1] = _executeCalldata(address(ics26), ics20Op);

        _runBatchViaSafe(_packExecutes(ordered));

        assertEq(ics20.calls(), 1, "transfer upgrade must run");
        assertEq(ics26.calls(), 1, "router upgrade must run after the transfer upgrade");
        assertTrue(timelock.isOperationDone(ics20Op), "transfer op must be done");
        assertTrue(timelock.isOperationDone(ics26Op), "router op must be done");
    }

    /// @dev Builds the `timelock.execute(target, 0, upgradeData, predecessor, 0)` calldata for one upgrade op.
    function _executeCalldata(address target, bytes32 predecessor) private view returns (bytes memory) {
        return abi.encodeCall(TimelockController.execute, (target, 0, upgradeData, predecessor, bytes32(0)));
    }

    /// @dev Packs timelock-execute sub-calls into the Safe MultiSend wire format. Each sub-tx is
    /// `abi.encodePacked(uint8(0) operation, address to, uint256 value, uint256 dataLength, bytes data)` with `to`
    /// fixed to the timelock; all entries are concatenated.
    function _packExecutes(bytes[] memory calls) private view returns (bytes memory packed) {
        for (uint256 i = 0; i < calls.length; i++) {
            packed = bytes.concat(
                packed, abi.encodePacked(uint8(0), address(timelock), uint256(0), calls[i].length, calls[i])
            );
        }
    }

    /// @dev Computes the Safe transaction hash for a DelegateCall MultiSend and signs it with the owner key.
    function _signBatch(bytes memory packed) private view returns (bytes memory data, bytes memory sig) {
        data = abi.encodeCall(MultiSendCallOnly.multiSend, (packed));
        bytes32 txHash = safe.getTransactionHash(
            address(ms), 0, data, Enum.Operation.DelegateCall, 0, 0, 0, address(0), address(0), safe.nonce()
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(OWNER_PK, txHash);
        sig = abi.encodePacked(r, s, v);
    }

    /// @dev Signs and executes a MultiSend batch through the Safe via DELEGATECALL (the canonical multisend path).
    function _runBatchViaSafe(bytes memory packed) private {
        (bytes memory data, bytes memory sig) = _signBatch(packed);
        safe.execTransaction(
            address(ms), 0, data, Enum.Operation.DelegateCall, 0, 0, 0, address(0), payable(address(0)), sig
        );
    }

    /// @dev Schedules one upgrade op through the Safe (the proposer) with a plain `Call` to the timelock.
    function _scheduleViaSafe(address target, bytes32 predecessor) private {
        bytes memory data =
            abi.encodeCall(TimelockController.schedule, (target, 0, upgradeData, predecessor, bytes32(0), DELAY));
        bytes32 txHash = safe.getTransactionHash(
            address(timelock), 0, data, Enum.Operation.Call, 0, 0, 0, address(0), address(0), safe.nonce()
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(OWNER_PK, txHash);
        bytes memory sig = abi.encodePacked(r, s, v);
        safe.execTransaction(
            address(timelock), 0, data, Enum.Operation.Call, 0, 0, 0, address(0), payable(address(0)), sig
        );
    }
}
