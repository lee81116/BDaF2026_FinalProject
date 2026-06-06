// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title E3_DelegationDepth
/// @notice E3 (contextual / stateful) policy: bound the LENGTH of a delegation
///         chain. A permission at depth `depth` may be granted only while
///         `depth <= maxDepth`. The check itself is a single comparison — the
///         "context" is the depth the caller has already accumulated up the
///         chain, supplied as an argument. See `DepthBoundedDelegation` for the
///         stateful derivation of `depth` from the parent permission.
/// @dev `check` is `pure`: opcode-identical in shape to `E2_ValueCap`
///      (dispatch + decode two words + one GT + STOP). The only behavioural
///      difference is the error it raises. The accompanying gas test pins the
///      hypothesis that the pass path therefore measures identically to the E2
///      cap baseline.
library E3_DelegationDepth {
    error DepthExceeded(uint256 depth, uint256 maxDepth);

    function check(uint256 depth, uint256 maxDepth) internal pure {
        if (depth > maxDepth) revert DepthExceeded(depth, maxDepth);
    }
}

contract E3_DelegationDepth_Harness {
    function checkExternal(uint256 depth, uint256 maxDepth) external pure {
        E3_DelegationDepth.check(depth, maxDepth);
    }
}
