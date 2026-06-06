// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {GasMeasure} from "./GasMeasure.sol";
import {E3_DelegationDepth_Harness} from "../../src/policies/E3_DelegationDepth.sol";

/// @notice Measure — E3_DelegationDepth per-check gas (callee-frame).
///
/// HYPOTHESIS (handoff M2): `check(depth, maxDepth)` is opcode-identical in
/// shape to `E2_ValueCap` — dispatch + decode two words + one GT + STOP — so the
/// pass path must measure EXACTLY 284 and the revert path 308 (the E2 baseline).
///
/// The pass path is byte-for-byte the E2 comparison and is expected to confirm
/// 284. The revert path is where the hypothesis is at risk: `DepthExceeded`
/// carries two uint256 args, whereas E2's `ExceedsValueCap()` is parameterless.
/// If the revert misses 308, the delta is the cost of MSTORE-ing the two error
/// words — explained at the opcode level in docs/gas-results.md, never absorbed
/// by widening TOL.
contract E3_DelegationDepth_GasTest is GasMeasure {
    E3_DelegationDepth_Harness internal depth;

    uint256 internal constant MAXD = 2;

    // Pass CONFIRMS the hypothesis at exactly 284 (E2_ValueCap shape). Revert
    // MISSES the 308 hypothesis: measured 350. The +42 over the E2 revert is the
    // two uint256 args of DepthExceeded — two extra arg MSTOREs + memory growth
    // to the 0x44 error region — which the parameterless ExceedsValueCap() does
    // not pay. Model fixed, TOL not widened. See docs/gas-results.md.
    uint256 internal constant PRED_PASS = 284; // E2_ValueCap pass baseline (hypothesis CONFIRMED)
    uint256 internal constant PRED_REVERT = 350; // 308 E2 baseline + 42 for 2-arg DepthExceeded
    uint256 internal constant TOL = 2;

    function setUp() public override {
        super.setUp();
        depth = new E3_DelegationDepth_Harness();
    }

    function test_gas_E3_DelegationDepth_pass() public {
        bytes memory data = abi.encodeCall(E3_DelegationDepth_Harness.checkExternal, (MAXD, MAXD));
        uint256 g = _measure(address(depth), data, true); // depth == maxDepth: pass
        emit log_named_uint("E3_DelegationDepth pass", g);
        assertApproxEqAbs(g, PRED_PASS, TOL, "DelegationDepth pass off prediction");
    }

    function test_gas_E3_DelegationDepth_revert() public {
        bytes memory data =
            abi.encodeCall(E3_DelegationDepth_Harness.checkExternal, (MAXD + 1, MAXD));
        uint256 g = _measure(address(depth), data, false); // depth > maxDepth: revert
        emit log_named_uint("E3_DelegationDepth revert", g);
        assertApproxEqAbs(g, PRED_REVERT, TOL, "DelegationDepth revert off prediction");
    }
}
