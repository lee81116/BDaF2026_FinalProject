// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseTest} from "../BaseTest.sol";
import {E3_Revocation, E3_Revocation_Harness} from "../../src/policies/E3_Revocation.sol";

/// @notice C.5 — E3 revocation. Correctness only; cold/warm gas is Section D.
contract E3_Revocation_Test is BaseTest {
    E3_Revocation_Harness internal harness;

    function setUp() public override {
        super.setUp();
        harness = new E3_Revocation_Harness();
    }

    /// pass: an active policy passes.
    function test_Pass_WhenActive() public {
        harness.setActive(true);
        harness.checkExternal();
    }

    /// revert: a revoked policy is rejected.
    function test_Revert_AfterRevoked() public {
        harness.setActive(true);
        harness.setActive(false); // revoke
        vm.expectRevert(E3_Revocation.PolicyInactive.selector);
        harness.checkExternal();
    }

    /// revert: the default (never-activated) state is inactive — fail closed.
    function test_Revert_WhenDefaultInactive() public {
        vm.expectRevert(E3_Revocation.PolicyInactive.selector);
        harness.checkExternal();
    }
}
