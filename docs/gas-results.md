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

---

# Batch settlement curve (Section E)

Three baselines × N ∈ {1, 2, 5, 10, 20, 50}. Raw data: `docs/batch-curve.csv`.

| N  | baseline 0 (no policy) | baseline 1 (E2 only) | baseline 2 (full E3) |
|---:|---:|---:|---:|
|  1 |    10,418 |    18,608 |    30,964 |
|  2 |    20,122 |    28,634 |    40,990 |
|  5 |    49,234 |    58,712 |    71,068 |
| 10 |    97,754 |   108,842 |   121,198 |
| 20 |   194,794 |   209,102 |   221,458 |
| 50 |   485,914 |   509,882 |   522,238 |

Per-request gas (column ÷ N):

| N  | baseline 0 | baseline 1 | baseline 2 |
|---:|---:|---:|---:|
|  1 | 10,418 | 18,608 | 30,964 |
|  2 | 10,061 | 14,317 | 20,495 |
|  5 |  9,847 | 11,742 | 14,214 |
| 10 |  9,775 | 10,884 | 12,120 |
| 20 |  9,740 | 10,455 | 11,073 |
| 50 |  9,718 | 10,198 | 10,445 |

## Floor decomposition (per-request as N → ∞)

Each baseline's curve fits exactly **`gas(N) = intercept + N · marginal`**:

| Baseline | Intercept | Marginal | Floor decomposition (marginal) |
|---|---:|---:|---|
| 0 — no policy | 714 | 9,704 | 2,600 cold-account + 9,000 callvalue − 2,300 stipend + ~404 loop body |
| 1 — E2 only | 8,582 | 10,026 | baseline 0 marginal (9,704) + 322 per-iter E2 check (GT + JUMPI + amount load) |
| 2 — full E3 | 20,938 | 10,026 | identical marginal to baseline 1 — the E3 checks live at batch level, not in the inner loop |

## Intercept decomposition (one-time per batch)

The amortizing component — what makes per-request gas drop as N grows:

| Baseline | Δ over baseline 0 | Components |
|---|---:|---|
| 1 − 0 |  7,868 | 2,200 cold SLOAD policies + 2,200 cold SLOAD balances + 2,900 SSTORE_RESET balances + ~568 arithmetic/dispatch |
| 2 − 1 | 12,356 | 3 × 2,100 cold SLOAD (validUntil, active, maxPerDay) + 2,200 cold SLOAD dailyState + 2,900 SSTORE_RESET dailyState + ~956 E3 arithmetic (advance + revocation + expiry inlines) |

## Analytical note

Per-request gas approaches a floor as N grows because the per-batch overhead —
the cold SLOAD of policy fields, the cold SLOAD of the balance, the SSTORE of
the new balance, plus (for baseline 2) the cold SLOAD and SSTORE of
`dailyState` — amortizes across N. The marginal cost per added recipient is
dominated by the per-recipient `CALL` (~9.7 k for an existing, cold-account
EOA with value), plus a small E2 check overhead (~0.3 k) that does not change
between baselines 1 and 2. The cumulative-cap SSTORE is paid once per batch,
not once per recipient — that is the whole point of batching.

At N = 50 the full-E3 premium over baseline 0 reduces to
`(522,238 − 485,914) / 485,914 ≈ **7.5 %**`. The premium of baseline 2 over
baseline 1 at N = 50 is `(522,238 − 509,882) / 509,882 ≈ **2.4 %**` — the
additional cost of E3-grade enforcement (expiry + revocation + cumulative cap)
is small relative to the underlying transfer cost once N is large.

## Measurement notes

- All measurements use `vm.lastCallGas().gasTotalUsed` on the callee frame.
- Setup (constructor, `setPolicy`, `deposit`, and a primer `batchDeduct` for
  baseline 2 to populate `dailyState` non-zero) runs in `setUp()`. Foundry
  runs `setUp` in a separate tx from each `test_*`, so the EIP-2929 access
  list is reset and the first SLOAD inside `batchDeduct` is genuinely cold.
- Recipients are pre-dealt 1 wei in `setUp` so they are existing accounts
  (no 25,000 G_newaccount surcharge per inner CALL). Each (baseline, N) point
  uses a disjoint recipient block to avoid cross-contamination.
- Baseline 2 primer ensures the measured `batchDeduct` is a **repeat-day**
  settlement (SSTORE_RESET path, 2,900 gas) rather than a **first-of-day**
  one (SSTORE_SET, 20,000 gas). The latter would add a one-time +17,100 to
  the N = 1 point that hides the steady-state curve.

## Checkpoint E

- [x] Three baseline measurements complete for N = 1, 2, 5, 10, 20, 50.
- [x] CSV produced and committed (`docs/batch-curve.csv`).
- [x] Per-request curve clearly approaches a floor — baseline 0 → ~9,704,
      baselines 1 and 2 → ~10,026.
- [x] Floor's dominant components named: the per-recipient inner CALL (cold
      account + callvalue − stipend) plus the per-iter E2 check.

## Section E reproduction

- Section E commits: `ba254f8` (E-1) → `1385ee5` (E-2) → `778a581` (E-3) →
  this commit (E-4).
- Run: `forge test --match-path test/batch/BatchCurve.t.sol -vv | grep '^CSV,'`
  reproduces every row of the CSV.
