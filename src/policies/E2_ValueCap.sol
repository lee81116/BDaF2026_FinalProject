// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title E2_ValueCap
/// @notice E2 (transaction-level) policy: the native-value of a single call may
///         not exceed a cap. Expressiveness is "how much per transaction" — it
///         inspects the transaction's amount, but no state or context — hence E2.
/// @dev `check` is `pure`: no storage, no `block.*`. This is the cheapest
///      policy in the set and the baseline against which the two sibling caps
///      (token-amount, approval) are compared (plan C.4): all three are the
///      same `uint256` comparison and should measure identically.
library E2_ValueCap {
    error ExceedsValueCap();

    function check(uint256 amount, uint256 cap) internal pure {
        if (amount > cap) revert ExceedsValueCap();
    }
}

contract E2_ValueCap_Harness {
    function checkExternal(uint256 amount, uint256 cap) external pure {
        E2_ValueCap.check(amount, cap);
    }
}
