// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseTest} from "../BaseTest.sol";
import {
    E2_TokenAmountCap,
    E2_TokenAmountCap_Harness
} from "../../src/policies/E2_TokenAmountCap.sol";

/// @notice C.4 — E2 ERC-20 token-amount cap. Correctness only; gas matrix is Section D.
contract E2_TokenAmountCap_Test is BaseTest {
    E2_TokenAmountCap_Harness internal harness;

    // 1000 tokens at 18 decimals.
    uint256 internal constant CAP = 1000e18;

    function setUp() public override {
        super.setUp();
        harness = new E2_TokenAmountCap_Harness();
    }

    function test_Pass_BelowCap() public view {
        harness.checkExternal(CAP - 1, CAP);
    }

    function test_Pass_AtCap() public view {
        harness.checkExternal(CAP, CAP);
    }

    function test_Revert_AboveCap() public {
        vm.expectRevert(E2_TokenAmountCap.ExceedsTokenAmountCap.selector);
        harness.checkExternal(CAP + 1, CAP);
    }
}
