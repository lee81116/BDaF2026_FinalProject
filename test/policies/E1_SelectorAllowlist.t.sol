// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseTest} from "../BaseTest.sol";
import {
    E1_SelectorAllowlist,
    E1_SelectorAllowlist_Harness
} from "../../src/policies/E1_SelectorAllowlist.sol";

/// @notice C.3 — E1 selector allowlist. Correctness only; gas matrix is Section D.
contract E1_SelectorAllowlist_Test is BaseTest {
    E1_SelectorAllowlist_Harness internal harness;

    // A representative paid-call selector: pay(bytes32).
    bytes4 internal constant PAY_SEL = bytes4(keccak256("pay(bytes32)"));
    bytes4 internal constant TRANSFER_SEL = bytes4(keccak256("transfer(address,uint256)"));

    function setUp() public override {
        super.setUp();
        harness = new E1_SelectorAllowlist_Harness();
    }

    function test_Pass_WhenAllowed() public {
        harness.setAllowed(PAY_SEL, true);
        harness.checkExternal(PAY_SEL); // must not revert
        assertTrue(harness.allowlist(PAY_SEL), "selector is allowed");
    }

    function test_Revert_WhenNotAllowed() public {
        // TRANSFER_SEL was never allowed.
        vm.expectRevert(E1_SelectorAllowlist.SelectorNotAllowed.selector);
        harness.checkExternal(TRANSFER_SEL);
    }

    function test_Revert_AfterDisabled() public {
        harness.setAllowed(PAY_SEL, true);
        harness.setAllowed(PAY_SEL, false);
        vm.expectRevert(E1_SelectorAllowlist.SelectorNotAllowed.selector);
        harness.checkExternal(PAY_SEL);
    }
}
