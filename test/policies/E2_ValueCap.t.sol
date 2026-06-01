// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseTest} from "../BaseTest.sol";
import {E2_ValueCap, E2_ValueCap_Harness} from "../../src/policies/E2_ValueCap.sol";

/// @notice C.4 — E2 native-value cap. Correctness only; gas matrix is Section D.
contract E2_ValueCap_Test is BaseTest {
    E2_ValueCap_Harness internal harness;

    uint256 internal constant CAP = 1 ether;

    function setUp() public override {
        super.setUp();
        harness = new E2_ValueCap_Harness();
    }

    /// pass: amount strictly below the cap.
    function test_Pass_BelowCap() public view {
        harness.checkExternal(CAP - 1, CAP);
    }

    /// pass: amount exactly at the cap (boundary is inclusive: `amount > cap` reverts).
    function test_Pass_AtCap() public view {
        harness.checkExternal(CAP, CAP);
    }

    /// revert: one wei over the cap.
    function test_Revert_AboveCap() public {
        vm.expectRevert(E2_ValueCap.ExceedsValueCap.selector);
        harness.checkExternal(CAP + 1, CAP);
    }
}
