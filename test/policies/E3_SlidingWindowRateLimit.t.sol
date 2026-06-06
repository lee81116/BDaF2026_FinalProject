// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseTest} from "../BaseTest.sol";
import {
    E3_SlidingWindowRateLimit,
    E3_SlidingWindowRateLimit_Harness
} from "../../src/policies/E3_SlidingWindowRateLimit.sol";

/// @notice M1 behavioral spec — E3_SlidingWindowRateLimit (count-based two-bucket
///         approximation). Correctness only; gas is the *_Gas test.
///
/// Window length W = 100s throughout. `weighted = curr + (prev*(W-elapsed))/W`,
/// pass iff `weighted + 1 <= maxPerWindow`. All edge cases from the handoff M1
/// spec are pinned here. These tests are written RED (the library reverts
/// "unimplemented") before any implementation exists.
contract E3_SlidingWindowRateLimit_Test is BaseTest {
    E3_SlidingWindowRateLimit_Harness internal h;

    uint256 internal constant W = 100;

    function setUp() public override {
        super.setUp();
        h = new E3_SlidingWindowRateLimit_Harness();
    }

    // --- maxPerWindow = 0 always reverts (even on fresh state) ----------------

    function test_MaxZero_AlwaysReverts() public {
        vm.warp(150); // window [100,200), elapsed 50
        vm.expectRevert(
            abi.encodeWithSelector(E3_SlidingWindowRateLimit.RateLimitExceeded.selector, 1, 0)
        );
        h.checkReadWrite(W, 0);
    }

    // --- maxPerWindow = 1 admits exactly one call per fresh window ------------

    function test_MaxOne_AdmitsExactlyOnePerFreshWindow() public {
        vm.warp(150); // window [100,200)
        h.checkReadWrite(W, 1); // weighted 0, attempted 1 <= 1: pass
        vm.expectRevert(
            abi.encodeWithSelector(E3_SlidingWindowRateLimit.RateLimitExceeded.selector, 2, 1)
        );
        h.checkReadWrite(W, 1); // weighted 1, attempted 2 > 1: revert

        // Next window, far enough in that prev's single request weighs 0.
        vm.warp(250); // window [200,300), elapsed 50: weighted = (1*50)/100 = 0
        h.checkReadWrite(W, 1); // pass again — one per fresh window
        (, uint104 prev, uint104 curr) = h.state();
        assertEq(curr, 1, "curr reset to 1 in new window");
        assertEq(prev, 1, "prev holds the previous window's single call");
    }

    // --- adjacent window, elapsed = 0: prev counts at FULL weight -------------

    function test_AdjacentWindow_Elapsed0_PrevFullWeight_Reverts() public {
        vm.warp(100); // window [100,200), elapsed 0
        h.checkReadWrite(W, 2); // curr 1
        h.checkReadWrite(W, 2); // curr 2 (== cap)

        vm.warp(200); // adjacent window [200,300), elapsed 0
        // prev = 2, weighted = 0 + (2*(100-0))/100 = 2, attempted 3 > 2: revert
        vm.expectRevert(
            abi.encodeWithSelector(E3_SlidingWindowRateLimit.RateLimitExceeded.selector, 3, 2)
        );
        h.checkReadWrite(W, 2);
    }

    // --- adjacent window, elapsed = W-1: prev contributes 0 (prev < W) --------

    function test_AdjacentWindow_ElapsedMax_PrevZeroWeight_Passes() public {
        vm.warp(100);
        h.checkReadWrite(W, 2); // curr 1
        h.checkReadWrite(W, 2); // curr 2

        vm.warp(299); // adjacent window [200,300), elapsed 99
        // weighted = 0 + (2*(100-99))/100 = (2*1)/100 = 0, attempted 1 <= 2: pass
        h.checkReadWrite(W, 2);
        (uint48 ws, uint104 prev, uint104 curr) = h.state();
        assertEq(ws, 200, "windowStart advanced to current window");
        assertEq(prev, 2, "prev carried the full previous count");
        assertEq(curr, 1, "curr started fresh and took this call");
    }

    // --- gap of >= 2 windows fully resets both buckets ------------------------

    function test_GapTwoWindows_ResetsBoth() public {
        vm.warp(100);
        h.checkReadWrite(W, 2); // curr 1
        h.checkReadWrite(W, 2); // curr 2

        vm.warp(350); // window [300,400): gap of 2 windows from [100,200)
        h.checkReadWrite(W, 2); // both buckets reset, then +1
        (uint48 ws, uint104 prev, uint104 curr) = h.state();
        assertEq(ws, 300, "windowStart jumped to the current window");
        assertEq(prev, 0, "prev reset across the gap");
        assertEq(curr, 1, "curr reset then took this call");
    }

    // --- off-by-one: exact-cap call passes, the next reverts ------------------

    function test_OffByOne_ExactCapPassesThenReverts() public {
        vm.warp(150); // single fresh window [100,200)
        h.checkReadWrite(W, 3); // weighted 0, attempted 1: pass (curr 1)
        h.checkReadWrite(W, 3); // weighted 1, attempted 2: pass (curr 2)
        h.checkReadWrite(W, 3); // weighted 2, attempted 3 == cap: pass (curr 3)
        (,, uint104 curr) = h.state();
        assertEq(curr, 3, "three admitted at exactly the cap");

        vm.expectRevert(
            abi.encodeWithSelector(E3_SlidingWindowRateLimit.RateLimitExceeded.selector, 4, 3)
        );
        h.checkReadWrite(W, 3); // weighted 3, attempted 4 > 3: revert
    }

    // --- read-only variant performs no SSTORE ---------------------------------

    function test_ReadOnly_Pass_DoesNotPersist() public {
        vm.warp(150);
        h.checkReadOnly(W, 5);
        (uint48 ws, uint104 prev, uint104 curr) = h.state();
        assertEq(ws, 0, "read-only must not write windowStart");
        assertEq(prev, 0, "read-only must not write prevCount");
        assertEq(curr, 0, "read-only must not write currCount");
    }

    function test_ReadOnly_Revert_OverCap() public {
        vm.warp(150);
        h.setState(uint48(100), 0, uint104(5)); // curr already at 5
        vm.expectRevert(
            abi.encodeWithSelector(E3_SlidingWindowRateLimit.RateLimitExceeded.selector, 6, 5)
        );
        h.checkReadOnly(W, 5); // weighted 5, attempted 6 > 5: revert
    }

    // --- read+write accumulates within a window -------------------------------

    function test_ReadWrite_SameWindow_Accumulates() public {
        vm.warp(150);
        h.checkReadWrite(W, 5);
        h.checkReadWrite(W, 5);
        (uint48 ws, uint104 prev, uint104 curr) = h.state();
        assertEq(ws, 100, "windowStart set to current window");
        assertEq(prev, 0, "no previous window yet");
        assertEq(curr, 2, "two calls accumulated in the current window");
    }
}
