// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title E1_TargetAllowlist
/// @notice E1 (access-level) policy: the agent may only pay targets the user
///         pre-approved. Expressiveness is "who can be called", independent of
///         amount or context — hence E1.
/// @dev Module pattern (plan C.1):
///      - The `library` holds the internal `check`. Internal library functions
///        are inlined into the caller at compile time (no DELEGATECALL), so the
///        escrow integration (C.6) pays the same opcodes as this isolated form.
///      - The `*_Harness` owns the storage and exposes `check` via an external
///        function, so a single call gives a clean, isolated gas number whose
///        cold/warm SLOAD is attributable to the check itself (Section D).
library E1_TargetAllowlist {
    error TargetNotAllowed();

    /// @dev One dynamic mapping read (keccak of slot+key, then SLOAD).
    function check(mapping(address => bool) storage allowlist, address target) internal view {
        if (!allowlist[target]) revert TargetNotAllowed();
    }
}

contract E1_TargetAllowlist_Harness {
    mapping(address => bool) public allowlist;

    function setAllowed(address target, bool ok) external {
        allowlist[target] = ok;
    }

    function checkExternal(address target) external view {
        E1_TargetAllowlist.check(allowlist, target);
    }
}
