// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {GasMeasure} from "./GasMeasure.sol";
import {E3_SlidingWindowRateLimit_Harness} from "../../src/policies/E3_SlidingWindowRateLimit.sol";

/// @notice Measure — E3_SlidingWindowRateLimit per-check gas (callee-frame,
///         via vm.lastCallGas()). Mirrors the E3_CumulativeDailyCap matrix: the
///         packed-slot SSTORE dominates and depends on what was in the slot at
///         tx start.
///
///   ① SET    (first call ever, cold)    — fresh slot; cold SLOAD + SSTORE_SET
///   ② RESET  (cross-tx, same window)    — slot pre-populated; cold SLOAD + SSTORE_RESET
///   ③ dirty  (same-tx 2nd call)         — warm SLOAD + dirty SSTORE (artifact, not realistic)
///   adjacent (cross-tx, window shift)   — RESET + the prev:=curr;curr:=0 branch arith
///   revert   (at cap, cold)             — cold SLOAD + arith + revert; no SSTORE
///
/// W = 100s throughout. setUp commits state in tx0 so the measured SLOADs in
/// each test_* tx are genuinely cold (EIP-2929 access list resets per tx);
/// vm.warp inside each test sets the timestamp and does not affect coldness.
///
/// Opcode model (predict-then-assert, TOL = 2). Anchored on the daily-cap rows:
/// daily RO cold = 2,954 = 2,100 cold SLOAD + 854 arith; daily RW = SLOAD +
/// (arith+prep 900) + SSTORE-class.
///
/// PREDICTION CORRECTION (see docs/gas-results.md). The first model estimated
/// the sliding-window arithmetic delta over daily as ≈ +50 (same-window
/// RO ≈ 3,004). Measurement showed the true same-window "arith + SSTORE-prep" is
/// 1,734 — i.e. +834 over daily's 900. The miss was the cost of the THREE
/// non-byte-aligned packed fields (uint48 / uint104 / uint104): each must be
/// masked + shifted out of the slot on the read-copy and shifted + OR'd back on
/// write, far more than daily's clean uint128/uint128 halves — plus the weighted
/// term's SUB+MUL+DIV+SUB+MUL+DIV+ADD chain and the same/adjacent/gap branch.
/// The decomposition is exact and is the model fix (TOL never widened):
///   SET      = 2,100 cold SLOAD + 1,734 arith+prep + 20,000 SSTORE_SET   = 23,834
///   RESET    = 2,100 cold SLOAD + 1,734 arith+prep +  2,900 SSTORE_RESET =  6,734
///   dirty    =   100 warm SLOAD + 1,734 arith+prep +    100 dirty SSTORE =  1,934
/// SET − RESET = 17,100 = 20,000 − 2,900 (SSTORE class) confirms the split; the
/// 1,734 is provably constant across all three (three equations, one value).
/// adjacent = RESET + 79 (the failed same-window EQ + ADD windowStart+W + EQ +
/// the prev:=curr;curr:=0 path) = 6,813. revert = 2,100 cold SLOAD + partial
/// arith (no write-back/repack, no SSTORE) + RateLimitExceeded(uint256,uint256)
/// glue (selector + two arg MSTOREs + REVERT) = 3,437.
contract E3_SlidingWindow_GasTest is GasMeasure {
    E3_SlidingWindowRateLimit_Harness internal freshH; // ① SET: slot empty
    E3_SlidingWindowRateLimit_Harness internal preWrittenH; // ② RESET + ③ dirty
    E3_SlidingWindowRateLimit_Harness internal adjacentH; // adjacent-window shift
    E3_SlidingWindowRateLimit_Harness internal capPinnedH; // revert: at cap

    uint256 internal constant W = 100;
    uint256 internal constant MAXC = 10; // generous cap for the pass paths

    // Opcode-reconciled (callee-frame), pinned toolchain. TOL = 2.
    // (Initial predictions 23050 / 5950 / 1150 / 5959 / 3032 corrected below;
    //  see the model-correction note above and docs/gas-results.md.)
    uint256 internal constant PRED_SET = 23834; // 2100 cold SLOAD + 1734 arith+prep + 20000 SET
    uint256 internal constant PRED_RESET = 6734; // 2100 cold SLOAD + 1734 arith+prep + 2900 RESET
    uint256 internal constant PRED_DIRTY = 1934; // 100 warm SLOAD + 1734 arith+prep + 100 dirty
    uint256 internal constant PRED_ADJACENT = 6813; // RESET + 79 adjacency-branch arith
    uint256 internal constant PRED_REVERT = 3437; // 2100 cold SLOAD + partial arith + 2-arg revert glue
    uint256 internal constant TOL = 2;

    function setUp() public override {
        super.setUp();
        freshH = new E3_SlidingWindowRateLimit_Harness();
        preWrittenH = new E3_SlidingWindowRateLimit_Harness();
        adjacentH = new E3_SlidingWindowRateLimit_Harness();
        capPinnedH = new E3_SlidingWindowRateLimit_Harness();

        // Pre-populate so the measured SLOAD reads a non-zero slot cross-tx.
        preWrittenH.setState(uint48(100), 0, uint104(1)); // same-window @ t=150
        adjacentH.setState(uint48(100), 0, uint104(2)); // previous window @ t=250
        capPinnedH.setState(uint48(100), 0, uint104(5)); // at cap @ t=150, max=5
    }

    // ① SET: fresh slot, zero → nonzero ---------------------------------------

    function test_gas_E3_SlidingWindow_set() public {
        vm.warp(50); // window [0,100): ws = 0, same-window branch on fresh slot
        uint256 g = _measure(
            address(freshH),
            abi.encodeCall(E3_SlidingWindowRateLimit_Harness.checkReadWrite, (W, MAXC)),
            true
        );
        emit log_named_uint("E3_SlidingWindow RW cold SET (zero->nonzero)", g);
        assertApproxEqAbs(g, PRED_SET, TOL, "SW SET off prediction");
    }

    // ② RESET: nonzero → nonzero, same window ---------------------------------

    function test_gas_E3_SlidingWindow_reset() public {
        vm.warp(150); // window [100,200): same-window branch (windowStart 100)
        uint256 g = _measure(
            address(preWrittenH),
            abi.encodeCall(E3_SlidingWindowRateLimit_Harness.checkReadWrite, (W, MAXC)),
            true
        );
        emit log_named_uint("E3_SlidingWindow RW cold RESET (nonzero->nonzero)", g);
        assertApproxEqAbs(g, PRED_RESET, TOL, "SW RESET off prediction");
    }

    // ③ dirty: same-tx second write -------------------------------------------

    function test_gas_E3_SlidingWindow_sameTxDirty() public {
        vm.warp(150);
        bytes memory data =
            abi.encodeCall(E3_SlidingWindowRateLimit_Harness.checkReadWrite, (W, MAXC));
        _measure(address(preWrittenH), data, true); // priming call, gas discarded
        uint256 g = _measure(address(preWrittenH), data, true);
        emit log_named_uint("E3_SlidingWindow RW same-tx dirty", g);
        assertApproxEqAbs(g, PRED_DIRTY, TOL, "SW dirty off prediction");
    }

    // adjacent-window shift: prev := curr; curr := 0 --------------------------

    function test_gas_E3_SlidingWindow_adjacentShift() public {
        vm.warp(250); // window [200,300): adjacent to the stored window [100,200)
        uint256 g = _measure(
            address(adjacentH),
            abi.encodeCall(E3_SlidingWindowRateLimit_Harness.checkReadWrite, (W, MAXC)),
            true
        );
        emit log_named_uint("E3_SlidingWindow RW adjacent-window shift", g);
        assertApproxEqAbs(g, PRED_ADJACENT, TOL, "SW adjacent off prediction");
    }

    // revert: at cap, no SSTORE -----------------------------------------------

    function test_gas_E3_SlidingWindow_revert() public {
        vm.warp(150); // same window; curr already at 5, max 5 → attempted 6 > 5
        uint256 g = _measure(
            address(capPinnedH),
            abi.encodeCall(E3_SlidingWindowRateLimit_Harness.checkReadWrite, (W, 5)),
            false
        );
        emit log_named_uint("E3_SlidingWindow revert cold (at cap)", g);
        assertApproxEqAbs(g, PRED_REVERT, TOL, "SW revert off prediction");
    }
}