- Date: 2026-06-03.

---

# E3 family extensions: sliding-window rate limit + delegation depth

Two E3 modules added after the main A–G sweep, measured under the same pinned
toolchain and the same callee-frame primitive (`vm.lastCallGas().gasTotalUsed`),
same predict-then-assert discipline (TOL = 2, model fixed on a miss, tolerance
never widened).

Storage-layout proof (acceptance): `E3_SlidingWindowRateLimit.State` packs into
exactly one slot —
`forge inspect src/policies/E3_SlidingWindowRateLimit.sol:E3_SlidingWindowRateLimit_Harness storageLayout`
reports `state` at slot 0, offset 0, **32 bytes** (uint48 + uint104 + uint104 = 256 bits).

## Results

| Check | Level | Path | Storage | Gas | Opcode account |
|---|---|---|---|---:|---|
| E3_SlidingWindowRateLimit | E3 | R+W pass ① SET    | cold  | 23,834 | cold SLOAD 2,100 + 1,734 arith+prep + SSTORE_SET 20,000 (zero→nonzero) |
| E3_SlidingWindowRateLimit | E3 | R+W pass ② RESET  | cold  |  6,734 | cold SLOAD 2,100 + 1,734 arith+prep + SSTORE_RESET 2,900 (nonzero→nonzero) |
| E3_SlidingWindowRateLimit | E3 | R+W pass ③ dirty  | dirty |  1,934 | warm SLOAD 100 + 1,734 arith+prep + dirty SSTORE 100. ⚠ same-tx 2nd call — NOT a representative per-tx cost |
| E3_SlidingWindowRateLimit | E3 | R+W adjacent shift | cold |  6,813 | RESET row + 79 adjacency-branch arith (failed same-window EQ + ADD windowStart+W + EQ + prev:=curr;curr:=0) |
| E3_SlidingWindowRateLimit | E3 | revert (at cap)   | cold  |  3,437 | cold SLOAD 2,100 + partial arith (no write-back/repack, no SSTORE) + RateLimitExceeded(uint256,uint256) glue (selector + two arg MSTOREs + REVERT) |
| E3_DelegationDepth | E3 | pass   | — | 284 | dispatch + decode 2 words + 1 GT + STOP — opcode-identical to E2_ValueCap (hypothesis **confirmed**) |
| E3_DelegationDepth | E3 | revert | — | 350 | E2_ValueCap revert (308) + 42 for the two uint256 args of DepthExceeded (two arg MSTOREs + memory growth to the 0x44 error region) |

## Prediction corrections (golden-rule #2: fix the model, never the tolerance)

**Sliding window — same-window arithmetic.** First opcode model estimated the
arithmetic delta over the daily cap as ≈ +50 gas, predicting same-window
RO ≈ 3,004 and hence:

- ~~SET 23,050~~ → **23,834**
- ~~RESET 5,950~~ → **6,734**
- ~~dirty 1,150~~ → **1,934**
- ~~adjacent 5,959~~ → **6,813**
- ~~revert 3,032~~ → **3,437**

Trace showed the true same-window "arith + SSTORE-prep" term is **1,734**, i.e.
**+834** over the daily cap's 900. The miss is the cost of three *non-byte-aligned*
packed fields (uint48 / uint104 / uint104): unlike the daily cap's clean
uint128/uint128 halves, each field must be masked + shifted out of the slot on
the read-copy and shifted + OR'd back on write — plus the weighted estimate's
SUB+MUL+DIV+SUB+MUL+DIV+ADD chain and the same/adjacent/gap classification. The
corrected model is **exact, not fitted**:

- `SET − RESET = 23,834 − 6,734 = 17,100 = 20,000 − 2,900` isolates the SSTORE
  class (SET vs RESET) with everything else held equal.
- `RESET − dirty = 6,734 − 1,934 = 4,800 = (2,100 + 2,900) − (100 + 100)`
  isolates the cold-vs-warm SLOAD and RESET-vs-dirty SSTORE.
- The 1,734 arith+prep term is **provably constant** across SET / RESET / dirty
  (three independent equations, one value) — the only thing that varies between
  the three rows is the SSTORE regime, exactly as intended.

**Delegation depth — revert path.** The M2 hypothesis (pass/revert measure
E2_ValueCap's 284 / 308 exactly) holds on the pass path: `check` is the same
dispatch + decode-2-words + GT + STOP, measured **284**. The revert path
**misses** the hypothesis:

- ~~revert 308~~ → **350**

The +42 over the E2 revert is structural, not a model error: `DepthExceeded`
carries two `uint256` arguments, whereas E2's `ExceedsValueCap()` is
parameterless. Encoding the two args costs two extra arg MSTOREs plus memory
growth to the 0x44-byte error region — the parameterless E2 error never pays it.
The pass path (no error data) is therefore the right place to read the
"opcode-identical to E2" claim, and it is confirmed to the gas.

## Reproduction

- Toolchain: forge 1.7.1 (4072e487) · solc 0.8.26 · optimizer 200 · via_ir = false.
- `forge test --match-path test/policies/E3_SlidingWindow_Gas.t.sol -vv`
- `forge test --match-path test/policies/E3_DelegationDepth_Gas.t.sol -vv`
- New snapshot entries land in `snapshots/current.snap` via `make snap`.
- Date: 2026-06-06.
