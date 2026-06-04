// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title TwoHopDelegation — Section G
/// @notice A minimal permission-delegation model with a SINGLE funding pool.
///         Hand-written (not auto-generated): the escape only means something
///         if every line of the enforcement is understood.
/// @dev The point of this contract is its omission. `executeLocalOnly` checks
///      only the immediate permission's per-call and cumulative caps. It never
///      walks up the `parent` chain to ask whether the budget a parent was
///      granted has already been consumed elsewhere in the tree. That single
///      missing check is what lets a sub-delegate's spending, plus its parent's
///      own spending, jointly exceed the budget the user originally authorized.
contract TwoHopDelegation {
    struct Permission {
        address parent; // who delegated this (address(0) = a root grant from the user)
        address subject; // who holds and may exercise it
        uint256 perCallCap;
        uint256 cumulativeCap;
        uint256 spent;
        bool active;
    }

    mapping(bytes32 => Permission) public permissions;
    uint256 public nonce;

    /// @notice The single funding pool. Every payout draws from this contract's
    ///         own balance, so there is exactly one source of money and a global
    ///         overspend is unambiguous (see G.4: a single source makes the
    ///         escape clean to assert).
    receive() external payable {}

    /// @notice Grant `subject` a permission with the given caps. Anyone may
    ///         re-delegate what they hold — and crucially, the new permission
    ///         gets its OWN fresh `cumulativeCap`, tracked in its OWN slot,
    ///         independent of the granter's remaining budget.
    function grant(address subject, uint256 perCallCap, uint256 cumulativeCap)
        external
        returns (bytes32 permId)
    {
        permId = keccak256(abi.encodePacked(msg.sender, subject, nonce++));
        permissions[permId] = Permission({
            parent: msg.sender,
            subject: subject,
            perCallCap: perCallCap,
            cumulativeCap: cumulativeCap,
            spent: 0,
            active: true
        });
    }

    /// @dev LOCAL-ONLY enforcement. Validates the immediate permission and
    ///      nothing above it. No traversal of `parent`; no global accounting.
    function executeLocalOnly(bytes32 permId, address payable to, uint256 amount) external {
        Permission storage p = permissions[permId];
        require(p.subject == msg.sender, "not subject");
        require(p.active, "inactive");
        require(amount <= p.perCallCap, "per-call cap");
        require(p.spent + amount <= p.cumulativeCap, "cumulative cap");
        p.spent += amount;
        (bool ok,) = to.call{value: amount}("");
        require(ok, "transfer failed");
    }

    function spentOf(bytes32 permId) external view returns (uint256) {
        return permissions[permId].spent;
    }
}
