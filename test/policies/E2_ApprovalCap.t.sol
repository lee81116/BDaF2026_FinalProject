// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseTest} from "../BaseTest.sol";
import {E2_ApprovalCap, E2_ApprovalCap_Harness} from "../../src/policies/E2_ApprovalCap.sol";

/// @notice C.4 — E2 approval-allowance cap. Correctness only; gas matrix is Section D.
contract E2_ApprovalCap_Test is BaseTest {
    E2_ApprovalCap_Harness internal harness;

    uint256 internal constant CAP = 500e18;

    function setUp() public override {
        super.setUp();
        harness = new E2_ApprovalCap_Harness();
    }

    function test_Pass_BelowCap() public view {
        harness.checkExternal(CAP - 1, CAP);
    }

    function test_Pass_AtCap() public view {
        harness.checkExternal(CAP, CAP);
    }

    function test_Revert_AboveCap() public {
        vm.expectRevert(E2_ApprovalCap.ExceedsApprovalCap.selector);
        harness.checkExternal(CAP + 1, CAP);
    }
}
