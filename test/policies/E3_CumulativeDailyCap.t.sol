// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseTest} from "../BaseTest.sol";
import {
    E3_CumulativeDailyCap,
    E3_CumulativeDailyCap_Harness
} from "../../src/policies/E3_CumulativeDailyCap.sol";

/// @notice C.5 — E3 cumulative daily cap, the most stateful check.
///         Correctness only; cold/warm read-only vs read+write gas is Section D.
contract E3_CumulativeDailyCap_Test is BaseTest {
    E3_CumulativeDailyCap_Harness internal harness;

    uint256 internal constant T0 = 1_700_000_000;
    uint256 internal constant CAP = 2 ether;

    function setUp() public override {
        super.setUp();
        vm.warp(T0);
        harness = new E3_CumulativeDailyCap_Harness();
    }

    // --- read-only variant ----------------------------------------------------

    /// pass + no-persist: a within-cap read-only check succeeds and leaves
    /// storage untouched (proves the variant truly performs no SSTORE).
    function test_ReadOnly_Pass_DoesNotPersist() public {
        harness.checkReadOnly(1 ether, CAP);
        (uint128 dayStart, uint128 spent) = harness.dailyState();
        assertEq(dayStart, 0, "read-only must not write dayStart");
        assertEq(spent, 0, "read-only must not write spent");
    }

    /// revert: read-only still enforces the cap.
    function test_ReadOnly_Revert_AboveCap() public {
        vm.expectRevert(E3_CumulativeDailyCap.ExceedsDailyCap.selector);
        harness.checkReadOnly(CAP + 1, CAP);
    }

    // --- read+write variant ---------------------------------------------------

    /// pass + persist: cumulative spend accumulates across calls within a day.
    function test_ReadWrite_Pass_Accumulates() public {
        uint256 today = T0 / 1 days;

        harness.checkReadWrite(1 ether, CAP); // 0 -> 1.0
        (uint128 d1, uint128 s1) = harness.dailyState();
        assertEq(d1, uint128(today), "dayStart set to today");
        assertEq(s1, 1 ether, "spent = 1.0 after first");

        harness.checkReadWrite(1 ether, CAP); // 1.0 -> 2.0 == cap, ok
        (, uint128 s2) = harness.dailyState();
        assertEq(s2, 2 ether, "spent = 2.0 at cap");
    }

    /// revert: cumulative spend over the cap is rejected (and the prior total stands).
    function test_ReadWrite_Revert_CumulativeOverCap() public {
        harness.checkReadWrite(2 ether, CAP); // at cap
        vm.expectRevert(E3_CumulativeDailyCap.ExceedsDailyCap.selector);
        harness.checkReadWrite(1, CAP); // 2.0 + 1 wei > cap
    }

    /// state: crossing a day boundary resets the counter (vm.warp).
    function test_ReadWrite_ResetsOnNewDay() public {
        uint256 day1 = T0 / 1 days;
        harness.checkReadWrite(2 ether, CAP); // fill day 1 to cap
        (uint128 ds1, uint128 sp1) = harness.dailyState();
        assertEq(sp1, 2 ether, "day1 at cap");
        assertEq(ds1, uint128(day1), "day1 index");

        vm.warp(T0 + 1 days); // cross boundary
        harness.checkReadWrite(1 ether, CAP); // resets then +1.0
        (uint128 ds2, uint128 sp2) = harness.dailyState();
        assertEq(sp2, 1 ether, "day2 reset then +1.0");
        assertGt(ds2, ds1, "dayStart advanced");
    }
}
