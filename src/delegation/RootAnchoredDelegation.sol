// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title RootAnchoredDelegation — Section G′ (the cross-hop closure)
/// @notice Same single-pool grant/execute shape as `TwoHopDelegation`, but it
///         CLOSES the Section G escape by walking the parent chain to the root
///         on every spend and debiting a per-permission, root-anchored counter
///         at every ancestor. This is methodology.md option (b) — the host-side
///         analog of MetaMask's chain walk + hash-keyed counter (H5).
/// @dev The contrast with `TwoHopDelegation` is exactly one thing: that contract
///      checks only the immediate permission's own `spent` slot; this one debits
///      EVERY ancestor's counter, so a sub-delegate's spend is charged against
///      the budget its parent originally received. A's 1.5 + B's 2.0 therefore
///      hits the 2-ETH root cap and reverts — the escape is priced, not free.
///      Closing it costs O(depth) root-anchored state per spend; the `_Gas` test
///      measures the per-hop increment (callee-frame, comparable to the host E3
///      RESET row — unlike MetaMask's caller-side 63k).
contract RootAnchoredDelegation {
    struct Permission {
        bytes32 parentId; // 0 for a root grant
        uint256 depth; // 1 for a root grant; parent.depth + 1 otherwise
        address subject; // who holds and may exercise it
        uint256 perCallCap;
        uint256 cumulativeCap; // this permission's own cap
        bool active;
    }

    mapping(bytes32 => Permission) public permissions;
    mapping(bytes32 => uint256) public spentOf; // per-permission cumulative spend
    uint256 public nonce;

    /// @notice The single funding pool (see `TwoHopDelegation`): one source of
    ///         money, so a global overspend is unambiguous.
    receive() external payable {}

    /// @notice Grant `subject` a permission derived from `parentId`. Root grant
    ///         passes `parentId == bytes32(0)` (depth 1); otherwise the caller
    ///         must hold `parentId` and the new depth is one deeper.
    function grant(bytes32 parentId, address subject, uint256 perCallCap, uint256 cumulativeCap)
        external
        returns (bytes32 permId)
    {
        revert("unimplemented");
    }

    /// @notice Spend `amount` to `to` under `permId`, charging the amount against
    ///         EVERY ancestor's root-anchored counter (root-anchored closure).
    function executeComposed(bytes32 permId, address payable to, uint256 amount) external {
        revert("unimplemented");
    }

    function depthOf(bytes32 permId) external view returns (uint256) {
        revert("unimplemented");
    }
}
