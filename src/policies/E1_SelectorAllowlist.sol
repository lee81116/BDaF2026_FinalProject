// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title E1_SelectorAllowlist
/// @notice E1 (access-level) policy: the agent may only invoke function
///         selectors the user pre-approved. Same access-level expressiveness as
///         the target allowlist, keyed on `bytes4` instead of `address`.
/// @dev Dynamic-mapping variant (plan C.3, D.2): one mapping read per check.
///      A hardcoded selector set would be near-free; we keep it dynamic so the
///      measured cost is a real SLOAD, comparable to the target allowlist.
library E1_SelectorAllowlist {
    error SelectorNotAllowed();

    function check(mapping(bytes4 => bool) storage allowlist, bytes4 selector) internal view {
        if (!allowlist[selector]) revert SelectorNotAllowed();
    }
}

contract E1_SelectorAllowlist_Harness {
    mapping(bytes4 => bool) public allowlist;

    function setAllowed(bytes4 selector, bool ok) external {
        allowlist[selector] = ok;
    }

    function checkExternal(bytes4 selector) external view {
        E1_SelectorAllowlist.check(allowlist, selector);
    }
}
