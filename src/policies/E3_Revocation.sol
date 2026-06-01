// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title E3_Revocation
/// @notice E3 (contextual / stateful) policy: a policy is honored only while
///         `active`. Revocation flips one stored bit. This is the on-chain
///         primitive behind r_rev (revocability) — hence E3.
/// @dev `check` takes the loaded `bool` and is `pure`; the harness performs the
///      SLOAD of `active`, so the measured cost is one SLOAD plus an `ISZERO`.
library E3_Revocation {
    error PolicyInactive();

    function check(bool active) internal pure {
        if (!active) revert PolicyInactive();
    }
}

contract E3_Revocation_Harness {
    bool public active;

    function setActive(bool a) external {
        active = a;
    }

    function checkExternal() external view {
        // SLOAD of `active` happens here; cold on first touch, warm after.
        E3_Revocation.check(active);
    }
}
