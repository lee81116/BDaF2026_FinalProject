// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {GasMeasure} from "./GasMeasure.sol";
import {E2_ValueCap_Harness} from "../../src/policies/E2_ValueCap.sol";
import {E2_TokenAmountCap_Harness} from "../../src/policies/E2_TokenAmountCap.sol";
import {E2_ApprovalCap_Harness} from "../../src/policies/E2_ApprovalCap.sol";

/// @notice D — E2 cap per-check gas (callee-frame, via vm.lastCallGas()).
///
/// E2 checks are `pure`: no SLOAD, so there is NO cold/warm split — one number
/// per path. Deterministic under the pinned toolchain (solc 0.8.26, optimizer
/// 200 runs, forge 1.7.1); a drift beyond TOL means the model is wrong — open a
/// trace, do not widen the band (discipline #1).
///
/// Opcode account:
///  - pass (~284): dominated by the harness ABI front-matter — selector
///    dispatch + CALLDATASIZE check + decoding two uint256 args. The check
///    itself is one GT (~3) + a JUMPI; it is NOT where the gas goes.
///  - revert (~308 = pass + ~24): MSTORE the 4-byte error selector, then REVERT
///    instead of a clean STOP.
///
/// C.4 claim: the three caps are the same comparison under different names, so
/// they must measure identically. test_gas_E2_AllThree_* assert that directly.
contract E2_Cap_GasTest is GasMeasure {
    E2_ValueCap_Harness internal valueCap;
    E2_TokenAmountCap_Harness internal tokenCap;
    E2_ApprovalCap_Harness internal approvalCap;

    uint256 internal constant CAP = 1 ether;

    // Predicted (opcode-derived, lastCallGas callee-frame), pinned toolchain.
    uint256 internal constant PRED_PASS = 284;
    uint256 internal constant PRED_REVERT = 308;
    uint256 internal constant TOL = 2; // narrow: >2 gas drift => investigate

    function setUp() public override {
        super.setUp();
        valueCap = new E2_ValueCap_Harness();
        tokenCap = new E2_TokenAmountCap_Harness();
        approvalCap = new E2_ApprovalCap_Harness();
    }

    // --- canonical: E2_ValueCap pass + revert ---------------------------------

    function test_gas_E2_ValueCap_pass() public {
        bytes memory data = abi.encodeCall(E2_ValueCap_Harness.checkExternal, (CAP, CAP));
        uint256 g = _measure(address(valueCap), data, true);
        emit log_named_uint("E2_ValueCap pass", g);
        assertApproxEqAbs(g, PRED_PASS, TOL, "E2_ValueCap pass off prediction");
    }

    function test_gas_E2_ValueCap_revert() public {
        bytes memory data = abi.encodeCall(E2_ValueCap_Harness.checkExternal, (CAP + 1, CAP));
        uint256 g = _measure(address(valueCap), data, false);
        emit log_named_uint("E2_ValueCap revert", g);
        assertApproxEqAbs(g, PRED_REVERT, TOL, "E2_ValueCap revert off prediction");
    }

    // --- C.4 equality across the three caps -----------------------------------

    function test_gas_E2_AllThree_PassEqual() public {
        uint256 gv = _measure(
            address(valueCap), abi.encodeCall(E2_ValueCap_Harness.checkExternal, (CAP, CAP)), true
        );
        uint256 gt = _measure(
            address(tokenCap),
            abi.encodeCall(E2_TokenAmountCap_Harness.checkExternal, (CAP, CAP)),
            true
        );
        uint256 ga = _measure(
            address(approvalCap),
            abi.encodeCall(E2_ApprovalCap_Harness.checkExternal, (CAP, CAP)),
            true
        );
        emit log_named_uint("Value", gv);
        emit log_named_uint("Token", gt);
        emit log_named_uint("Approval", ga);
        assertEq(gv, gt, "ValueCap == TokenAmountCap (pass)");
        assertEq(gt, ga, "TokenAmountCap == ApprovalCap (pass)");
        assertApproxEqAbs(gv, PRED_PASS, TOL, "pass off prediction");
    }

    function test_gas_E2_AllThree_RevertEqual() public {
        uint256 gv = _measure(
            address(valueCap),
            abi.encodeCall(E2_ValueCap_Harness.checkExternal, (CAP + 1, CAP)),
            false
        );
        uint256 gt = _measure(
            address(tokenCap),
            abi.encodeCall(E2_TokenAmountCap_Harness.checkExternal, (CAP + 1, CAP)),
            false
        );
        uint256 ga = _measure(
            address(approvalCap),
            abi.encodeCall(E2_ApprovalCap_Harness.checkExternal, (CAP + 1, CAP)),
            false
        );
        assertEq(gv, gt, "ValueCap == TokenAmountCap (revert)");
        assertEq(gt, ga, "TokenAmountCap == ApprovalCap (revert)");
        assertApproxEqAbs(gv, PRED_REVERT, TOL, "revert off prediction");
    }
}
