// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title E3_CumulativeDailyCap
/// @notice E3 (contextual / stateful) policy: cumulative spend within a rolling
///         day may not exceed a cap. The most stateful sprint-scope check — it
///         reads prior spend, resets across a day boundary, and writes the new
///         running total. Expressiveness depends on accumulated history, the
///         strongest form of context in scope — hence E3.
/// @dev `(dayStart, spent)` are packed into a single 32-byte slot, so the read
///      is one SLOAD and the persist is one SSTORE. `advance` is `pure` and does
///      NOT touch storage: the harness decides whether to persist the returned
///      state. That split lets Section D measure the read-only path and the
///      read+write path with everything *except the trailing SSTORE* held equal.
library E3_CumulativeDailyCap {
    error ExceedsDailyCap();

    struct DailyState {
        uint128 dayStart;
        uint128 spent;
    }

    /// @dev Reset on a new day, enforce the cap, return state with `amount`
    ///      accumulated. Reverts if the cap would be breached. No storage access.
    /// @param d      the loaded daily state (caller does the SLOAD)
    /// @param amount the spend to account for
    /// @param cap    the per-day cap
    /// @param today  current day index, i.e. `block.timestamp / 1 days`
    function advance(DailyState memory d, uint256 amount, uint256 cap, uint256 today)
        internal
        pure
        returns (DailyState memory)
    {
        if (today != d.dayStart) {
            d.dayStart = uint128(today);
            d.spent = 0;
        }
        if (uint256(d.spent) + amount > cap) revert ExceedsDailyCap();
        d.spent += uint128(amount);
        return d;
    }
}

contract E3_CumulativeDailyCap_Harness {
    E3_CumulativeDailyCap.DailyState public dailyState;

    function setState(uint128 dayStart, uint128 spent) external {
        dailyState = E3_CumulativeDailyCap.DailyState({dayStart: dayStart, spent: spent});
    }

    /// @dev Read + compare only: one SLOAD of the packed slot plus arithmetic.
    ///      The updated state is computed but discarded (no SSTORE). The SLOAD
    ///      and the cap comparison cannot be optimized away because `advance`
    ///      reverts based on the loaded `spent`.
    function checkReadOnly(uint256 amount, uint256 cap) external view {
        E3_CumulativeDailyCap.DailyState memory d = dailyState;
        uint256 today = block.timestamp / 1 days;
        E3_CumulativeDailyCap.advance(d, amount, cap, today);
    }

    /// @dev Read + compare + persist: identical to `checkReadOnly` plus one
    ///      SSTORE of the packed slot. The gas delta isolates the write cost.
    function checkReadWrite(uint256 amount, uint256 cap) external {
        E3_CumulativeDailyCap.DailyState memory d = dailyState;
        uint256 today = block.timestamp / 1 days;
        dailyState = E3_CumulativeDailyCap.advance(d, amount, cap, today);
    }
}
