// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {GasMeasure} from "./GasMeasure.sol";
import {E1_TargetAllowlist_Harness} from "../../src/policies/E1_TargetAllowlist.sol";
import {E1_SelectorAllowlist_Harness} from "../../src/policies/E1_SelectorAllowlist.sol";

/// @notice D-3 — E1 allowlist per-check gas (callee-frame, vm.lastCallGas()).
///
/// Both E1 modules are a single dynamic-mapping read. Plan D.2 mentions a
/// "~500–2000" range for selector — that assumes a hardcoded set; we deliberately
/// keep the selector path as a dynamic mapping (see comment in
/// E1_SelectorAllowlist.sol) so the gas is governed by the same SLOAD-class
/// opcode as target. Target and Selector therefore measure within a small
/// constant of each other (asserted via approxEq, not eq — see below).
///
/// Opcode account (callee-frame, pinned toolchain — measured, not guessed):
///   Selector pass warm  = 531  baseline
///   + ABI strict decode of `address`              +26  (Target − Selector delta)
///   + cold→warm SLOAD (EIP-2929)                  +2000 (cold = 2100, warm = 100)
///   + revert overhead (MSTORE selector + REVERT)  +26
///
/// Target − Selector = 26 (constant across cold/warm/pass/revert). Source: Solidity
/// 0.8.x's strict ABI decoder verifies the high 12 bytes of an `address` calldata
/// arg are zero (`iszero(eq(arg, and(arg, 0xff..20bytes..ff)))` ≈ 4 PUSHes +
/// AND + EQ + ISZERO + JUMPI ≈ 25–30 gas). `bytes4` has a cheaper cleanup
/// because it lives in the high-4-byte lane already. This is calldata decoding,
/// not the check itself — both paths execute one dynamic-mapping SLOAD.
///
/// cold + warm split is controlled within the test transaction: setUp pre-stores
/// the slot value via the harness (warming setUp's access list, which is reset
/// at test entry — so first read in test_* is cold). For warm measurements we
/// pre-touch the slot inside the test body using the public getter, then
/// _measure.
contract E1_Allowlist_GasTest is GasMeasure {
    E1_TargetAllowlist_Harness internal targetH;
    E1_SelectorAllowlist_Harness internal selectorH;

    address internal constant ALLOWED_TARGET = address(0xC0FFEE);
    address internal constant DENIED_TARGET = address(0xBADBAD);
    bytes4 internal constant ALLOWED_SELECTOR = bytes4(0xAABBCCDD);
    bytes4 internal constant DENIED_SELECTOR = bytes4(0x11223344);

    // Predictions (opcode-derived, callee-frame, pinned toolchain).
    // Target and Selector each have their own PRED — the 26-gas delta is the
    // address-vs-bytes4 ABI decoder cost, documented above. TOL stays at 2.
    uint256 internal constant PRED_TARGET_PASS_COLD = 2557;
    uint256 internal constant PRED_TARGET_PASS_WARM = 557;
    uint256 internal constant PRED_TARGET_REVERT_COLD = 2583;
    uint256 internal constant PRED_TARGET_REVERT_WARM = 583;
    uint256 internal constant PRED_SEL_PASS_COLD = 2531;
    uint256 internal constant PRED_SEL_PASS_WARM = 531;
    uint256 internal constant PRED_SEL_REVERT_COLD = 2557;
    uint256 internal constant PRED_SEL_REVERT_WARM = 557;
    uint256 internal constant TOL = 2;
    // Cross-check: same storage-class (1 dynamic SLOAD), differ by ABI decoder.
    uint256 internal constant TOL_CROSS = 30;

    function setUp() public override {
        super.setUp();
        targetH = new E1_TargetAllowlist_Harness();
        selectorH = new E1_SelectorAllowlist_Harness();
        // Pre-store allowed entries. The SSTORE here warms the slot for setUp's
        // tx access list, but Foundry resets access list at each test entry, so
        // the first read in each test_* is cold.
        targetH.setAllowed(ALLOWED_TARGET, true);
        selectorH.setAllowed(ALLOWED_SELECTOR, true);
    }

    // ---------- Target allowlist ---------------------------------------------

    function test_gas_E1_Target_pass_cold() public {
        uint256 g = _measure(
            address(targetH),
            abi.encodeCall(E1_TargetAllowlist_Harness.checkExternal, (ALLOWED_TARGET)),
            true
        );
        emit log_named_uint("E1_Target pass cold", g);
        assertApproxEqAbs(g, PRED_TARGET_PASS_COLD, TOL, "E1_Target pass cold off prediction");
    }

    function test_gas_E1_Target_pass_warm() public {
        // Pre-touch the slot to warm it within this tx.
        targetH.allowlist(ALLOWED_TARGET);
        uint256 g = _measure(
            address(targetH),
            abi.encodeCall(E1_TargetAllowlist_Harness.checkExternal, (ALLOWED_TARGET)),
            true
        );
        emit log_named_uint("E1_Target pass warm", g);
        assertApproxEqAbs(g, PRED_TARGET_PASS_WARM, TOL, "E1_Target pass warm off prediction");
    }

    function test_gas_E1_Target_revert_cold() public {
        uint256 g = _measure(
            address(targetH),
            abi.encodeCall(E1_TargetAllowlist_Harness.checkExternal, (DENIED_TARGET)),
            false
        );
        emit log_named_uint("E1_Target revert cold", g);
        assertApproxEqAbs(g, PRED_TARGET_REVERT_COLD, TOL, "E1_Target revert cold off prediction");
    }

    function test_gas_E1_Target_revert_warm() public {
        targetH.allowlist(DENIED_TARGET);
        uint256 g = _measure(
            address(targetH),
            abi.encodeCall(E1_TargetAllowlist_Harness.checkExternal, (DENIED_TARGET)),
            false
        );
        emit log_named_uint("E1_Target revert warm", g);
        assertApproxEqAbs(g, PRED_TARGET_REVERT_WARM, TOL, "E1_Target revert warm off prediction");
    }

    // ---------- Selector allowlist -------------------------------------------

    function test_gas_E1_Selector_pass_cold() public {
        uint256 g = _measure(
            address(selectorH),
            abi.encodeCall(E1_SelectorAllowlist_Harness.checkExternal, (ALLOWED_SELECTOR)),
            true
        );
        emit log_named_uint("E1_Selector pass cold", g);
        assertApproxEqAbs(g, PRED_SEL_PASS_COLD, TOL, "E1_Selector pass cold off prediction");
    }

    function test_gas_E1_Selector_pass_warm() public {
        selectorH.allowlist(ALLOWED_SELECTOR);
        uint256 g = _measure(
            address(selectorH),
            abi.encodeCall(E1_SelectorAllowlist_Harness.checkExternal, (ALLOWED_SELECTOR)),
            true
        );
        emit log_named_uint("E1_Selector pass warm", g);
        assertApproxEqAbs(g, PRED_SEL_PASS_WARM, TOL, "E1_Selector pass warm off prediction");
    }

    function test_gas_E1_Selector_revert_cold() public {
        uint256 g = _measure(
            address(selectorH),
            abi.encodeCall(E1_SelectorAllowlist_Harness.checkExternal, (DENIED_SELECTOR)),
            false
        );
        emit log_named_uint("E1_Selector revert cold", g);
        assertApproxEqAbs(g, PRED_SEL_REVERT_COLD, TOL, "E1_Selector revert cold off prediction");
    }

    function test_gas_E1_Selector_revert_warm() public {
        selectorH.allowlist(DENIED_SELECTOR);
        uint256 g = _measure(
            address(selectorH),
            abi.encodeCall(E1_SelectorAllowlist_Harness.checkExternal, (DENIED_SELECTOR)),
            false
        );
        emit log_named_uint("E1_Selector revert warm", g);
        assertApproxEqAbs(g, PRED_SEL_REVERT_WARM, TOL, "E1_Selector revert warm off prediction");
    }

    // ---------- Target == Selector cross-check (both are 1 dynamic SLOAD) ----

    function test_gas_E1_TargetEqualsSelector_pass_cold() public {
        uint256 gT = _measure(
            address(targetH),
            abi.encodeCall(E1_TargetAllowlist_Harness.checkExternal, (ALLOWED_TARGET)),
            true
        );
        uint256 gS = _measure(
            address(selectorH),
            abi.encodeCall(E1_SelectorAllowlist_Harness.checkExternal, (ALLOWED_SELECTOR)),
            true
        );
        emit log_named_uint("Target", gT);
        emit log_named_uint("Selector", gS);
        assertApproxEqAbs(gT, gS, TOL_CROSS, "Target ~= Selector (1 dyn SLOAD; ABI delta)");
    }

    function test_gas_E1_TargetEqualsSelector_revert_cold() public {
        uint256 gT = _measure(
            address(targetH),
            abi.encodeCall(E1_TargetAllowlist_Harness.checkExternal, (DENIED_TARGET)),
            false
        );
        uint256 gS = _measure(
            address(selectorH),
            abi.encodeCall(E1_SelectorAllowlist_Harness.checkExternal, (DENIED_SELECTOR)),
            false
        );
        assertApproxEqAbs(gT, gS, TOL_CROSS, "Target ~= Selector (1 dyn SLOAD; ABI delta)");
    }
}
