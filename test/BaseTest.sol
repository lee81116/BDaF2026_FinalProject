// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";

abstract contract BaseTest is Test {
    address constant USER = address(0xA11CE);
    address constant AGENT = address(0xB0B);
    address constant PROVIDER = address(0xC0C);
    address constant MALICIOUS = address(0xDEAD);

    function setUp() public virtual {
        vm.label(USER, "User");
        vm.label(AGENT, "Agent");
        vm.label(PROVIDER, "Provider");
        vm.label(MALICIOUS, "MaliciousProvider");
        vm.deal(USER, 100 ether);
        vm.deal(AGENT, 1 ether);
    }

    /// @dev Measure gas cost of a single call, asserting on whether it should
    /// revert. Returns gas used on the successful path.
    function measureGas(address target, bytes memory data, bool expectRevert)
        internal
        returns (uint256 gasUsed)
    {
        uint256 g0 = gasleft();
        (bool ok,) = target.call(data);
        uint256 g1 = gasleft();
        gasUsed = g0 - g1;
        if (expectRevert) {
            assertFalse(ok, "expected revert");
        } else {
            assertTrue(ok, "unexpected revert");
        }
    }
}
