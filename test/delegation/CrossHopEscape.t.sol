// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseTest} from "../BaseTest.sol";
import {TwoHopDelegation} from "../../src/delegation/TwoHopDelegation.sol";

/// @notice Section G — the cross-hop r_scope "break".
///
/// SCENARIO: User → A (cap 2 ether) → B (cap 2 ether).
///   - A spends 1.5 ether under its own permission (≤ 2: locally fine).
///   - B spends 2.0 ether under its permission   (≤ 2: locally fine).
///   - Total leaving the single pool: 3.5 ether — but the User only ever
///     authorized A's subtree for 2 ether.
///
/// No local cap is ever violated; the escape lives in the GAP between local
/// caps and the absent global accounting. The assertion is on the TOTAL drained
/// (G.4 pitfall 1), not on any single permission's local state.
contract CrossHopEscapeTest is BaseTest {
    TwoHopDelegation internal del;

    address internal constant AGENT_A = address(0xA1);
    address internal constant AGENT_B = address(0xB2);

    uint256 internal constant ROOT_CAP = 2 ether; // what the User authorized A's subtree

    function setUp() public override {
        super.setUp();
        vm.label(AGENT_A, "AgentA");
        vm.label(AGENT_B, "AgentB");

        del = new TwoHopDelegation();
        // Single funding pool: the User funds the contract once.
        (bool ok,) = address(del).call{value: 10 ether}("");
        require(ok, "fund pool");
    }

    function test_LocalOnly_AllowsEscape() public {
        // Hop 1: User grants A a 2-ether budget.
        vm.prank(USER);
        bytes32 permA = del.grant(AGENT_A, 1 ether, ROOT_CAP);

        // Hop 2: A re-delegates a FRESH 2-ether budget to B (own slot).
        vm.prank(AGENT_A);
        bytes32 permB = del.grant(AGENT_B, 1 ether, ROOT_CAP);

        // Phase 1: A itself spends 1.5 ether through permA (≤ 2: locally legal).
        vm.startPrank(AGENT_A);
        del.executeLocalOnly(permA, payable(PROVIDER), 0.8 ether);
        del.executeLocalOnly(permA, payable(PROVIDER), 0.7 ether);
        vm.stopPrank();

        // Phase 2: B spends 2.0 ether through permB (≤ 2: locally legal).
        vm.startPrank(AGENT_B);
        del.executeLocalOnly(permB, payable(PROVIDER), 1 ether);
        del.executeLocalOnly(permB, payable(PROVIDER), 1 ether);
        vm.stopPrank();

        // --- Local invariants: every permission stayed within its own cap -----
        assertEq(del.spentOf(permA), 1.5 ether, "A within its 2-ether cap");
        assertEq(del.spentOf(permB), 2.0 ether, "B within its 2-ether cap");
        assertLe(del.spentOf(permA), ROOT_CAP, "A local cap not violated");
        assertLe(del.spentOf(permB), ROOT_CAP, "B local cap not violated");

        // --- Global truth: the escape -----------------------------------------
        // The single pool paid out 3.5 ether to the provider, even though the
        // User authorized A's subtree for only 2 ether.
        uint256 totalDrained = PROVIDER.balance;
        assertEq(totalDrained, 3.5 ether, "total drained from the single pool");
        assertGt(totalDrained, ROOT_CAP, "ESCAPE: drained > user-authorized budget");

        emit log_named_decimal_uint("root cap (authorized)", ROOT_CAP, 18);
        emit log_named_decimal_uint("A spent (local)", del.spentOf(permA), 18);
        emit log_named_decimal_uint("B spent (local)", del.spentOf(permB), 18);
        emit log_named_decimal_uint("TOTAL drained (global)", totalDrained, 18);
        emit log_named_decimal_uint("overspend", totalDrained - ROOT_CAP, 18);
    }

    /// Control: a single hop alone CANNOT exceed its cap — proving the escape is
    /// compositional (it needs the second hop), not just a missing per-permission
    /// check. A's 3rd spend that would breach its own cap reverts.
    function test_SingleHop_CannotExceedOwnCap() public {
        vm.prank(USER);
        bytes32 permA = del.grant(AGENT_A, 1 ether, ROOT_CAP);

        vm.startPrank(AGENT_A);
        del.executeLocalOnly(permA, payable(PROVIDER), 1 ether);
        del.executeLocalOnly(permA, payable(PROVIDER), 1 ether); // spent == cap
        vm.expectRevert(bytes("cumulative cap"));
        del.executeLocalOnly(permA, payable(PROVIDER), 1); // 1 wei over → reverts
        vm.stopPrank();
    }
}
