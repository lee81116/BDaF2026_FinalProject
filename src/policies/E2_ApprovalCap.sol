// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title E2_ApprovalCap
/// @notice E2 (transaction-level) policy: the allowance granted in an `approve`
///         call may not exceed a cap. Governs how much an agent may *authorize*
///         a third party to pull, rather than how much it spends directly.
/// @dev Third sibling of the E2 cap trio (plan C.4). Identical comparison shape
///      to value/token caps; kept separate so the report can state — and the
///      gas table can show — that approval-allowance capping is no costlier than
///      direct value capping. The semantic difference lives off-chain; the
///      on-chain enforcement primitive is the same `GT`.
library E2_ApprovalCap {
    error ExceedsApprovalCap();

    function check(uint256 approvalAmount, uint256 cap) internal pure {
        if (approvalAmount > cap) revert ExceedsApprovalCap();
    }
}

contract E2_ApprovalCap_Harness {
    function checkExternal(uint256 approvalAmount, uint256 cap) external pure {
        E2_ApprovalCap.check(approvalAmount, cap);
    }
}
