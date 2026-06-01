// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseTest} from "../BaseTest.sol";
import {E3_Expiry, E3_Expiry_Harness} from "../../src/policies/E3_Expiry.sol";

/// @notice C.5 — E3 expiry. Correctness only; cold/warm gas is Section D.
contract E3_Expiry_Test is BaseTest {
    E3_Expiry_Harness internal harness;

    // Realistic base time so block.timestamp comparisons are non-degenerate.
    uint256 internal constant T0 = 1_700_000_000;

    function setUp() public override {
        super.setUp();
        vm.warp(T0);
        harness = new E3_Expiry_Harness();
    }

    /// pass: now is before validUntil.
    function test_Pass_BeforeExpiry() public {
        harness.setValidUntil(T0 + 1 days);
        harness.checkExternal();
    }

    /// pass: now equals validUntil (boundary inclusive: `block.timestamp > validUntil` reverts).
    function test_Pass_AtExpiry() public {
        harness.setValidUntil(T0);
        harness.checkExternal();
    }

    /// revert: now is past validUntil.
    function test_Revert_AfterExpiry() public {
        harness.setValidUntil(T0);
        vm.warp(T0 + 1);
        vm.expectRevert(E3_Expiry.Expired.selector);
        harness.checkExternal();
    }
}
