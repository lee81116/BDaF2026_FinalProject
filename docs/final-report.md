# Measuring the Enforceability Boundary and Gas Cost of On-Chain Payment Policies for Autonomous Agents

**Final report** · 2026-06-06
**Toolchain (pinned)**: forge 1.7.1 (`4072e487`) · solc 0.8.26 · optimizer 200 · `via_ir = false`
**Status**: Sections A–H complete (+ E3 extensions, adversarial suite, cross-hop closure G′) · host suite 113/113 green · case-study suites 4/4 (Coinbase) and 2/2 (MetaMask) green

---

## Abstract

When an autonomous agent initiates on-chain payments on behalf of an absent human, the human's spending rules live in a smart account. This project asks: **which of those rules can the chain actually enforce, and at what gas cost?** We classify policy expressiveness into three levels (E1 access / E2 transaction / E3 contextual & stateful) and enforcement into three properties (r_rev revocation / r_scope scope, including cross-hop / r_conf semantic honesty), then measure a minimal but realistic escrow with ten policy modules (eight core, plus two E3 extensions added after external review) under a fully pinned toolchain.

Three results. **(1) The enforceable side is cheap and exactly explainable**: every per-check cost is accounted for at the opcode level (largest unexplained residual < 46 gas), and the measured batch-level E3 core — expiry, revocation, cumulative daily cap — adds only **2.4%** over an E2-only baseline at batch size N = 50. **(2) The non-enforceable side is structural, not incidental**: an honest and a malicious settlement can be **byte-identical** at the contract boundary (r_conf), and local per-permission caps allow a two-hop delegation chain to drain **3.5 ether from a 2-ether authorization** without violating any local cap (cross-hop r_scope). **(3) The three production systems we examined align with this boundary, each by a different strategy**: Coinbase Spend Permissions *restricts the call surface* until the hard questions cannot arise; the MetaMask Delegation Framework *pays to walk the chain*, closing the cross-hop gap at a measured **63,396 gas** for a 2-layer redemption; x402 *leaves the chain*, keeping standing-authority enforcement off-chain entirely. None of the three attempts r_conf on-chain.

**Thesis**: under this settlement-boundary model, on-chain mechanisms enforce the chain-observable *ceiling* of a payment policy R(P) — amounts, windows, scope within one hop, revocation. Semantic honesty (r_conf) and, absent root-anchored global state, cross-hop scope (r_scope) break. The smart account replaces the absent human, not the credit card.

---

## 1. Motivation and research question

Autonomous agents that pay for API calls, data, or services need standing payment authority. Two recent systematizations frame this space. Zhang et al. (2026) systematize blockchain agent-to-agent payments as a four-stage lifecycle (discovery → authorization → execution → accounting) and organize the authorization stage along *authorization carriers* × *policy expressiveness* — naming, but not measuring, risks such as "misuse under valid authorization" and valid-transaction sequences that violate intended spending boundaries. Shi et al. (2025) systematize LLM-agent security as a Belief–Intention–Permission lifecycle and find that existing defenses cluster at the belief/intent stages while the *permission* (authorization) boundary remains under-examined. Both classify; **neither quantifies** what enforcement costs on-chain or demonstrates experimentally where it structurally fails. This project supplies that measurement axis:

> On a minimal but realistic escrow, measure the per-check on-chain cost of E1/E2/E3 policy checks, determine how batching amortizes that cost, demonstrate experimentally which enforcement properties cannot hold, and anchor the resulting boundary against production systems.

The framing assumption, used as a consistency check throughout: **the smart account replaces the absent human, not the credit card**. The contract must self-enforce at decision time, with no human in the loop and no ex-post reconciliation.

**Scope.** This is a measurement of the payment-*authorization* boundary at the on-chain policy layer — a study of blast radius, not decision quality. It does not address agent belief/intention correctness, service-quality verification, fraud detection, dispute resolution, or adoption economics; and it does not claim that policies *should* live on-chain — §7.3 documents a production system rationally choosing the opposite. The question is narrower and prior to all of those: what can the chain hold when asked to be the last line, and at what price. The mechanisms studied are delegated-spending generic; the agent setting is where their assumptions become the default rather than the exception — no human reviews statements at machine speed, payment frequency makes per-check and batch costs first-order, and counterparties are discovered programmatically rather than vetted.

## 2. Conceptual framework

Two axes form a grid:

| Axis | Levels |
|---|---|
| **Expressiveness** | E1 access (who/what may be called) · E2 transaction (per-call amount ceilings) · E3 contextual & stateful (expiry, revocation, cumulative windows) |
| **Enforcement** | r_rev (revocability) · r_scope (scope, single-hop and **cross-hop** through redelegation) · r_conf (semantic honesty — does the on-chain settlement reflect the off-chain truth?) |

The expressiveness levels follow Zhang et al.'s (2026) policy-expressiveness dimension (their E1 access-level / E2 transaction-level / E3 contextual-and-stateful, §4.2) verbatim, so our measurements plug directly into their taxonomy. The enforcement axis adopts the risk decomposition of Shi et al.'s (2025) B-I-P framework — `R_P = max(r_conf, r_rev, r_scope)`, their eq. (5), §3.5 "Stage III: Permission Grant" — and **re-instantiates it at the on-chain settlement boundary**, which is this project's contribution: r_rev becomes revocability of standing payment authority (B-I-P: operational irreversibility), r_scope becomes blast radius including cross-hop delegation (B-I-P: cascade scope), and r_conf is narrowed to the slice visible at the settlement boundary — semantic honesty of what is billed (B-I-P's confidentiality/intent-fidelity reading stays out of scope, with the same conclusion: not locally observable on-chain). Zhang et al.'s §5.2 describes the corresponding risks in prose (reactive revocation; valid-sequence boundary violations; "authorization validates transactions but assumes transaction generation is trustworthy"); this project turns each into a property that can be tested and priced.

