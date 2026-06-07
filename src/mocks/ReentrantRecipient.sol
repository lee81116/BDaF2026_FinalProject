// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Escrow} from "../Escrow.sol";

/// @title ReentrantRecipient — SWC-107 probe
/// @notice A payable recipient that re-enters `Escrow.settle` from its
///         `receive()` hook. Used by `test/adversarial/AttackVectors.t.sol` to
///         demonstrate that reentrancy on `settle` is bounded by the cumulative
///         daily cap, not by an explicit reentrancy guard.
/// @dev The reentrant call is wrapped in try/catch on purpose: the daily cap
///      makes the reentrant `settle` revert (CEI commits state before the
///      external call), and we want to OBSERVE that bound from the outside — a
///      blanket revert would instead abort the outer transfer and hide it.
///      Source: SWC-107 / Consensys smart-contract best practices.
contract ReentrantRecipient {
    Escrow public immutable escrow;
    address public immutable agent;

    uint256 public hits; // number of times receive() attempted a reentry
    uint256 public constant MAX_HITS = 3; // hard stop, so a passing reentry can't loop forever

    constructor(Escrow _escrow, address _agent) {
        escrow = _escrow;
        agent = _agent;
    }

    receive() external payable {
        if (hits < MAX_HITS) {
            hits += 1;
            // Re-enter settle for the SAME agent, trying to pull another unit.
            // Escrow.settle has already committed dailyState/balances (CEI), so
            // this reentrant advance() sees spent == cap and reverts
            // ExceedsDailyCap. try/catch so the bounded failure does not abort the
            // outer transfer — we want to observe the bound, not a blanket revert.
            try escrow.settle(agent, payable(address(this)), 1 ether) {
            // reached only if the cap did NOT block reentry (it does)
            }
                catch {
                // expected: ExceedsDailyCap — reentrancy is bounded by the cap
            }
        }
    }
}
