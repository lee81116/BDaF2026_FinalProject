// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title Escrow
/// @notice Minimum per-agent payment escrow used as the substrate for
///         enforceability/gas measurements. ETH-only for now; an ERC-20 variant
///         is added later for E2 token-amount tests (see plan B.1).
/// @dev Design notes (B.1):
///      - `AgentPolicy` is per-agent, not global: `mapping(address => AgentPolicy)`.
///      - `DailyState` packs (dayStart, spent) into one slot. A settlement on a
///        new day (relative to `dayStart`) resets `spent` to 0 and bumps `dayStart`.
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

    struct DailyState {
        uint128 dayStart;
        uint128 spent;
    }

    address public immutable user;
    mapping(address => AgentPolicy) public policies;
    mapping(address => DailyState) public dailyState;
    mapping(address => uint256) public balances;

    error PolicyInactive();
    error PolicyExpired();
    error ExceedsPerRequest();
    error ExceedsDailyCap();
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
    function settle(address agent, address payable to, uint256 amount) external {
        AgentPolicy memory p = policies[agent];
        if (!p.active) revert PolicyInactive();
        if (block.timestamp > p.validUntil) revert PolicyExpired();
        if (amount > p.maxPerRequest) revert ExceedsPerRequest();

        DailyState memory d = dailyState[agent];
        uint256 today = block.timestamp / 1 days;
        if (today != d.dayStart) {
            d.dayStart = uint128(today);
            d.spent = 0;
        }
        if (uint256(d.spent) + amount > p.maxPerDay) revert ExceedsDailyCap();
        if (balances[agent] < amount) revert InsufficientBalance();

        d.spent += uint128(amount);
        dailyState[agent] = d;
        balances[agent] -= amount;

        (bool ok,) = to.call{value: amount}("");
        require(ok, "transfer failed");
    }

    /// @dev Batched settlement. Used for batch-curve measurement.
    function batchDeduct(
        address agent,
        address payable[] calldata recipients,
        uint256[] calldata amounts
    ) external {
        require(recipients.length == amounts.length, "length mismatch");
        AgentPolicy memory p = policies[agent];
        DailyState memory d = dailyState[agent];

        uint256 today = block.timestamp / 1 days;
        if (today != d.dayStart) {
            d.dayStart = uint128(today);
            d.spent = 0;
        }

        // Hoist invariant checks out of the loop where possible.
        if (!p.active) revert PolicyInactive();
        if (block.timestamp > p.validUntil) revert PolicyExpired();

        uint256 totalAmount;
        for (uint256 i = 0; i < amounts.length; ++i) {
            if (amounts[i] > p.maxPerRequest) revert ExceedsPerRequest();
            totalAmount += amounts[i];
        }
        if (uint256(d.spent) + totalAmount > p.maxPerDay) revert ExceedsDailyCap();
        if (balances[agent] < totalAmount) revert InsufficientBalance();

        d.spent += uint128(totalAmount);
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
