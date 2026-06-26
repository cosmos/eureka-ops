// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { Test } from "forge-std/Test.sol";
import { TimelockController } from "@openzeppelin-contracts/governance/TimelockController.sol";

/// @dev Minimal call target standing in for an upgradeable proxy; records how many times it was invoked so the
/// test can assert execution order.
contract OrderedTarget {
    uint256 public calls;

    function upgrade() external {
        calls++;
    }
}

/// @notice Locks in the TimelockController predecessor wiring that `schedule-v3-ics26router-upgrade-params` relies
/// on: the ICS26Router upgrade is scheduled with the ICS20Transfer upgrade operation as its `predecessor`
/// (computed via `_v3-ics20-upgrade-operation-id` -> `TimelockController.hashOperation`), so the timelock refuses
/// to execute the router upgrade until the transfer upgrade is done.
///
/// This guards the recipe intent and the timelock semantics it depends on against drift (e.g. a recipe edit that
/// drops the predecessor, or an OpenZeppelin upgrade that changes ordering behavior). The proxy/`initializeV2`
/// internals and the v2-to-v3 admin coupling require v2 sources and are exercised by the shadow-fork rehearsal,
/// not here. In production the targets are the ICS20Transfer/ICS26Router proxies and the data is
/// `upgradeToAndCall(newImplementation, initializeV2(accessManager))`.
contract TimelockUpgradeOrderingTest is Test {
    TimelockController internal timelock;
    OrderedTarget internal ics20; // stands in for the ICS20Transfer proxy
    OrderedTarget internal ics26; // stands in for the ICS26Router proxy

    uint256 internal constant DELAY = 100;
    bytes internal upgradeData;

    function setUp() public {
        address[] memory proposers = new address[](1);
        proposers[0] = address(this);
        address[] memory executors = new address[](1);
        executors[0] = address(this);
        timelock = new TimelockController(DELAY, proposers, executors, address(0));

        ics20 = new OrderedTarget();
        ics26 = new OrderedTarget();
        upgradeData = abi.encodeCall(OrderedTarget.upgrade, ());
    }

    /// @dev The router upgrade carries the transfer upgrade as its predecessor and cannot execute until the
    /// transfer upgrade is done; the documented order (transfer first, then router) then succeeds.
    function test_routerUpgradeBlockedUntilTransferUpgradeDone() public {
        bytes32 transferOpId = timelock.hashOperation(address(ics20), 0, upgradeData, bytes32(0), bytes32(0));

        timelock.schedule(address(ics20), 0, upgradeData, bytes32(0), bytes32(0), DELAY);
        // predecessor = transfer operation id, exactly what schedule-v3-ics26router-upgrade-params wires in.
        timelock.schedule(address(ics26), 0, upgradeData, transferOpId, bytes32(0), DELAY);

        vm.warp(block.timestamp + DELAY + 1);

        // Mis-ordered: executing the router upgrade first reverts (predecessor not done).
        vm.expectRevert();
        timelock.execute(address(ics26), 0, upgradeData, transferOpId, bytes32(0));
        assertEq(ics26.calls(), 0, "router upgrade must not run before the transfer upgrade");

        // Correct order succeeds.
        timelock.execute(address(ics20), 0, upgradeData, bytes32(0), bytes32(0));
        assertEq(ics20.calls(), 1);
        timelock.execute(address(ics26), 0, upgradeData, transferOpId, bytes32(0));
        assertEq(ics26.calls(), 1);
    }

    /// @dev Contrast: with a zero predecessor (the pre-fix behavior) the timelock does NOT enforce ordering, so
    /// the router upgrade can execute first. This is the failure the predecessor wiring prevents.
    function test_withoutPredecessorOrderingIsNotEnforced() public {
        timelock.schedule(address(ics20), 0, upgradeData, bytes32(0), bytes32(0), DELAY);
        // Distinct salt so the two zero-predecessor operations have different ids.
        timelock.schedule(address(ics26), 0, upgradeData, bytes32(0), bytes32(uint256(1)), DELAY);

        vm.warp(block.timestamp + DELAY + 1);

        timelock.execute(address(ics26), 0, upgradeData, bytes32(0), bytes32(uint256(1)));
        assertEq(ics26.calls(), 1, "without a predecessor the router upgrade is not ordered after the transfer");
    }
}
