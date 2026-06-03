// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseTest} from "../BaseTest.sol";

/// @notice Shared gas-measurement helper for Section D (Track A).
/// @dev Measurement primitive: the `vm.lastCallGas()` cheatcode. After any
///      external call it returns the *callee frame's* `gasTotalUsed` — the gas
///      the called function actually consumed, independent of the caller-side
///      `CALL` base cost and the EIP-2929 cold-*account* surcharge (calibrated:
///      account-cold and account-warm both report the same number). Cold vs warm
///      *storage* still shows up here, and is controlled per test by whether the
///      measured slot was already touched earlier in the same transaction.
abstract contract GasMeasure is BaseTest {
    /// @dev Measure one external call's callee-frame gas. Low-level call so a
    ///      reverting check does not bubble up; `expectOk` pins pass vs revert.
    function _measure(address target, bytes memory data, bool expectOk)
        internal
        returns (uint256 gasUsed)
    {
        (bool ok,) = target.call(data);
        gasUsed = vm.lastCallGas().gasTotalUsed;
        if (expectOk) assertTrue(ok, "expected success");
        else assertFalse(ok, "expected revert");
    }
}
