// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseTest} from "./BaseTest.sol";
import {Escrow} from "../src/Escrow.sol";

/// @notice Section B unit tests. Each test maps to one row of the B.3 checklist.
/// @dev A realistic base timestamp is set in setUp so `block.timestamp / 1 days`
///      is a normal-sized day index, not the degenerate 0 you get at the default
///      Foundry timestamp of 1.
contract EscrowBasicTest is BaseTest {
    Escrow internal escrow;

    // 2023-11-14 ~ a stable, realistic base time.
    uint256 internal constant T0 = 1_700_000_000;

    function setUp() public override {
        super.setUp();
        vm.warp(T0);
        vm.prank(USER);
        escrow = new Escrow();
        assertEq(escrow.user(), USER, "deployer should be USER");
    }

    // --- helpers ---------------------------------------------------------------

    function _defaultPolicy() internal view returns (Escrow.AgentPolicy memory) {
        return Escrow.AgentPolicy({
            maxPerRequest: 1 ether,
            maxPerDay: 2 ether,
            validUntil: block.timestamp + 30 days,
            active: true
        });
    }

    function _fundAndSetPolicy() internal {
        vm.prank(USER);
        escrow.deposit{value: 10 ether}(AGENT);
        vm.prank(USER);
        escrow.setPolicy(AGENT, _defaultPolicy());
    }

    // --- happy path ------------------------------------------------------------

    function test_HappyPath_SettleWithinCap() public {
        _fundAndSetPolicy();
        uint256 provBefore = PROVIDER.balance;

        escrow.settle(AGENT, payable(PROVIDER), 0.5 ether);

        assertEq(PROVIDER.balance, provBefore + 0.5 ether, "provider paid");
        assertEq(escrow.getBalance(AGENT), 9.5 ether, "agent balance debited");
        (, uint128 spent) = escrow.dailyState(AGENT);
        assertEq(spent, 0.5 ether, "daily spent tracked");
    }

    // --- access control: setPolicy is user-only --------------------------------

    function test_SetPolicy_RevertWhen_NotUser() public {
        vm.prank(AGENT);
        vm.expectRevert(Escrow.NotUser.selector);
        escrow.setPolicy(AGENT, _defaultPolicy());
    }

    // --- E2: per-request cap ---------------------------------------------------

    function test_Settle_RevertWhen_ExceedsPerRequest() public {
        _fundAndSetPolicy();
        vm.expectRevert(Escrow.ExceedsPerRequest.selector);
        escrow.settle(AGENT, payable(PROVIDER), 1 ether + 1); // > maxPerRequest
    }

    // --- E3: cumulative daily cap ----------------------------------------------

    function test_Settle_RevertWhen_ExceedsDailyCap() public {
        _fundAndSetPolicy();
        escrow.settle(AGENT, payable(PROVIDER), 1 ether); // cum = 1.0
        escrow.settle(AGENT, payable(PROVIDER), 1 ether); // cum = 2.0 == cap, ok
        vm.expectRevert(Escrow.ExceedsDailyCap.selector);
        escrow.settle(AGENT, payable(PROVIDER), 0.5 ether); // cum would be 2.5 > 2
    }

    // --- E3: expiry ------------------------------------------------------------

    function test_Settle_RevertWhen_Expired() public {
        _fundAndSetPolicy();
        vm.warp(block.timestamp + 31 days); // past validUntil (= T0 + 30 days)
        vm.expectRevert(Escrow.PolicyExpired.selector);
        escrow.settle(AGENT, payable(PROVIDER), 0.5 ether);
    }

    // --- E3: revocation --------------------------------------------------------

    function test_Settle_RevertWhen_Revoked() public {
        _fundAndSetPolicy();
        vm.prank(USER);
        escrow.revokePolicy(AGENT);
        vm.expectRevert(Escrow.PolicyInactive.selector);
        escrow.settle(AGENT, payable(PROVIDER), 0.5 ether);
    }

    // --- balance check ---------------------------------------------------------

    function test_Settle_RevertWhen_InsufficientBalance() public {
        // Fund less than the (within-cap) amount we will settle.
        vm.prank(USER);
        escrow.deposit{value: 0.1 ether}(AGENT);
        vm.prank(USER);
        escrow.setPolicy(AGENT, _defaultPolicy());

        vm.expectRevert(Escrow.InsufficientBalance.selector);
        escrow.settle(AGENT, payable(PROVIDER), 0.5 ether); // within caps, but balance 0.1
    }

    // --- E3: daily counter resets across a day boundary (vm.warp) --------------

    function test_DailyCounter_ResetsOnNewDay() public {
        _fundAndSetPolicy();

        // Day 1: spend up to the cap.
        escrow.settle(AGENT, payable(PROVIDER), 1 ether);
        escrow.settle(AGENT, payable(PROVIDER), 1 ether); // cum = 2.0 == cap
        (uint128 day1Start, uint128 day1Spent) = escrow.dailyState(AGENT);
        assertEq(day1Spent, 2 ether, "day1 spent at cap");

        // Same day: one more wei over the cap must revert.
        vm.expectRevert(Escrow.ExceedsDailyCap.selector);
        escrow.settle(AGENT, payable(PROVIDER), 0.5 ether);

        // Cross a day boundary -> counter resets.
        vm.warp(block.timestamp + 1 days);
        escrow.settle(AGENT, payable(PROVIDER), 1 ether); // succeeds again

        (uint128 day2Start, uint128 day2Spent) = escrow.dailyState(AGENT);
        assertEq(day2Spent, 1 ether, "day2 spent reset then +1");
        assertGt(day2Start, day1Start, "dayStart advanced");
    }
}
