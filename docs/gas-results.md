# Per-check gas results (Section D)

All numbers are **callee-frame** gas, captured via the `vm.lastCallGas().gasTotalUsed`
cheatcode inside an isolated harness call. They exclude the caller-side `CALL`
base cost and the EIP-2929 cold-*account* surcharge (calibrated: account-cold
and account-warm both report the same number). Cold-vs-warm *storage* still
shows up in these numbers and is controlled per-test by whether the slot was
already touched earlier in the same transaction.

We do **not** use `forge test --gas-report`'s Min/Max for per-check numbers:
- it bundles caller-side overhead into the figure;
- it mixes cold and warm executions across runs;
- in C-stage it reported a phantom Max = 44,505 for `checkReadWrite` whose true
  cold value is 23,041.

Drift > 2 gas under the pinned toolchain means the opcode model is wrong; we
open a trace (`forge test --match-test <name> -vvvv`) and fix the model, not
the assertion.

Toolchain: forge 1.7.1 (4072e487) · solc 0.8.26 · optimizer 200 · via_ir = false.

## Results

| Check | Level | Path | Storage | Gas | Opcode account |
|---|---|---|---|---|---|
| E2_ValueCap        | E2 | pass   | —    |   284 | dispatch + decode 2 args + 1 GT + STOP |
| E2_ValueCap        | E2 | revert | —    |   308 | pass + MSTORE error selector + REVERT (+24) |
| E2_TokenAmountCap  | E2 | pass   | —    |   284 | identical to ValueCap — same comparison, just typed (C.4) |
| E2_TokenAmountCap  | E2 | revert | —    |   308 | identical to ValueCap |
| E2_ApprovalCap     | E2 | pass   | —    |   284 | identical to ValueCap (C.4) |
| E2_ApprovalCap     | E2 | revert | —    |   308 | identical to ValueCap |
| E1_TargetAllowlist   | E1 | pass   | cold | 2,557 | dispatch + address strict decode + keccak64 + cold SLOAD (2100) + JUMPI + STOP |
| E1_TargetAllowlist   | E1 | pass   | warm |   557 | same path with warm SLOAD (100) → −2000 vs cold |
| E1_TargetAllowlist   | E1 | revert | cold | 2,583 | pass cold + MSTORE TargetNotAllowed + REVERT (+26) |
| E1_TargetAllowlist   | E1 | revert | warm |   583 | pass warm + revert overhead |
| E1_SelectorAllowlist | E1 | pass   | cold | 2,531 | same shape; bytes4 needs a cheaper ABI cleanup than address (−26) |
| E1_SelectorAllowlist | E1 | pass   | warm |   531 | warm SLOAD path |
| E1_SelectorAllowlist | E1 | revert | cold | 2,557 | pass cold + revert overhead |
| E1_SelectorAllowlist | E1 | revert | warm |   557 | pass warm + revert overhead |

Notes:
- Plan D.2 mentions a 500–2000 range for selector — that assumes a hardcoded
  selector set. We deliberately keep selector as a dynamic mapping, so it pays
  one SLOAD just like target. Target − Selector = 26 across all four paths and
  comes from Solidity's strict `address` ABI decoder (high-12-byte zero check)
  that `bytes4` does not pay.
- All numbers reproducible with `make snap`; `current.snap` is committed
  alongside `gas-results.md` per checkpoint.
