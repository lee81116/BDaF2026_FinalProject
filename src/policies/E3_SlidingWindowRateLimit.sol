// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title E3_SlidingWindowRateLimit
/// @notice E3 (contextual / stateful) policy: a *count-based* rate limit using
///         the standard two-bucket sliding-window approximation. Within any
///         window of length `W` seconds, at most `maxPerWindow` requests may
///         pass; the boundary between windows is smoothed by weighting the
///         previous window's count by the fraction of `W` not yet elapsed.
///         Like `E3_CumulativeDailyCap`, expressiveness depends on accumulated
///         history (prior request counts) — hence E3.
/// @dev State packs into exactly ONE 32-byte slot (uint48 + uint104 + uint104 =
///      256 bits), so the read is one SLOAD and the persist is one SSTORE —
///      mirroring `E3_CumulativeDailyCap`'s single-slot factoring. `advance` is
///      `pure` and does NOT touch storage; the harness owns the slot and decides
///      whether to persist the returned state. That split lets the read-only and
///      read+write paths be measured with everything except the SSTORE held equal.
///
///      This is the two-bucket APPROXIMATION, not a true sliding log. A true
///      sliding log is O(events) slots and is bounded analytically, not measured.
library E3_SlidingWindowRateLimit {
    error RateLimitExceeded(uint256 attempted, uint256 maxPerWindow);

    struct State {
        uint48 windowStart; // aligned start of the current window: (t / W) * W
        uint104 prevCount; // requests admitted in the previous window
        uint104 currCount; // requests admitted in the current window
    }

    /// @dev Roll the buckets forward to time `t`, apply the weighted estimate,
    ///      and (on pass) account this request. Reverts if the cap would break.
    ///      No storage access — the caller does the SLOAD/SSTORE.
    /// @param s            the loaded sliding-window state (caller does the SLOAD)
    /// @param W            window length in seconds (must be > 0)
    /// @param maxPerWindow the per-window request cap (count)
    /// @param t            current timestamp, i.e. `block.timestamp`
    function advance(State memory s, uint256 W, uint256 maxPerWindow, uint256 t)
        internal
        pure
        returns (State memory)
    {
        uint256 ws = (t / W) * W; // aligned start of the window containing t
        uint256 elapsed = t - ws; // seconds into the current window

        uint256 prev;
        uint256 curr;
        if (s.windowStart == ws) {
            // same window: buckets unchanged
            prev = s.prevCount;
            curr = s.currCount;
        } else if (s.windowStart + W == ws) {
            // adjacent window: the old current becomes the new previous
            prev = s.currCount;
            curr = 0;
        } else {
            // gap of >= 2 windows (or fresh state): both buckets reset
            prev = 0;
            curr = 0;
        }

        // Weighted estimate: the previous window decays linearly across W.
        uint256 weighted = curr + (prev * (W - elapsed)) / W;
        uint256 attempted = weighted + 1;
        if (attempted > maxPerWindow) revert RateLimitExceeded(attempted, maxPerWindow);

        s.windowStart = uint48(ws);
        s.prevCount = uint104(prev);
        s.currCount = uint104(curr + 1);
        return s;
    }
}

contract E3_SlidingWindowRateLimit_Harness {
    E3_SlidingWindowRateLimit.State public state;

    function setState(uint48 windowStart, uint104 prevCount, uint104 currCount) external {
        state = E3_SlidingWindowRateLimit.State({
            windowStart: windowStart, prevCount: prevCount, currCount: currCount
        });
    }

    /// @dev Read + compare only: one SLOAD of the packed slot plus arithmetic.
    ///      The updated state is computed but discarded (no SSTORE). The SLOAD
    ///      and the rate check cannot be optimized away because `advance` reverts
    ///      based on the loaded counts.
    function checkReadOnly(uint256 W, uint256 maxPerWindow) external view {
        E3_SlidingWindowRateLimit.State memory s = state;
        E3_SlidingWindowRateLimit.advance(s, W, maxPerWindow, block.timestamp);
    }

    /// @dev Read + compare + persist: identical to `checkReadOnly` plus one
    ///      SSTORE of the packed slot. The gas delta isolates the write cost.
    function checkReadWrite(uint256 W, uint256 maxPerWindow) external {
        E3_SlidingWindowRateLimit.State memory s = state;
        state = E3_SlidingWindowRateLimit.advance(s, W, maxPerWindow, block.timestamp);
    }
}