**Definitions.** *Enforceable* here means: the contract reverts every transaction that violates a policy predicate, where the predicate is computable at execution time purely from on-chain-observable inputs — calldata, `msg` context, block context, and contract state. Enforcement is therefore a runtime-checked invariant over transaction features, not a static security property of the agent. The *ceiling* of a policy P is formalizable as the strongest sub-predicate of P that factors through this observable projection: writing the intended policy as Π(tx, world) and the chain-checkable part as π(tx, σ), the ceiling is the maximal π implied by Π — maximal with respect to logical strength (π₁ ≥ π₂ iff π₁ ⇒ π₂ over the observable projection); in plain terms, among all predicates computable from on-chain observables, the strongest one still implied by the intended off-chain policy. Three tiers must be kept distinct throughout: **(i) on-chain enforceable** — π is checkable and checked; **(ii) locally self-verifiable** — the contract can evaluate the predicate without trusting any external claim (what r_conf fails, §6.1); **(iii) enforceable with imported truth** — the predicate becomes checkable only after a trusted party (oracle, attester, prover) injects a claim, making enforcement conditional on that party. Our negative results place r_conf outside (ii) for a bare payment primitive; they do not claim it is outside (iii).

The thesis was committed before measurement, as four falsifiable predictions (recorded in the project proposal):

- **P1.** Checks expressible over on-chain-observable transaction features (E1/E2, single-hop E3) are enforceable, and their cost is small and exactly attributable.
- **P2.** Cross-hop r_scope breaks under local-only state: per-hop caps do not compose into a global bound.
- **P3.** r_conf is not locally self-verifiable: no on-chain rule can act on a difference that never reaches the contract's input.
- **P4.** Deployed systems already behave as if this boundary exists — concentrating on-chain enforcement inside it and routing the rest off-chain.

Sections A–E build and price the cells that hold (P1). Sections F–G demonstrate the two cells that break (P2, P3). Section H checks the resulting picture against production systems (P4). The conclusion (§12) returns a verdict on each prediction.

## 3. System under measurement

`src/Escrow.sol` is a per-agent ETH escrow with a single-payment `settle(agent, to, amount)` and a batched `batchDeduct(agent, recipients[], amounts[])`. `settle` is deliberately **not** caller-restricted: the contract decides purely on its on-chain-observable input — the property the r_conf demonstration relies on.

Ten policy modules share one factoring: a **`library`** with an internal `check` (inlined into `Escrow`, so integrated opcodes match isolated ones) plus an external **`*_Harness`** wrapper for clean isolated measurement, each with a focused test file under `test/policies/`:

| Level | Modules |
|---|---|
| E1 | `E1_TargetAllowlist`, `E1_SelectorAllowlist` |
| E2 | `E2_ValueCap`, `E2_TokenAmountCap`, `E2_ApprovalCap` |
| E3 (core) | `E3_Expiry`, `E3_Revocation`, `E3_CumulativeDailyCap` |
| E3 (post-review extensions) | `E3_SlidingWindowRateLimit` (two-bucket approximation, not a true sliding log), `E3_DelegationDepth` |

The eight core modules are integrated into `Escrow.settle`/`batchDeduct` (E2 + E3 core; E1 is module-level, §9); the two extensions were added after external review under the same TDD discipline (red-committed behavioral specs before implementation, predicted-then-asserted gas) and are measured in isolation only.

Since C.6 the libraries' errors are canonical: `Escrow.settle`/`batchDeduct` revert with the library errors (`ExceedsValueCap`, `Expired`, `PolicyInactive`, `ExceedsDailyCap`); `Escrow` retains only `NotUser` and `InsufficientBalance`.

## 4. Measurement methodology

**Primitive.** Every per-check number is `vm.lastCallGas().gasTotalUsed` — the **callee-frame** gas of the measured call (helper: `test/policies/GasMeasure.sol`). Calibration showed account-cold and account-warm report the same value, so the primitive excludes caller-side `CALL` base cost and EIP-2929 cold-*account* surcharges; cold-vs-warm *storage* remains visible and is controlled by call ordering within a transaction. Foundry runs `setUp()` in a separate transaction from each `test_*`, so the first SLOAD inside a measured call is genuinely cold.

**Discipline (predict, then assert).** Each number is first predicted from an opcode model and asserted with `assertApproxEqAbs(measured, PREDICTED, 2)`. Under the pinned toolchain gas is deterministic; a deviation beyond ±2 means the *model* is wrong — the response is to open a trace (`-vvvv`) and fix the model, never to widen the assertion. This separates "the test passes" from "the test asserts what you think".

**Rejected alternative.** `forge --gas-report` Min/Max is not used for stateful checks: it bundles caller-side overhead and mixes cold/warm runs (it once reported a phantom 44,505 for `checkReadWrite` whose true cold value is 23,041).

**The three SSTORE regimes.** A cumulative-cap write costs radically different amounts depending on storage state, and conflating them corrupts conclusions:

| Regime | Meaning | Gas (SSTORE component) |
|---|---|---:|
| ① SET (zero→nonzero) | first settlement of the day | ~20,000 |
| ② RESET (nonzero→nonzero, cross-tx) | repeat-day settlement — the realistic steady state | ~2,900 |
| ③ dirty (same-tx second write) | measurement artifact, **not** a realistic per-tx cost | ~100 |

**Batch hygiene.** Each (baseline, N) point uses a fresh contract (no cross-contamination); recipients are pre-dealt 1 wei (avoids the 25,000 G_newaccount surcharge per inner CALL); a primer batch drives `dailyState` non-zero so the measured settlement takes the RESET path rather than a one-time +17,100 SET that would mask the steady-state curve.

**Measurement-regime summary.** Five kinds of gas numbers appear in this report. They are never summed or differenced across rows of this table:

| Where | Number type | Includes | Excludes | Comparable with |
|---|---|---|---|---|
| §5.1 (Section D + E3 extensions) | callee-frame, `vm.lastCallGas`, host profile | the measured policy-call frame, incl. its storage ops | 21k tx base, caller-side CALL overhead, cold-*account* surcharge | other §5.1 rows; §7.1 callee rows at component level |
| §5.2 (Section E) | callee-frame of the whole batch call | per-recipient inner CALLs + batch-level checks | same as above | other §5.2 baselines/N only |
| §7.1 (Coinbase H3) | callee-frame, `vm.lastCallGas`, **Coinbase profile** (solc 0.8.35) | full `spend()`/`revoke()` body incl. AA transfer chain | same as above | §5.1 via component decomposition only (different toolchain) |
| §7.1 (their `.gas-snapshot`) | whole-test fuzz mean μ (`forge --gas-report` style) | test-harness setup, fuzz variance, caller overhead | nothing isolated | nothing here — orientation only |
| §7.2 (MetaMask H5) | caller-side `gasleft()` delta | call overhead, calldata/memory expansion, full redemption | callee-frame isolation | nothing here — magnitude and mechanism only |

