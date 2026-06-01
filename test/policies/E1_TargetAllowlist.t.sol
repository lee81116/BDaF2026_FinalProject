// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseTest} from "../BaseTest.sol";
import {
    E1_TargetAllowlist,
    E1_TargetAllowlist_Harness
} from "../../src/policies/E1_TargetAllowlist.sol";

/// @notice C.2 — E1 target allowlist. Correctness only; gas matrix is Section D.
contract E1_TargetAllowlist_Test is BaseTest {
    E1_TargetAllowlist_Harness internal harness;

    function setUp() public override {
        super.setUp();
        harness = new E1_TargetAllowlist_Harness();
    }

    /// pass: an allowed target passes the check.
    function test_Pass_WhenAllowed() public {
        harness.setAllowed(PROVIDER, true);
        harness.checkExternal(PROVIDER); // must not revert
        assertTrue(harness.allowlist(PROVIDER), "target is allowed");
    }

    /// revert: a target never added to the allowlist is rejected.
    function test_Revert_WhenNotAllowed() public {
        vm.expectRevert(E1_TargetAllowlist.TargetNotAllowed.selector);
        harness.checkExternal(MALICIOUS);
    }

    /// revert: a target explicitly disabled is rejected (allowlist is a gate, not a log).
    function test_Revert_AfterDisabled() public {
        harness.setAllowed(PROVIDER, true);
        harness.setAllowed(PROVIDER, false);
        vm.expectRevert(E1_TargetAllowlist.TargetNotAllowed.selector);
        harness.checkExternal(PROVIDER);
    }
}
