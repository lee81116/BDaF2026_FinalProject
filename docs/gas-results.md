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
| E3_Expiry            | E3 | pass   | cold | 2,296 | dispatch + cold SLOAD slot0 (2100) + TIMESTAMP + GT + JUMPI + STOP |
| E3_Expiry            | E3 | pass   | warm |   296 | warm SLOAD (100) on same slot |
| E3_Expiry            | E3 | revert | cold | 2,326 | pass cold + MSTORE Expired + REVERT (+30) |
| E3_Expiry            | E3 | revert | warm |   326 | pass warm + revert overhead |
| E3_Revocation        | E3 | pass   | cold | 2,297 | dispatch + cold SLOAD + bool sanitization (+1) + ISZERO + JUMPI |
| E3_Revocation        | E3 | pass   | warm |   297 | warm SLOAD on same slot |
| E3_Revocation        | E3 | revert | cold | 2,327 | pass cold + MSTORE PolicyInactive + REVERT (+30) |
| E3_Revocation        | E3 | revert | warm |   327 | pass warm + revert overhead |
| E3_CumulativeDailyCap | E3 | RO  pass     | cold | 2,954 | cold SLOAD packed slot (2100) + 854 arith (decode + unpack + DIV + add + cap cmp) |
| E3_CumulativeDailyCap | E3 | R+W pass ①   | cold | 23,000 | RO baseline + SSTORE_SET 20000 (zero→nonzero, fresh slot) + 46 prep |
| E3_CumulativeDailyCap | E3 | R+W pass ②   | cold | 5,900 | RO baseline + SSTORE_RESET 2900 (post-EIP-3529, nonzero→nonzero) + 46 prep |
| E3_CumulativeDailyCap | E3 | R+W pass ③   | dirty | 1,100 | warm SLOAD (100) + 854 arith + dirty SSTORE (100) + 46. ⚠ same-tx 2nd call — NOT a representative per-tx cost |
| E3_CumulativeDailyCap | E3 | revert (cap) | cold | 2,785 | cold SLOAD + 685 partial arith + revert glue (no SSTORE; advance reverts before harness write) |

Notes:
- Plan D.2 mentions a 500–2000 range for selector — that assumes a hardcoded
  selector set. We deliberately keep selector as a dynamic mapping, so it pays
  one SLOAD just like target. Target − Selector = 26 across all four paths and
  comes from Solidity's strict `address` ABI decoder (high-12-byte zero check)
  that `bytes4` does not pay.
- All numbers reproducible with `make snap`; `current.snap` is committed
  alongside `gas-results.md` per checkpoint.

## Checkpoint D

- [x] All eight policy modules have measured pass and revert gas
  - E2: ValueCap, TokenAmountCap, ApprovalCap (3 × pass/revert)
  - E1: TargetAllowlist, SelectorAllowlist (2 × pass/revert)
  - E3: Expiry, Revocation, CumulativeDailyCap (3 × pass/revert)
- [x] Stateful checks have both cold and warm numbers
  - E1 × 2: cold + warm (pass and revert)
  - E3 Expiry, Revocation: cold + warm (pass and revert)
  - E3 CumulativeDailyCap: cold RO + three SSTORE classes (SET, RESET, dirty)
- [x] Every number explained to within ~100 gas
  - Each row's "Opcode account" column accounts for the gas at the EVM-cost
    level. The largest unexplained residual is ~46 gas (SSTORE prep glue in
    the cumulative-cap RW paths) — well under 100.
- [x] `docs/gas-results.md` exists and is sortable
  - Single Markdown table, columns: Check | Level | Path | Storage | Gas |
    Opcode account. Sorts by any column.

## Reproduction

- Toolchain: forge 1.7.1 (4072e487) · solc 0.8.26 · optimizer 200 · via_ir = false.
- Snapshot of these numbers: `snapshots/current.snap`.
- Section D commits (in order): `35d8502` (D-1/D-2) → `8c87e1b` (D-3) →
  `92bf9be` (D-4) → `d24e893` (D-5). This file finalized at commit recorded
  by the D-6 wrap-up commit.
- Date: 2026-06-03.