## 5. Results I — the enforceable side and its price

### 5.1 Per-check gas (Section D)

This table reports **all measured paths behind the report's claims** — every number is locked by an `assertApproxEqAbs(measured, predicted, 2)` in the test suite; the per-row opcode accounts live in `docs/gas-results.md`. The checks fall into three cost families.

**(a) Stateless checks** — no storage access, hence no cold/warm split. One comparison each:

| Check | Pass | Revert |
|---|---:|---:|
| E2 ValueCap | 284 | 308 |
| E2 TokenAmountCap | 284 | 308 |
| E2 ApprovalCap | 284 | 308 |
| E3 DelegationDepth | 284 | 350 |

(The three E2 rows being identical is itself asserted. DelegationDepth's pass path confirms the same opcode shape exactly; its revert costs +42 because `DepthExceeded` carries two `uint256` args while the E2 errors are parameterless.)

**(b) Single-SLOAD stateful checks** — one mapping/slot read dominates; cold − warm = 2,000 on every path (the EIP-2929 SLOAD delta):

| Check | Pass cold | Pass warm | Revert cold | Revert warm |
|---|---:|---:|---:|---:|
| E1 TargetAllowlist | 2,557 | 557 | 2,583 | 583 |
| E1 SelectorAllowlist | 2,531 | 531 | 2,557 | 557 |
| E3 Expiry | 2,296 | 296 | 2,326 | 326 |
| E3 Revocation | 2,297 | 297 | 2,327 | 327 |

(Target − Selector = 26 on all four paths — the `address` ABI decoder's high-12-byte zero check that `bytes4` does not pay. Revocation − Expiry = 1 gas: bool sanitization.)

**(c) Single-slot read + write family** — the stateful E3 core. Columns are the three SSTORE regimes (① SET zero→nonzero, first-ever write · ② RESET nonzero→nonzero, cross-tx — the realistic steady state · ③ dirty same-tx second write — a measurement artifact, never a realistic per-tx cost):

| Check | Read-only cold | ① SET | ② RESET | ③ dirty | Adjacent-window shift | Revert (cap) cold |
|---|---:|---:|---:|---:|---:|---:|
| E3 CumulativeDailyCap | 2,954 | 23,000 | 5,900 | 1,100 | n/a | 2,785 |
| E3 SlidingWindowRateLimit (two-bucket approx.) | —¹ | 23,834 | 6,734 | 1,934 | 6,813 | 3,437 |

¹ Not measured as a separate path; the constant-arithmetic identity below pins the same-window arithmetic at 1,734 without a standalone RO assertion.

Four findings worth defending orally:

1. **The three E2 caps cost exactly the same (284/308).** They are one `amount > cap` comparison under different names (native wei, ERC-20 amount, approve allowance). Renaming the semantics does not change the on-chain cost; the equality is itself asserted in the test suite.
2. **Target vs Selector allowlist differ by exactly 26 gas on all four paths.** The source is Solidity's strict ABI decoder for `address` (high-12-byte zero check) that `bytes4` does not pay — a constant attributable to a single decoder behavior.
3. **One SSTORE, 20× spread.** The same cumulative-cap write costs 23,000 / 5,900 / 1,100 gas across regimes ①/②/③. Any "gas cost of a daily cap" claim that does not name its regime is underspecified.
4. **The two stateful families share one cost skeleton.** The sliding-window rate limit (added after the main sweep, two-bucket approximation) lands in the *same* three SSTORE regimes as the cumulative cap — SET 23,834 / RESET 6,734 / dirty 1,934 — with `SET − RESET = 17,100` isolating the SSTORE class exactly and the arithmetic provably constant (1,734) across all three. The richer arithmetic over the daily cap (+834) is fully attributable to its three non-byte-aligned packed fields (uint48/uint104/uint104) and the weighted MUL/DIV chain. And `E3_DelegationDepth` confirms the E2 shape at the gas: its pass path measures **exactly 284** like `E2_ValueCap`; its revert is 350, the +42 being only the two `uint256` args of `DepthExceeded` over E2's parameterless error.

An engineering footnote verified at the bytecode level: under the legacy optimizer (`via_ir = false`), a library `internal` function used by multiple call sites is emitted as a **shared subroutine rather than inlined** (the integrated `ExceedsDailyCap` revert string appears exactly once in the `Escrow` bytecode), so integrated per-check costs carry a small dispatch overhead over the isolated harness numbers.

### 5.2 Batch settlement curve (Section E)

Three baselines — 0: no policy (`src/baselines/PlainBatchTransfer.sol`), 1: E2-only (`src/baselines/Escrow_E2Only.sol`), 2: full E3 (`Escrow.batchDeduct`) — measured at N ∈ {1, 2, 5, 10, 20, 50}. Raw data: `docs/batch-curve.csv` (regenerable by one grep, see §10). Every curve fits **exactly** `gas(N) = intercept + N · marginal`:

Complete measured curve — whole-batch gas, with the per-request equivalent (gas ÷ N) beside it:

| N | B0 total | B0 /req | B1 total | B1 /req | B2 total | B2 /req |
|--:|---:|---:|---:|---:|---:|---:|
| 1 | 10,418 | 10,418 | 18,608 | 18,608 | 30,964 | 30,964 |
| 2 | 20,122 | 10,061 | 28,634 | 14,317 | 40,990 | 20,495 |
| 5 | 49,234 | 9,847 | 58,712 | 11,742 | 71,068 | 14,214 |
| 10 | 97,754 | 9,775 | 108,842 | 10,884 | 121,198 | 12,120 |
| 20 | 194,794 | 9,740 | 209,102 | 10,455 | 221,458 | 11,073 |
| 50 | 485,914 | 9,718 | 509,882 | 10,198 | 522,238 | **10,445** |

The linear fit, exact at every point:

| Baseline | Intercept (once per batch) | Marginal (per recipient) |
|---|---:|---:|
| 0 — no policy | 714 | 9,704 |
| 1 — E2 only | 8,582 | 10,026 |
| 2 — full E3 | 20,938 | **10,026** |

Both coefficients decompose to named EVM costs:

| Coefficient | Decomposition |
|---|---|
| Marginal 9,704 (B0) | 2,600 cold-account access + 9,000 callvalue − 2,300 stipend + ~404 loop body, per recipient `CALL` |
| Marginal 10,026 (B1 = B2) | B0 marginal + 322 per-iteration E2 check (GT + JUMPI + amount load) |
| Intercept Δ (B1 − B0) = 7,868 | 2,200 cold SLOAD `policies` + 2,200 cold SLOAD `balances` + 2,900 SSTORE_RESET `balances` + ~568 arithmetic/dispatch |
| Intercept Δ (B2 − B1) = 12,356 | 3 × 2,100 cold SLOAD (`validUntil`, `active`, `maxPerDay`) + 2,200 cold SLOAD `dailyState` + 2,900 SSTORE_RESET `dailyState` + ~956 E3 arithmetic |

The decisive observation: **baselines 1 and 2 have identical marginals.** All E3 checks (revocation, expiry, cumulative cap) execute at *batch level* — they live entirely in the intercept and never enter the per-recipient loop. Consequently per-request cost falls from 30,964 (N = 1) to **10,445** (N = 50); at N = 50, full E3 costs **+7.5%** over no policy at all, and **+2.4%** over E2-only.

> **Claim 1 (priced ceiling).** The measured batch-level E3 core — expiry + revocation + cumulative daily cap — is effectively free at batch scale: its cost is per-batch, not per-payment, and amortizes to single-digit percent. The two E3 extensions (§5.1 tables a and c) were measured separately and fall into the same stateless / single-slot-stateful cost families, but they are **not** part of the batch curve; extending the curve to them is predictable from the intercept decomposition (one more RESET-class slot per batch) but was not measured.

## 6. Results II — the two structural breaks

### 6.1 r_conf: the byte-identical settlement (Section F)

`test/rconf/CalldataIdentical.t.sol` stages an honest provider (`reportedUsage = 100`) and a malicious one (`reportedUsage = type(uint256).max / 2 ≈ 5.79 × 10⁷⁶`). When each bills the *same* amount, the settlement calldata the agent submits is **bit-identical** — asserted both as `assertEq(honestCalldata, maliciousCalldata)` and as keccak256 equality — and the escrow accepts both on equal footing.

The negation test makes the gap structural rather than incidental: the `settle` surface is exactly 4 selector bytes + 3 × 32-byte words (`agent`, `to`, `amount`) = **100 bytes**, with no field that could carry usage, an attestation, or a receipt. If the contract's entire input cannot differ, no on-chain rule it could contain can act on the difference.

Closing r_conf requires importing the off-chain truth through a trusted channel — oracle, signed attestation, TEE, ZK proof. Each *relocates* trust (to the oracle, signer, chip, prover) rather than removing it. A bare payment primitive cannot decide semantic honesty because the needed information is not in its input. (Figure: `figures/rconf_calldata_identity.svg`.)

**Claim status.** This is an empirical demonstration plus a structural argument scoped to this settlement surface — not a general impossibility theorem. Widening the surface (e.g., adding a `usage` field) does not escape the argument: the contract would then check a *claim* made by an interested party, and binding the claim to truth re-requires a trusted source — which is tier (iii) of §2, with the trust relocated and priced (signature verification, oracle fees, or ZK verification gas), not eliminated.

**Which slice of r_conf this instantiates.** Semantic honesty is not one problem: it decomposes into at least *usage/billing* honesty, *delivery* honesty, *computation-correctness*, *price* honesty, and *intent fidelity*. The experiment instantiates the usage/billing slice. The structural argument — the truth never enters the observable input — is slice-independent, but the appropriate tier-(iii) mechanism differs per slice: signed receipts for delivery, oracles for price, ZK proofs for computation correctness, identity registries for counterparty attribution; response *quality* falls largely outside what any payment layer can adjudicate. Every one of these mechanisms verifies an **artifact**, not the truth itself — the binding of artifact to truth lives with the artifact's issuer, which is exactly the relocation tier (iii) names.

### 6.2 Cross-hop r_scope: the delegation escape (Section G)

`src/delegation/TwoHopDelegation.sol` implements local-only enforcement: every permission tracks its own `spent` against its own cap in its own slot. `test/delegation/CrossHopEscape.t.sol`:

- User grants Agent A a **2-ether** budget from a single funding pool.
- A spends 1.5 ether (≤ 2 — locally legal), then re-delegates a *fresh* 2-ether budget to B.
- B spends 2.0 ether (≤ 2 — locally legal).
- The pool pays out **3.5 ether against a 2-ether authorization**, with assertions confirming *no local cap was ever violated* — the assertion targets the global total drained, not any local state.

A control test shows a single hop cannot exceed its own cap (the third spend reverts), proving the escape is **compositional**: it lives in the gap between local caps and absent global accounting, not in a bug in the local checks. (Figure: `figures/crosshop_escape.svg`.)

That local authority does not compose into global authority is a lesson the capability-security literature learned long ago (attenuation of delegated authority). The contribution here is accordingly **not the principle but its operationalization at this boundary**: a reproducible escape construction with the assertion on the global drain, the isolation of exactly which mechanism is missing (root-anchored accounting — not depth limits, as the next paragraph shows), and, in §7.2, the measured production price of supplying it.

A follow-up module isolates *which* mechanism is missing. `src/delegation/DepthBoundedDelegation.sol` adds a hard delegation-depth bound (`E3_DelegationDepth`, `MAX_DEPTH = 2`) on top of the same local-only enforcement; `test/delegation/DepthBoundEscape.t.sol` shows the bound is real (a depth-3 grant reverts `DepthExceeded`) yet the **exact same 3.5-ether escape replays at legal depth** (User→A→B, both within the bound). The depth bound constrains chain *length*, not *budget* — confirming the missing mechanism is root-anchored accounting, orthogonal to and unaffected by depth limits.

What closing it would require (see also §7.2): every spend must answer a *global* question — either (a) one shared budget object that the root grant creates and every descendant debits, or (b) ancestor traversal decrementing every ancestor's remaining allowance per spend. Both add state and gas scaling with delegation depth; with the measured single-hop cumulative check at ~2,954 read / ~5,900 read+write, option (b) multiplies roughly that per hop.

**The closure, built and measured (Section G′).** We now implement option (b) in our own escrow: `src/delegation/RootAnchoredDelegation.sol` walks the parent chain to the root on every spend and debits each ancestor's root-anchored counter (`test/delegation/RootAnchoredClosure.t.sol`). It replays the exact Section G scenario and **closes it** — A's 1.5 + B's 2.0 hits A's 2-ether root counter and reverts; total drained stays at A's legal 1.5, and the original local-only escape remains demonstrated, unchanged, in `CrossHopEscape.t.sol` (the two coexist). The cost is measured callee-frame with the same predict-then-assert-±2 discipline (§5.1): the **per-hop closure increment is 9,625 gas, constant across depth** (depth 1/2/3 = 26,001 / 35,626 / 45,251; d2−d1 = d3−d2 = 9,625 — the O(depth) law). That increment decomposes into ~5,000 for the counter R+W (the E3 RESET class) plus ~4,200 for the two cold `Permission` SLOADs needed to traverse one hop. **Cross-hop r_scope is therefore host-measured as enforceable on-chain at O(depth) root-anchored state, ~9,625 gas/hop — comparable to the E3 RESET regime: the boundary is priced, not impassable.** This does not weaken P2; it completes it — the break was always specific to *local-only* state, and the price of *root-anchored* state is now a number in our own system.

> **Claim 2 (the breaks).** r_conf fails by construction at the calldata boundary; cross-hop r_scope fails under local-only state. r_conf is *impassable*; cross-hop is the *priced* break — closed at ~9,625 gas/hop of root-anchored state (Section G′). Both are missing-mechanism problems, not implementation bugs.

## 7. Results III — the boundary against production systems (Section H)

Two audited production systems, vendored at pinned commits with their own toolchains (never merged into ours), each deployed locally in Foundry — no mainnet fork:

| System | Pin | Role in the argument |
|---|---|---|
| Coinbase Spend Permissions | v1.0.0 @ `54e99c7e` (deployed `SpendPermissionManager = 0xf85210B2…dC9b67Ad` on 8 chains) | A system that *occupies the enforceable ceiling* and avoids both gaps |
| MetaMask Delegation Framework | v1.3.0 @ `bfbdf979` (ERC-7710 redelegation + caveat enforcers) | The one candidate that *offers redelegation*, so it must answer the cross-hop question |

Evidence dossiers with every file:line: `docs/case-study-coinbase.md`, `docs/case-study-metamask.md`; synthesis: `docs/case-study.md`; overlay figure: `figures/casestudy_mapping.svg`.

### 7.1 Coinbase: the ceiling, occupied deliberately

Structure (H2): a `SpendPermission` is account → spender, **one hop**. No arbitrary-call surface exists — `spend()` takes only `(SpendPermission, uint160 value)`; the E2/E3 core is a cumulative `allowance` per rolling `period` (direct analog of our `E3_CumulativeDailyCap`, generalized from 1 day to any period); r_rev is a one-bit `_isRevoked[hash]` checked on every spend. **Cross-hop never arises because redelegation is not implemented.** **r_conf is explicitly out of scope**: of the struct's nine fields, eight are syntactic; the ninth (`extraData`) is hashed for integrity but never read or constrained on-chain.

Gas (H3, our callee-frame tests under Coinbase's own profile, solc pinned 0.8.35, asserted ±2):

| Coinbase call | Regime | Gas | Host analog (Section D) |
|---|---|---:|---|
| `spend()` native, first ever | ① SET | **64,821** | CumulativeDailyCap R+W ① = 23,000 |
| `spend()` native, cross-tx repeat | ② RESET | **46,537** | R+W ② = 5,900 |
| `spend()` native, same-tx second | ③ dirty | **33,237** | R+W ③ = 1,100 |
| `revoke()` by account | SET | **33,545** | SSTORE SET class ≈ 23,000 |

Decomposition (H3.3): the regime-① total splits into ~6.5–7k of policy checks (reconciling with the matching Section D rows), ~22.5k of state SSTORE, and ~34k of **account-abstraction transfer chain** (`account.execute` → `receive()` → `safeTransferETH` — three external calls). Once the AA chain is stripped, the residual reconciles with the host opcode model to within ~15% — a **qualitative component reconciliation, not an asserted opcode-equivalence claim**: the residual is expected because the toolchain (solc 0.8.35 vs 0.8.26) and the surrounding call path differ, and it is held to a different standard than the ±2 assertions of §5.

For orientation only, Coinbase's own committed `.gas-snapshot` (their methodology: `forge --gas-report`-style whole-test gas, fuzz mean μ over 256 runs — **not comparable to any callee-frame number above**, per §4):

| Their test | μ gas |
|---|---:|
| `test_spend_success_ether` (first spend, fresh period) | 199,163 |
| `test_spend_success_ether_alreadyInitialized` (repeat, same period) | 172,602 |
| `test_spend_success_ERC20ReturnsTrue` | 186,880 |
| `test_revoke_success_isNoLongerAuthorized` | 87,261 |

> **Claim 3a.** Production-grade enforceability is not a gas problem at the policy layer: Coinbase's policy logic costs about what our minimal escrow's does; the premium pays for ERC-4337/smart-wallet infrastructure.

### 7.2 MetaMask: cross-hop closed, and what it costs

Source walk (H5.1): `DelegationManager.redeemDelegations` fires **every caveat on every delegation in the chain** (beforeAll/before/after/afterAll hooks), and execution runs against the **root delegator's account**. State key (H5.2): every cumulative enforcer keys state as `spentMap[msg.sender][delegationHash]`, and only the manager calls the hooks — so the effective key is the delegation hash, which is **identical** whether User→A is redeemed directly by A or as the parent inside B's chain `[A→B, User→A]`.

Behavioral tests (`casestudy/metamask/test/h5-crosshop/CrossHopEnforcement.t.sol`, 2 PASS) replicate Section G's exact scenario inside the production framework:

| Test | Outcome |
|---|---|
| A spends 1.5 of a 2-ether root cap; B attempts 1.0 through the chain (total 2.5) | **Reverts** `allowance-exceeded`; counter and pool unchanged — the Section G escape does not survive |
| A 1.5 + B 0.5 (exactly cap); then either party attempts 1 wei more | First two succeed, both follow-ups revert — one shared counter, exactly enforced. B's 2-layer redemption: **63,396 gas** (caller-side `gasleft`; asserted ±2; not summable with callee-frame rows) |

The closure matches the mechanism our Section G analysis said would be necessary: a counter anchored to the root delegation that every redemption path debits. **This is now production confirmation of a result we also have host-side**: Section G′ (§6.2) implements the same root-anchored ancestor walk in our own escrow and prices it at **9,625 gas/hop callee-frame**. The two numbers are *not* directly comparable in magnitude — MetaMask's 63,396 is caller-side `gasleft` for a full 2-layer redemption through the production DeleGator/4337 stack, while ours is the isolated callee-frame increment of the closure mechanism itself — but they agree on the shape: cross-hop enforcement costs O(depth) root-anchored state, and that state is the thing that closes the escape. Caveat (H5.6): the guarantee is keyed to the delegation hash — issuing a second User→A delegation with a different `salt` creates a fresh counter and re-opens the escape; the root principal must treat each issued hash as the budget.

**Coverage note (post-extension).** The two E3 modules added after the H sweep have no enforcer analog in the framework: the period enforcers are fixed-window (no sliding weighting), and no enforcer bounds delegation depth — nor could one, since the v1.3.0 `beforeHook` interface never exposes an enforcer's position in (or the length of) the chain. Conversely, our `DepthBoundedDelegation` experiment shows a depth bound would not have substituted for the hash-keyed shared counter anyway: the budget escape replays at legal depth (§6.2). Full reading: `docs/case-study-metamask.md` §H4.5.

> **Claim 3b.** Cross-hop r_scope *is* on-chain-enforceable, but only by paying for chain-walked, root-anchored state — measured at ~63k gas for two layers in a production framework. Coinbase avoids the question; MetaMask pays it. **Neither system attempts r_conf**, confirming Section F's conclusion from the production side.

### 7.3 The third strategy: x402 leaves the chain (structural reading — discussion-grade evidence, not a measured case study)

x402 — a prominent Coinbase/Cloudflare HTTP-402 standard for agentic payments — was surveyed during target selection and deliberately *not* vendored, because it has almost no on-chain policy surface to measure: per-request payments are signed EIP-3009 `transferWithAuthorization` payloads settled by a facilitator, and every standing-authority policy (budgets, counterparty rules, rate limits) lives client-side or facilitator-side, off-chain. Read structurally against the grid (protocol-spec reading, not vendored tests): the on-chain remainder is an exact per-payment amount (E2, enforced by the token contract), a validity window (E3-time), a one-shot nonce, and `cancelAuthorization` (r_rev). Cumulative state, delegation, and r_conf simply do not exist on-chain.

This is not a vendored measurement point; it is a structural contrast that exhibits the third placement strategy. Where Coinbase *restricts the surface* and MetaMask *pays to walk the chain*, x402 *exits the chain*: it relocates R(P) enforcement to an off-chain trust point, which is exactly the trade our framework predicts when on-chain enforcement is either impossible (r_conf) or priced (stateful policy). Source: the x402 specification and launch documentation (https://github.com/coinbase/x402; https://www.coinbase.com/developer-platform/discover/launches/x402).

### 7.4 The filled gradient

| System | E1 | E2 | E3 | r_rev | r_scope (cross-hop) | r_conf | Strategy |
|---|---|---|---|---|---|---|---|
| **Host** (this project) | ✓ allowlists | ✓ three caps | ✓ expiry + revocation + daily cap | ✓ | ✗ Section G escape | ✗ Section F | measure the boundary |
| **Coinbase v1.0.0** | △ token-only surface | ✓ allowance | ✓ period rollover | ✓ | n/a — no redelegation | ✗ `extraData` opaque | restrict the surface |
| **MetaMask v1.3.0** | ✓ targets/methods/calldata | ✓ `ValueLte` + cumulative family | ✓ period + time enforcers | ✓ | **✓ at 63,396 gas (2 layers)** | ✗ no enforcer addresses it | pay to walk the chain |
| **x402** (spec reading) | ✗ no call surface | ✓ exact amount (token contract) | △ validity window only | ✓ `cancelAuthorization` | n/a — no delegation | ✗ | leave the chain |

Evidence basis differs by row and is marked accordingly: Host, Coinbase, and MetaMask rows rest on vendored source plus passing tests; the x402 row is a structural reading of the protocol specification (§7.3).

## 8. Threat model

What the measured policy layer actually buys, stated as threats. Every "mitigated" row points at a passing test; every "not mitigated" row points at a demonstration or a structural argument — no row rests on intention.

**Mitigated on-chain:**

| Threat | Mechanism | Evidence |
|---|---|---|
| Settlement exceeds per-request cap | `E2_ValueCap` revert (308 gas) | `test/policies/E2_ValueCap.t.sol` |
| Cumulative spend exceeds daily budget | `E3_CumulativeDailyCap` revert (2,785 cold) | `test/policies/E3_CumulativeDailyCap.t.sol` |
| Spend under expired authority | `E3_Expiry` revert | `test/policies/E3_Expiry.t.sol` |
| Spend under revoked authority | `E3_Revocation` revert | `test/policies/E3_Revocation.t.sol` |
| Call to disallowed target / selector | E1 allowlists (module-level) | `test/policies/E1_*.t.sol` |
| Cross-hop overspend, **given root-anchored state** | chain-walked caveats + hash-keyed counter | MetaMask H5 tests (§7.2) |
| Replay of a settlement | **bounded, not prevented** — no per-settlement nonce exists; repeated valid settlements are capped by the per-request and cumulative ceilings | T2 (§8.1); §5.1 caps |
| Reentrant drain of the pool | **bounded by the cap** — `settle` commits state before the external call (CEI), so a reentrant `settle` reverts `ExceedsDailyCap` | T1 (§8.1); SWC-107 |

**Not mitigated on-chain (and cannot be, locally):**

| Threat | Why it remains | Evidence |
|---|---|---|
| Provider over-reports usage / bills dishonestly | the difference never reaches calldata | §6.1 byte-identical demonstration |
| Service not delivered / response useless | delivery is off-chain | §6.1 negation argument |
| Prompt-injected agent spends *within* its caps | the chain sees R(P), never T(B, I) | framework (§2); Shi et al. (2025) |
| Economically bad but policy-valid transaction | the contract checks shape, not wisdom | §6.1 |
| Cross-hop overspend under local-only state | no global accounting exists | §6.2 escape |
| Payload confidentiality | semantic property, out of settlement scope | scope note (§2) |

The first table is the priced ceiling; the second is the residue that must be bought with off-chain trust (oracle, attestation, TEE, ZK — each a relocation, not a removal).

### 8.1 Adversarial tests — prose rows made executable

Four tests in `test/adversarial/AttackVectors.t.sol` turn the threat-model rows above into running demonstrations, each tagged with its literature source (Zhang et al. 2026 §5.2 or SWC-107). Full coverage map: `docs/threat-coverage.md`.

| # | Attack | Source | Result |
|---|---|---|---|
| T1 | Reentrancy on `settle` | SWC-107 | **Bounded by the cap.** Checks-effects-interactions commits `dailyState`/`balances` before the external call, so the reentrant `settle` sees `spent == cap` and reverts; the recipient receives exactly 1 ether, never a second. No explicit reentrancy guard is needed. |
| T2 | Repetition / replay | Zhang §5.2 "repetition" | **Bounded, not prevented.** No per-settlement nonce, so five identical calls are not duplicate-rejected; the daily cap admits the first three and reverts the 4th/5th. The cap is a ceiling, not a uniqueness guarantee. |
| T3 | Fragmentation | Zhang §5.2 "fragmentation" | **Bounded only by the E3 cap.** Six sub-per-request-cap spends (0.5 ether each) reach exactly the 3-ether cumulative cap; the 7th reverts. A per-request (E2) cap alone would let fragmentation run unbounded — this is the affirmative case for why the cumulative cap is load-bearing. |
| T4 | Timing manipulation | Zhang §5.2 "timing manipulation" | **Attack succeeds (negative result).** The fixed-window `CumulativeDailyCap` admits 2× the daily cap within ~2 seconds across a day boundary. The count-based sliding window does not close this *value* burst. See limitation 9 below. |

## 9. Limitations

1. **Callee-frame ≠ end-to-end.** Numbers exclude the 21,000 transaction base and caller-side CALL overhead; they price the policy check increment, not the wallet-visible total.
2. **E1 allowlists are measured in isolation only.** `settle(agent, to, amount)` has no target/selector dimension, so C.6 integrated E2+E3 only; E1 numbers are module-level.
3. **The escrow is ETH-only.** Token/approval caps are measured as pure checks, not inside a real ERC-20 transfer path.
4. **Cross-hop closure is built and measured in a dedicated host contract, not integrated into `Escrow.settle`.** `RootAnchoredDelegation` (Section G′, §6.2) implements and prices the root-anchored ancestor walk host-side (9,625 gas/hop callee-frame); it is a standalone demonstration contract (like `TwoHopDelegation`), not wired into the main escrow's settle path, and it does not reproduce MetaMask's full production redemption (its 63,396 is caller-side, §7.2 — compared by shape, not magnitude).
5. **The MetaMask 63,396 figure is caller-side** (their forge-std pin predates `vm.lastCallGas`) and must not be summed with callee-frame rows; the H5 tests use a minimal `MockDelegator`, not the production DeleGator signature/4337 paths (orthogonal to the chain-enforcement question, but a scope boundary).
6. **r_conf is demonstrated for a bare payment primitive.** Systems that *import* off-chain truth (oracles, attestations, TEEs, ZK) can move the boundary at the price of relocated trust — measured here only as an argument, not an implementation.
7. **The sliding-window rate limit is measured as a two-bucket approximation, not a true sliding log.** `E3_SlidingWindowRateLimit` is now implemented and measured (§5.1): the count-based two-bucket approximation packs into one slot and lands in the same three SSTORE regimes as the cumulative cap. A *true* sliding log — one that remembers each event's timestamp — is O(events) storage slots, whose cost is bounded analytically (one cold SLOAD + one SSTORE per retained event), not measured here; the two-bucket form is the standard production trade of exactness for a single slot. Delegation-depth bounds are likewise now implemented and measured (`E3_DelegationDepth`, §5.1) and, via `DepthBoundedDelegation`, shown to constrain chain length without closing the budget escape (§6.2). Host-side cross-hop *closure* is now implemented and measured too (`RootAnchoredDelegation`, Section G′ / §6.2): root-anchored ancestor traversal closes the escape at **9,625 gas/hop callee-frame**, a number directly comparable to the E3 RESET regime. The only sliding-window form left unimplemented is a *value*-based one (limitation 9, the fixed-window reset burst); the *count*-based sliding window and the cross-hop closure are both done.
8. **Absolute gas numbers are toolchain-specific.** Under `via_ir = true` (or a different solc/optimizer), codegen changes and every absolute number shifts — which is exactly why the toolchain is pinned and treated as part of the experiment's identity. The *structural* findings (the three SSTORE regimes, exact linearity of the batch curve, equal marginals between baselines 1 and 2, the E2 equality) are expected to survive a toolchain change, but this was not re-verified under the IR pipeline.
9. **The cumulative cap is a fixed window, vulnerable to a reset burst (value dimension).** Adversarial test T4 (§8.1) drains 2× the daily cap within ~2 seconds across the `block.timestamp / 1 days` boundary — the canonical "timing manipulation" attack (Zhang et al. 2026 §5.2). `E3_SlidingWindowRateLimit` mitigates this for the request-*rate* (count) dimension, but it is count-based, not value-based; a sliding-window *value* cap was not implemented, so the value burst is a real, demonstrated limitation of the fixed-window `CumulativeDailyCap`, not a toolchain artifact.

## 10. Reproducibility

Everything is deterministic under the pinned toolchain; gas numbers reproduce exactly cross-platform (independently re-run on Linux during review — all asserted values matched to the digit).

```sh
forge --version    # must be 1.7.1 (4072e487)
forge test         # host: 113 passed / 0 failed
make snap-check    # 0 drift vs snapshots/current.snap (baseline.snap is the phase-1 record, never overwritten)

# Section E curve, regenerated row-by-row:
forge test --match-path test/batch/BatchCurve.t.sol -vv | grep '^CSV,'

# Case studies (own toolchains, vendored pins in casestudy/*/VERSION.md):
cd casestudy/coinbase  && forge test --match-path "test/h3-gas/*" -vv      # 4 PASS, numbers printed + asserted ±2
cd casestudy/metamask  && forge test --match-path "test/h5-crosshop/*" -vv # 2 PASS, 63,396 asserted ±2
```

Vendoring rules: each system lives under `casestudy/<system>/` with its own `foundry.toml`; upstream settings are never merged into the host profile; `VERSION.md` records repo, tag, commit, submodule pins, deployed address, and the two documented local patches (magic-spend URL rename; Coinbase solc pinned to 0.8.35 — the version both recorded runs resolved — so H3 numbers cannot drift silently).

## 11. Repository map and history

```
src/       Escrow.sol · policies/ (10 modules) · baselines/ (E) · mocks/ (F, + ReentrantRecipient) · delegation/ (G: TwoHopDelegation + DepthBoundedDelegation + RootAnchoredDelegation [G′])
test/      policies/ (D) · batch/ (E) · rconf/ (F) · delegation/ (G + G′ closure) · adversarial/ (§8.1) · BaseTest.sol
casestudy/ coinbase/ (H2–H3) · metamask/ (H4–H5), each pinned via VERSION.md
docs/      gas-results.md (D+E) · batch-curve.csv ·
           case-study{,-coinbase,-metamask}.md (H) · figures/*.svg · final-report.md
snapshots/ baseline.snap (frozen) · current.snap (live)
```

Sections and merges: A–B (`9895070`) → C (`f0591e9`, 8 modules + integration) → D (`35d8502`…`bbf0e30`, per-check gas) → E (`ba254f8`…`6ef265c`, batch curve) → F (`6e388d9`, r_conf) → G (`edab10d`, cross-hop escape) → H (`7fbab9f` → `119abbf` → `53b58e4` → `11a9d14`, case studies; merged via PR #2) → H9 post-review fixes (`23bb900`, PR #3: locked case-study gas assertions, Coinbase solc pin, doc reference cleanup) → E3 extensions post-review (`60e7fdf` → `8d311e8`, PR #4: `E3_SlidingWindowRateLimit`, `E3_DelegationDepth`, `DepthBoundedDelegation` under a red→green→measure TDD trail, plus fail-closed tests for malformed window parameters; host suite expanded 78 → 102 tests) → adversarial suite (`875c487` → `9780407`, PR #5: reentrancy/replay/fragmentation/timing tests turning threat-model rows into executable demonstrations; host suite 102 → 106 tests) → cross-hop closure G′ (`3af3d72` → `d7b9a36`, PR #6: `RootAnchoredDelegation` root-anchored ancestor traversal under a red→green→measure TDD trail; per-hop closure measured at 9,625 gas; host suite 106 → 113 tests).

## 12. Conclusion

The verdict on the four predictions committed in §2:

| Prediction | Verdict | Decisive evidence |
|---|---|---|
| **P1** — the expressible ceiling is enforceable, cheaply and attributably | **Held** | every per-check number opcode-accounted (residual < 46 gas); the batch-level E3 core's premium amortizes to 2.4% at N = 50 (§5) |
| **P2** — cross-hop r_scope breaks under local-only state | **Held, and now priced host-side** | 3.5 ether drained from a 2-ether authorization, no local cap violated, control test passes (§6.2) — and the closure is built and measured in our own escrow: **9,625 gas/hop** callee-frame for root-anchored ancestor traversal (Section G′), with production confirmation at 63,396 gas in MetaMask (§7.2). The break is specific to *local-only* state; with *root-anchored* state cross-hop is enforceable at O(depth) — priced, not impassable |
| **P3** — r_conf is not locally self-verifiable | **Held, by construction** | honest and malicious settlements byte-identical; the 100-byte surface has no field for truth (§6.1); none of the three production systems attempts it (§7) |
| **P4** — deployed systems already respect the boundary | **Held, with a refinement** | not one pattern but three strategies: restrict the surface (Coinbase), pay to walk the chain (MetaMask), leave the chain (x402) — all converging on the same r_conf wall (§7) |

What this buys a designer is a **placement rule**: put a policy on-chain iff its predicate factors through the observable projection (tiers i–ii of §2) *and* its storage cost fits the regimes priced in §5.1; if the predicate needs off-chain truth (tier iii), the real cost is the imported-truth mechanism and its trust relocation, not the gas. Three anti-patterns fall out of the same grid: a fresh `salt` silently splits a budget counter into two (§7.2); a depth bound is not a budget bound (§6.2); and any stateful gas claim that does not name its SSTORE regime is underspecified (§4). What gas numbers do *not* decide is adoption — the 2.4% figure removes "policy checks are too expensive" as an objection; it does not claim gas was the binding constraint.

The project set out to measure a boundary and ended up pricing both of its sides. Inside the boundary, enforcement is cheap, linear, and explainable to the opcode: three identical 284-gas caps, a 26-gas decoder constant, a 20× SSTORE spread that careful methodology must name, and a batch-level E3-core premium that amortizes to 2.4% at batch scale. Outside it, the failures are structural: a 100-byte settlement surface that cannot carry truth, and local counters that cannot see a delegation tree. Production systems trace the same line from three directions — restricting the surface until the hard questions vanish, paying ~63k gas to walk the chain and anchor state at the root, or leaving the chain entirely — and **all of them leave semantic honesty to the off-chain world**. On-chain payment policy enforces the chain-observable ceiling of R(P); without imported truth, it cannot locally verify the truth beneath it.

## References

Shi, G., Du, H., Wang, Z., Liang, X., Liu, W., Bian, S., & Guan, Z. (2025). *SoK: Trust-authorization mismatch in LLM agent interactions* (arXiv:2512.06914). arXiv. https://doi.org/10.48550/arXiv.2512.06914

Zhang, Y., Xiang, Y., Lei, Y., Wang, Q., Qiu, T., Sun, Y., Zarkov, S., Yuen, T. H., Deppeler, A., Yu, J., & Lam, K.-Y. (2026). *SoK: Blockchain agent-to-agent payments* (arXiv:2604.03733). arXiv. https://doi.org/10.48550/arXiv.2604.03733
