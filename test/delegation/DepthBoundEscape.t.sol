// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseTest} from "../BaseTest.sol";
import {DepthBoundedDelegation} from "../../src/delegation/DepthBoundedDelegation.sol";
import {E3_DelegationDepth} from "../../src/policies/E3_DelegationDepth.sol";

/// @notice M3 — depth bounds constrain chain LENGTH, not BUDGET.
///
/// Two findings, mirroring Section G's `CrossHopEscape.t.sol`:
///   1. The depth bound is real: granting a 4th-generation permission (depth 3,
///      User→A→B→C) reverts `DepthExceeded` with MAX_DEPTH = 2.
///   2. The escape persists at legal depth: the exact Section G scenario
///      (User→A→B, both within MAX_DEPTH) still drains 3.5 ether from a 2-ether
///      root authorization, because each permission still meters its own budget
///      in its own slot. The depth bound did nothing to the budget escape; the
///      missing mechanism is root-anchored accounting, unchanged.
contract DepthBoundEscapeTest is BaseTest {
    DepthBoundedDelegation internal del;

    address internal constant AGENT_A = address(0xA1);
    address internal constant AGENT_B = address(0xB2);
    address internal constant AGENT_C = address(0xC3);

    uint256 internal constant ROOT_CAP = 2 ether; // what the User authorized A's subtree

    function setUp() public override {
        super.setUp();
        vm.label(AGENT_A, "AgentA");
        vm.label(AGENT_B, "AgentB");
        vm.label(AGENT_C, "AgentC");

        del = new DepthBoundedDelegation();
        (bool ok,) = address(del).call{value: 10 ether}("");
        require(ok, "fund pool");
    }

    /// 1 — The depth bound is enforced: a chain longer than MAX_DEPTH is rejected
    ///     at grant time.
    function test_DepthBound_Enforced() public {
        vm.prank(USER);
        bytes32 permA = del.grant(bytes32(0), AGENT_A, 1 ether, ROOT_CAP); // depth 1

        vm.prank(AGENT_A);
        bytes32 permB = del.grant(permA, AGENT_B, 1 ether, ROOT_CAP); // depth 2 == MAX_DEPTH

        assertEq(del.depthOf(permA), 1, "root grant is depth 1");
        assertEq(del.depthOf(permB), 2, "second hop is depth 2");

        // Third hop would be depth 3 > MAX_DEPTH (2): rejected.
        // Fetch MAX_DEPTH() BEFORE the prank: a real contract call inside the
        // expectRevert args would otherwise consume vm.prank, sending the grant
        // from the test contract and tripping "not parent holder" first.
        uint256 maxDepth = del.MAX_DEPTH();
        vm.prank(AGENT_B);
        vm.expectRevert(
            abi.encodeWithSelector(E3_DelegationDepth.DepthExceeded.selector, 3, maxDepth)
        );
        del.grant(permB, AGENT_C, 1 ether, ROOT_CAP);
    }

    /// 2 — At legal depth, the Section G escape still works: the bound on chain
    ///     length does not bound the budget.
    function test_DepthLegal_EscapeStillPossible() public {
        // Hop 1: User grants A a 2-ether budget (depth 1).
        vm.prank(USER);
        bytes32 permA = del.grant(bytes32(0), AGENT_A, 1 ether, ROOT_CAP);

        // Hop 2: A re-delegates a FRESH 2-ether budget to B (depth 2 <= MAX_DEPTH).
        vm.prank(AGENT_A);
        bytes32 permB = del.grant(permA, AGENT_B, 1 ether, ROOT_CAP);

        assertLe(del.depthOf(permB), del.MAX_DEPTH(), "B is within the depth bound");

        // Phase 1: A spends 1.5 ether through permA (<= 2: locally legal).
        vm.startPrank(AGENT_A);
        del.executeLocalOnly(permA, payable(PROVIDER), 0.8 ether);
        del.executeLocalOnly(permA, payable(PROVIDER), 0.7 ether);
        vm.stopPrank();

        // Phase 2: B spends 2.0 ether through permB (<= 2: locally legal).
        vm.startPrank(AGENT_B);
        del.executeLocalOnly(permB, payable(PROVIDER), 1 ether);
        del.executeLocalOnly(permB, payable(PROVIDER), 1 ether);
        vm.stopPrank();

        // --- Local invariants: every permission stayed within its own cap -----
        assertEq(del.spentOf(permA), 1.5 ether, "A within its 2-ether cap");
        assertEq(del.spentOf(permB), 2.0 ether, "B within its 2-ether cap");
        assertLe(del.spentOf(permA), ROOT_CAP, "A local cap not violated");
        assertLe(del.spentOf(permB), ROOT_CAP, "B local cap not violated");

        // --- Global truth: the escape survives the depth bound ----------------
        uint256 totalDrained = PROVIDER.balance;
        assertEq(totalDrained, 3.5 ether, "total drained from the single pool");
        assertGt(totalDrained, ROOT_CAP, "ESCAPE: drained > user-authorized budget, at legal depth");

        emit log_named_decimal_uint("root cap (authorized)", ROOT_CAP, 18);
        emit log_named_decimal_uint("A spent (local)", del.spentOf(permA), 18);
        emit log_named_decimal_uint("B spent (local)", del.spentOf(permB), 18);
        emit log_named_decimal_uint("TOTAL drained (global)", totalDrained, 18);
        emit log_named_decimal_uint("overspend", totalDrained - ROOT_CAP, 18);
    }
}
