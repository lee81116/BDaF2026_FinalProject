// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {E2_ValueCap} from "./policies/E2_ValueCap.sol";
import {E3_Expiry} from "./policies/E3_Expiry.sol";
import {E3_Revocation} from "./policies/E3_Revocation.sol";
import {E3_CumulativeDailyCap} from "./policies/E3_CumulativeDailyCap.sol";

/// @title Escrow
/// @notice Minimum per-agent payment escrow used as the substrate for
///         enforceability/gas measurements. ETH-only for now; an ERC-20 variant
///         is added later for E2 token-amount tests (see plan B.1).
/// @dev Design notes (B.1):
///      - `AgentPolicy` is per-agent, not global: `mapping(address => AgentPolicy)`.
///      - `E3_CumulativeDailyCap.DailyState` packs (dayStart, spent) into one
///        slot; `advance()` resets `spent` on a new day and bumps `dayStart`.
///      - `settle` is intentionally NOT caller-restricted: the contract decides
///        purely on the on-chain settlement fields (agent, to, amount). This is
///        deliberate — it is the property the r_conf demonstration (Section F)
///        relies on.
contract Escrow {
    struct AgentPolicy {
        uint256 maxPerRequest;
        uint256 maxPerDay;
        uint256 validUntil;
        bool active;
    }

    address public immutable user;
    mapping(address => AgentPolicy) public policies;
    mapping(address => E3_CumulativeDailyCap.DailyState) public dailyState;
    mapping(address => uint256) public balances;

    // Policy-check reverts now originate from the policy libraries (E2_ValueCap,
    // E3_Expiry, E3_Revocation, E3_CumulativeDailyCap) — see settle/batchDeduct.
    // Escrow retains only the errors for the checks it still owns directly.
    error InsufficientBalance();
    error NotUser();

    constructor() {
        user = msg.sender;
    }

    modifier onlyUser() {
        if (msg.sender != user) revert NotUser();
        _;
    }

    function deposit(address agent) external payable {
        balances[agent] += msg.value;
    }

    /// @dev User-only withdrawal of unspent funds for a given agent.
    ///      NOTE: the plan's bare skeleton was `withdraw(uint256)`; the `agent`
    ///      parameter is added deliberately because balances are tracked per-agent
    ///      (B.1) — without it the function cannot know which sub-balance to debit.
    ///      Checks-effects-interactions: balance is debited before the transfer.
    function withdraw(address agent, uint256 amount) external onlyUser {
        if (balances[agent] < amount) revert InsufficientBalance();
        balances[agent] -= amount;
        (bool ok,) = payable(user).call{value: amount}("");
        require(ok, "transfer failed");
    }

    function setPolicy(address agent, AgentPolicy calldata p) external onlyUser {
        policies[agent] = p;
    }

    function revokePolicy(address agent) external onlyUser {
        policies[agent].active = false;
    }

    /// @dev Single-payment settlement. Used for per-check gas measurement.
    ///      Policy checks are delegated to the Section C libraries; their
    ///      `internal` functions inline here, so the per-check opcodes (and gas)
    ///      match the isolated harness measurements (plan C.6).
    function settle(address agent, address payable to, uint256 amount) external {
        AgentPolicy memory p = policies[agent];
        E3_Revocation.check(p.active);
        E3_Expiry.check(p.validUntil);
        E2_ValueCap.check(amount, p.maxPerRequest);

        E3_CumulativeDailyCap.DailyState memory d = dailyState[agent];
        uint256 today = block.timestamp / 1 days;
        // advance() resets across a day boundary, enforces the daily cap, and
        // returns state with `amount` accumulated (in memory only).
        d = E3_CumulativeDailyCap.advance(d, amount, p.maxPerDay, today);

        if (balances[agent] < amount) revert InsufficientBalance();

        dailyState[agent] = d;
        balances[agent] -= amount;

        (bool ok,) = to.call{value: amount}("");
        require(ok, "transfer failed");
    }

    /// @dev Batched settlement. Used for batch-curve measurement (Section E).
    ///      Invariant checks (revocation, expiry) are hoisted out of the loop;
    ///      the per-call value cap runs inside it. The cumulative cap is enforced
    ///      once on the batch total via advance().
    function batchDeduct(
        address agent,
        address payable[] calldata recipients,
        uint256[] calldata amounts
    ) external {
        require(recipients.length == amounts.length, "length mismatch");
        AgentPolicy memory p = policies[agent];

        E3_Revocation.check(p.active);
        E3_Expiry.check(p.validUntil);

        uint256 totalAmount;
        for (uint256 i = 0; i < amounts.length; ++i) {
            E2_ValueCap.check(amounts[i], p.maxPerRequest);
            totalAmount += amounts[i];
        }

        E3_CumulativeDailyCap.DailyState memory d = dailyState[agent];
        uint256 today = block.timestamp / 1 days;
        d = E3_CumulativeDailyCap.advance(d, totalAmount, p.maxPerDay, today);

        if (balances[agent] < totalAmount) revert InsufficientBalance();

        dailyState[agent] = d;
        balances[agent] -= totalAmount;

        for (uint256 i = 0; i < recipients.length; ++i) {
            (bool ok,) = recipients[i].call{value: amounts[i]}("");
            require(ok, "transfer failed");
        }
    }

    function getBalance(address agent) external view returns (uint256) {
        return balances[agent];
    }

    function getPolicy(address agent) external view returns (AgentPolicy memory) {
        return policies[agent];
    }
}
