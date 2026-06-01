// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title E3_Expiry
/// @notice E3 (contextual / stateful) policy: a policy is valid only until
///         `validUntil`. Expressiveness depends on chain context
///         (`block.timestamp`) and on stored state — hence E3.
/// @dev The harness holds `validUntil` in storage and reads it before calling
///      `check`, so the measured cost is one SLOAD (cold or warm) plus a
///      `block.timestamp` comparison. `check` itself is `view` (reads
///      `block.timestamp`) but stateless — the SLOAD is attributed to the
///      harness read, keeping the cold/warm distinction clean (Section D).
library E3_Expiry {
    error Expired();

    function check(uint256 validUntil) internal view {
        if (block.timestamp > validUntil) revert Expired();
    }
}

contract E3_Expiry_Harness {
    uint256 public validUntil;

    function setValidUntil(uint256 v) external {
        validUntil = v;
    }

    function checkExternal() external view {
        // SLOAD of `validUntil` happens here; cold on first touch, warm after.
        E3_Expiry.check(validUntil);
    }
}
