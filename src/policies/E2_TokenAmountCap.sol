// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title E2_TokenAmountCap
/// @notice E2 (transaction-level) policy: an ERC-20 transfer amount may not
///         exceed a cap. Semantically distinct from the native-value cap (it
///         governs token units, not wei) but structurally the same comparison.
/// @dev Typed for ERC-20 amounts. The point of keeping it separate from
///      `E2_ValueCap` (plan C.4) is empirical: measure whether a differently
///      *named* but identically *shaped* check costs the same gas. It should —
///      both compile to one `GT` + conditional `revert`.
library E2_TokenAmountCap {
    error ExceedsTokenAmountCap();

    function check(uint256 tokenAmount, uint256 cap) internal pure {
        if (tokenAmount > cap) revert ExceedsTokenAmountCap();
    }
}

contract E2_TokenAmountCap_Harness {
    function checkExternal(uint256 tokenAmount, uint256 cap) external pure {
        E2_TokenAmountCap.check(tokenAmount, cap);
    }
}
