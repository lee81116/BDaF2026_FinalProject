// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseTest} from "../BaseTest.sol";
import {
    E3_DelegationDepth,
    E3_DelegationDepth_Harness
} from "../../src/policies/E3_DelegationDepth.sol";

/// @notice M2 behavioral spec — E3_DelegationDepth. `check(depth, maxDepth)`
///         reverts `DepthExceeded` iff `depth > maxDepth`, else passes. Written
///         RED before implementation.
contract E3_DelegationDepth_Test is BaseTest {
    E3_DelegationDepth_Harness internal h;

    function setUp() public override {
        super.setUp();
        h = new E3_DelegationDepth_Harness();
    }

    function test_BelowMax_Passes() public view {
        h.checkExternal(1, 2);
    }

    function test_AtMax_Passes() public view {
        h.checkExternal(2, 2); // boundary: depth == maxDepth is allowed
    }

    function test_OverMax_Reverts() public {
        vm.expectRevert(abi.encodeWithSelector(E3_DelegationDepth.DepthExceeded.selector, 3, 2));
        h.checkExternal(3, 2); // depth 3 > maxDepth 2
    }

    function test_OneOverMax_Reverts() public {
        vm.expectRevert(abi.encodeWithSelector(E3_DelegationDepth.DepthExceeded.selector, 1, 0));
        h.checkExternal(1, 0); // maxDepth 0 admits nothing
    }
}
