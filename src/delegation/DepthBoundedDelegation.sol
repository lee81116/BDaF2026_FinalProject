// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {E3_DelegationDepth} from "../policies/E3_DelegationDepth.sol";

/// @title DepthBoundedDelegation — E3 extension to Section G
/// @notice `TwoHopDelegation` with one thing added: a depth bound. Each
///         permission records `(parentId, depth)`; `grant` derives
///         `depth = parent.depth + 1` and enforces `E3_DelegationDepth.check`
///         against `MAX_DEPTH`. Everything else — the SINGLE funding pool, the
///         LOCAL-ONLY `executeLocalOnly` with its own `spent` slot per
///         permission — is unchanged from `TwoHopDelegation`.
/// @dev The point is the contrast: a depth bound constrains how LONG the chain
///      may be, but not how MUCH the chain may collectively spend. With the
///      chain capped at `MAX_DEPTH = 2`, the Section G escape (`User→A→B`)
///      still drains the pool past the root authorization, because every
///      permission still meters its own budget in its own slot. The missing
///      mechanism is root-anchored accounting — orthogonal to depth, and
///      unchanged here.
contract DepthBoundedDelegation {
    uint256 public constant MAX_DEPTH = 2;

    struct Permission {
        bytes32 parentId; // the permission this was derived from (0 = root grant)
        uint256 depth; // 1 for a root grant; parent.depth + 1 otherwise
        address parent; // who delegated this (msg.sender at grant time)
        address subject; // who holds and may exercise it
        uint256 perCallCap;
        uint256 cumulativeCap;
        uint256 spent;
        bool active;
    }

    mapping(bytes32 => Permission) public permissions;
    uint256 public nonce;

    /// @notice The single funding pool (see `TwoHopDelegation`): one source of
    ///         money, so a global overspend is unambiguous.
    receive() external payable {}

    /// @notice Grant `subject` a permission derived from `parentId`. A root
    ///         grant passes `parentId == bytes32(0)` (depth 1); otherwise the
    ///         caller must hold `parentId` and the new depth is one deeper. The
    ///         depth bound is enforced BEFORE any state is written.
    function grant(bytes32 parentId, address subject, uint256 perCallCap, uint256 cumulativeCap)
        external
        returns (bytes32 permId)
    {
        uint256 depth;
        if (parentId == bytes32(0)) {
            depth = 1; // root grant from the user
        } else {
            Permission storage parent = permissions[parentId];
            require(parent.active, "inactive parent");
            require(parent.subject == msg.sender, "not parent holder");
            depth = parent.depth + 1;
        }
        // Enforce the depth bound BEFORE writing any state.
        E3_DelegationDepth.check(depth, MAX_DEPTH);

        permId = keccak256(abi.encodePacked(msg.sender, subject, nonce++));
        permissions[permId] = Permission({
            parentId: parentId,
            depth: depth,
            parent: msg.sender,
            subject: subject,
            perCallCap: perCallCap,
            cumulativeCap: cumulativeCap,
            spent: 0,
            active: true
        });
    }

    /// @dev LOCAL-ONLY enforcement, identical to `TwoHopDelegation`: validates
    ///      the immediate permission's caps and nothing above it. No traversal
    ///      of `parentId`; no global accounting. This is what lets a legal-depth
    ///      chain still escape the root budget.
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

    function depthOf(bytes32 permId) external view returns (uint256) {
        return permissions[permId].depth;
    }
}
