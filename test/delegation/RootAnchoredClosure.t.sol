// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseTest} from "../BaseTest.sol";
import {RootAnchoredDelegation} from "../../src/delegation/RootAnchoredDelegation.sol";

/// @notice Section G′ — the cross-hop closure, mirrored one-to-one against
///         `test/delegation/CrossHopEscape.t.sol` so the contrast is exact.
///
/// SCENARIO (same as Section G): User → A (cap 2 ether) → B (cap 2 ether) from a
/// single pool. Under LOCAL-ONLY state (`TwoHopDelegation`) A's 1.5 + B's 2.0 =
/// 3.5 escaped the 2-ether authorization. Under ROOT-ANCHORED state, B's spend
/// walks up to `User→A` and debits ITS counter, so 1.5 + 2.0 hits the 2-ether
/// root cap and reverts. The escape is closed; the cost is measured in the
/// `_Gas` test. These tests are written RED (the contract reverts
/// "unimplemented") before any closure logic exists.
contract RootAnchoredClosureTest is BaseTest {
    RootAnchoredDelegation internal del;

    address internal constant AGENT_A = address(0xA1);
    address internal constant AGENT_B = address(0xB2);

    uint256 internal constant ROOT_CAP = 2 ether; // what the User authorized A's subtree

    function setUp() public override {
        super.setUp();
        vm.label(AGENT_A, "AgentA");
        vm.label(AGENT_B, "AgentB");

        del = new RootAnchoredDelegation();
        (bool ok,) = address(del).call{value: 10 ether}("");
        require(ok, "fund pool");
    }

    /// 1 — The mirror of `test_LocalOnly_AllowsEscape`, now CLOSED. A spends 1.5
    ///     (legal), B attempts 2.0 through the chain; B's walk debits A's
    ///     root-anchored counter (1.5 + 2.0 > 2) and reverts. Total drained stays
    ///     at A's legal 1.5; the root counter is unchanged after the revert.
    function test_RootAnchored_BlocksEscape() public {
        vm.prank(USER);
        bytes32 permA = del.grant(bytes32(0), AGENT_A, 1 ether, ROOT_CAP); // depth 1

        vm.prank(AGENT_A);
        bytes32 permB = del.grant(permA, AGENT_B, 1 ether, ROOT_CAP); // depth 2, fresh own cap

        assertEq(del.depthOf(permA), 1, "permA is a root grant");
        assertEq(del.depthOf(permB), 2, "permB is one hop deeper");

        // A spends 1.5 ether through permA (<= 2: locally legal, and root == self).
        vm.startPrank(AGENT_A);
        del.executeComposed(permA, payable(PROVIDER), 0.8 ether);
        del.executeComposed(permA, payable(PROVIDER), 0.7 ether);
        vm.stopPrank();

        assertEq(del.spentOf(permA), 1.5 ether, "A's root-anchored counter at 1.5");

        // B attempts 2.0 ether through permB. The walk debits permB (ok, <= 2)
        // then permA (1.5 + 2.0 = 3.5 > 2) → revert: the escape is closed.
        vm.prank(AGENT_B);
        vm.expectRevert(bytes("cumulative cap"));
        del.executeComposed(permB, payable(PROVIDER), 2 ether);

        // After the revert: nothing B did persisted; the root counter is intact.
        assertEq(del.spentOf(permA), 1.5 ether, "root counter unchanged after revert");
        assertEq(del.spentOf(permB), 0, "B's counter rolled back");
        assertEq(PROVIDER.balance, 1.5 ether, "total drained == A's legal 1.5, escape blocked");
    }

    /// 2 — The mirror of MetaMask H5 test 2: one shared root budget, exactly
    ///     enforced. A 1.5 + B 0.5 == the 2-ether root cap (both succeed); one
    ///     more wei from EITHER party reverts.
    function test_RootAnchored_SharedCounter() public {
        vm.prank(USER);
        bytes32 permA = del.grant(bytes32(0), AGENT_A, 1 ether, ROOT_CAP);
        vm.prank(AGENT_A);
        bytes32 permB = del.grant(permA, AGENT_B, 1 ether, ROOT_CAP);

        vm.startPrank(AGENT_A);
        del.executeComposed(permA, payable(PROVIDER), 0.8 ether);
        del.executeComposed(permA, payable(PROVIDER), 0.7 ether); // A at 1.5
        vm.stopPrank();

        vm.prank(AGENT_B);
        del.executeComposed(permB, payable(PROVIDER), 0.5 ether); // root counter now exactly 2.0

        assertEq(del.spentOf(permA), 2 ether, "shared root counter at the cap");
        assertEq(PROVIDER.balance, 2 ether, "exactly the root cap drained");

        // One more wei from A: permA's counter 2.0 + 1 > 2 → revert.
        vm.prank(AGENT_A);
        vm.expectRevert(bytes("cumulative cap"));
        del.executeComposed(permA, payable(PROVIDER), 1);

        // One more wei from B: walk reaches permA (2.0 + 1 > 2) → revert.
        vm.prank(AGENT_B);
        vm.expectRevert(bytes("cumulative cap"));
        del.executeComposed(permB, payable(PROVIDER), 1);

        assertEq(PROVIDER.balance, 2 ether, "no overspend past the shared cap");
    }

    /// 3 — A single (root) hop still meters its own cap and reverts the wei over.
    function test_SingleHop_StillWorks() public {
        vm.prank(USER);
        bytes32 permA = del.grant(bytes32(0), AGENT_A, 1 ether, ROOT_CAP);

        vm.startPrank(AGENT_A);
        del.executeComposed(permA, payable(PROVIDER), 1 ether);
        del.executeComposed(permA, payable(PROVIDER), 1 ether); // spent == cap
        vm.expectRevert(bytes("cumulative cap"));
        del.executeComposed(permA, payable(PROVIDER), 1); // 1 wei over → reverts
        vm.stopPrank();

        assertEq(del.spentOf(permA), 2 ether, "single hop capped at its own cap");
        assertEq(PROVIDER.balance, 2 ether, "exactly the cap drained");
    }
}
