# Measuring the Enforceability Boundary and Gas Cost of On-Chain Payment Policies for Autonomous Agents

**Final report** · 2026-06-06
**Toolchain (pinned)**: forge 1.7.1 (`4072e487`) · solc 0.8.26 · optimizer 200 · `via_ir = false`
**Status**: Sections A–H complete (+ E3 extensions) · host suite 100/100 green · case-study suites 4/4 (Coinbase) and 2/2 (MetaMask) green

---

## Abstract

When an autonomous agent initiates on-chain payments on behalf of an absent human, the human's spending rules live in a smart account. This project asks: **which of those rules can the chain actually enforce, and at what gas cost?** We classify policy expressiveness into three levels (E1 access / E2 transaction / E3 contextual & stateful) and enforcement into three properties (r_rev revocation / r_scope scope, including cross-hop / r_conf semantic honesty), then measure a minimal but realistic escrow with eight policy modules under a fully pinned toolchain.

Three results. **(1) The enforceable side is cheap and exactly explainable**: every per-check cost is accounted for at the opcode level (largest unexplained residual < 46 gas), and full E3-grade enforcement adds only **2.4%** over an E2-only baseline at batch size N = 50. **(2) The non-enforceable side is structural, not incidental**: an honest and a malicious settlement can be **byte-identical** at the contract boundary (r_conf), and local per-permission caps allow a two-hop delegation chain to drain **3.5 ether from a 2-ether authorization** without violating any local cap (cross-hop r_scope). **(3) Production systems land exactly on this boundary, each by a different strategy**: Coinbase Spend Permissions *restricts the call surface* until the hard questions cannot arise; the MetaMask Delegation Framework *pays to walk the chain*, closing the cross-hop gap at a measured **63,396 gas** for a 2-layer redemption; x402 *leaves the chain*, keeping standing-authority enforcement off-chain entirely. None of the three attempts r_conf on-chain.

**Thesis**: on-chain mechanisms can enforce only the *ceiling* of a payment policy R(P) — amounts, windows, scope within one hop, revocation. Semantic honesty (r_conf) and, absent root-anchored global state, cross-hop scope (r_scope) break. The smart account replaces the absent human, not the credit card.

---

## 1. Motivation and research question

Autonomous agents that pay for API calls, data, or services need standing payment authority. Two recent systematizations frame this space. Zhang et al. (2026) systematize blockchain agent-to-agent payments as a four-stage lifecycle (discovery → authorization → execution → accounting) and organize the authorization stage along *authorization carriers* × *policy expressiveness* — naming, but not measuring, risks such as "misuse under valid authorization" and valid-transaction sequences that violate intended spending boundaries. Shi et al. (2025) systematize LLM-agent security as a Belief–Intention–Permission lifecycle and find that existing defenses cluster at the belief/intent stages while the *permission* (authorization) boundary remains under-examined. Both classify; **neither quantifies** what enforcement costs on-chain or demonstrates experimentally where it structurally fails. This project supplies that measurement axis:

> On a minimal but realistic escrow, measure the per-check on-chain cost of E1/E2/E3 policy checks, determine how batching amortizes that cost, demonstrate experimentally which enforcement properties cannot hold, and anchor the resulting boundary against production systems.

The framing assumption, used as a consistency check throughout: **the smart account replaces the absent human, not the credit card**. The contract must self-enforce at decision time, with no human in the loop and no ex-post reconciliation.

## 2. Conceptual framework

Two axes form a grid:

| Axis | Levels |
|---|---|
| **Expressiveness** | E1 access (who/what may be called) · E2 transaction (per-call amount ceilings) · E3 contextual & stateful (expiry, revocation, cumulative windows) |
| **Enforcement** | r_rev (revocability) · r_scope (scope, single-hop and **cross-hop** through redelegation) · r_conf (semantic honesty — does the on-chain settlement reflect the off-chain truth?) |

The expressiveness levels follow Zhang et al.'s (2026) policy-expressiveness dimension (their E1 access-level / E2 transaction-level / E3 contextual-and-stateful, §4.2) verbatim, so our measurements plug directly into their taxonomy. The enforcement axis adopts the risk decomposition of Shi et al.'s (2025) B-I-P framework — `R(P) = max(r_conf, r_rev, r_scope)` — and **re-instantiates it at the on-chain settlement boundary**, which is this project's contribution: r_rev becomes revocability of standing payment authority (B-I-P: operational irreversibility), r_scope becomes blast radius including cross-hop delegation (B-I-P: cascade scope), and r_conf is narrowed to the slice visible at the settlement boundary — semantic honesty of what is billed (B-I-P's confidentiality/intent-fidelity reading stays out of scope, with the same conclusion: not locally observable on-chain). Zhang et al.'s §5.2 describes the corresponding risks in prose (reactive revocation; valid-sequence boundary violations; "authorization validates transactions but assumes transaction generation is trustworthy"); this project turns each into a property that can be tested and priced.

**Definitions.** *Enforceable* here means: the contract reverts every transaction that violates a policy predicate, where the predicate is computable at execution time purely from on-chain-observable inputs — calldata, `msg` context, block context, and contract state. Enforcement is therefore a runtime-checked invariant over transaction features, not a static security property of the agent. The *ceiling* of a policy P is formalizable as the strongest sub-predicate of P that factors through this observable projection: writing the intended policy as Π(tx, world) and the chain-checkable part as π(tx, σ), the ceiling is the maximal π implied by Π. Three tiers must be kept distinct throughout: **(i) on-chain enforceable** — π is checkable and checked; **(ii) locally self-verifiable** — the contract can evaluate the predicate without trusting any external claim (what r_conf fails, §6.1); **(iii) enforceable with imported truth** — the predicate becomes checkable only after a trusted party (oracle, attester, prover) injects a claim, making enforcement conditional on that party. Our negative results place r_conf outside (ii) for a bare payment primitive; they do not claim it is outside (iii).

The thesis was committed before measurement, as four falsifiable predictions (recorded in the project proposal):

- **P1.** Checks expressible over on-chain-observable transaction features (E1/E2, single-hop E3) are enforceable, and their cost is small and exactly attributable.
- **P2.** Cross-hop r_scope breaks under local-only state: per-hop caps do not compose into a global bound.
- **P3.** r_conf is not locally self-verifiable: no on-chain rule can act on a difference that never reaches the contract's input.
- **P4.** Deployed systems already behave as if this boundary exists — concentrating on-chain enforcement inside it and routing the rest off-chain.

Sections A–E build and price the cells that hold (P1). Sections F–G demonstrate the two cells that break (P2, P3). Section H checks the resulting picture against production systems (P4). The conclusion (§12) returns a verdict on each prediction.

## 3. System under measurement

`src/Escrow.sol` is a per-agent ETH escrow with a single-payment `settle(agent, to, amount)` and a batched `batchDeduct(agent, recipients[], amounts[])`. `settle` is deliberately **not** caller-restricted: the contract decides purely on its on-chain-observable input — the property the r_conf demonstration relies on.

Eight policy modules share one factoring: a **`library`** with an internal `check` (inlined into `Escrow`, so integrated opcodes match isolated ones) plus an external **`*_Harness`** wrapper for clean isolated measurement, each with a focused test file under `test/policies/`:

| Level | Modules |
|---|---|
| E1 | `E1_TargetAllowlist`, `E1_SelectorAllowlist` |
| E2 | `E2_ValueCap`, `E2_TokenAmountCap`, `E2_ApprovalCap` |
| E3 | `E3_Expiry`, `E3_Revocation`, `E3_CumulativeDailyCap` |

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

## 5. Results I — the enforceable side and its price

### 5.1 Per-check gas (Section D)

Full sortable table with per-row opcode accounts: `docs/gas-results.md`. Key rows (callee-frame gas):

| Check | Path | Storage | Gas |
|---|---|---|---:|
| E2 ValueCap / TokenAmountCap / ApprovalCap | pass / revert | — | **284 / 308** (all three identical) |
| E1 TargetAllowlist | pass | cold / warm | 2,557 / 557 |
| E1 SelectorAllowlist | pass | cold / warm | 2,531 / 531 |
| E3 Expiry | pass | cold / warm | 2,296 / 296 |
| E3 Revocation | pass | cold / warm | 2,297 / 297 |
| E3 CumulativeDailyCap (read-only) | pass | cold | 2,954 |
| E3 CumulativeDailyCap (read+write) | pass | ① / ② / ③ | 23,000 / 5,900 / 1,100 |
| E3 CumulativeDailyCap | revert (cap) | cold | 2,785 |
| E3 SlidingWindowRateLimit (read+write) | pass | ① / ② / ③ | 23,834 / 6,734 / 1,934 |
| E3 SlidingWindowRateLimit (adjacent-window shift) | pass | ② RESET | 6,813 |
| E3 SlidingWindowRateLimit | revert (cap) | cold | 3,437 |
| E3 DelegationDepth | pass / revert | — | 284 / 350 |

Four findings worth defending orally:

1. **The three E2 caps cost exactly the same (284/308).** They are one `amount > cap` comparison under different names (native wei, ERC-20 amount, approve allowance). Renaming the semantics does not change the on-chain cost; the equality is itself asserted in the test suite.
2. **Target vs Selector allowlist differ by exactly 26 gas on all four paths.** The source is Solidity's strict ABI decoder for `address` (high-12-byte zero check) that `bytes4` does not pay — a constant attributable to a single decoder behavior.
3. **One SSTORE, 20× spread.** The same cumulative-cap write costs 23,000 / 5,900 / 1,100 gas across regimes ①/②/③. Any "gas cost of a daily cap" claim that does not name its regime is underspecified.
4. **The two stateful families share one cost skeleton.** The sliding-window rate limit (added after the main sweep, two-bucket approximation) lands in the *same* three SSTORE regimes as the cumulative cap — SET 23,834 / RESET 6,734 / dirty 1,934 — with `SET − RESET = 17,100` isolating the SSTORE class exactly and the arithmetic provably constant (1,734) across all three. The richer arithmetic over the daily cap (+834) is fully attributable to its three non-byte-aligned packed fields (uint48/uint104/uint104) and the weighted MUL/DIV chain. And `E3_DelegationDepth` confirms the E2 shape at the gas: its pass path measures **exactly 284** like `E2_ValueCap`; its revert is 350, the +42 being only the two `uint256` args of `DepthExceeded` over E2's parameterless error.

An engineering footnote verified at the bytecode level: under the legacy optimizer (`via_ir = false`), a library `internal` function used by multiple call sites is emitted as a **shared subroutine rather than inlined** (the integrated `ExceedsDailyCap` revert string appears exactly once in the `Escrow` bytecode), so integrated per-check costs carry a small dispatch overhead over the isolated harness numbers.

### 5.2 Batch settlement curve (Section E)

Three baselines — 0: no policy (`src/baselines/PlainBatchTransfer.sol`), 1: E2-only (`src/baselines/Escrow_E2Only.sol`), 2: full E3 (`Escrow.batchDeduct`) — measured at N ∈ {1, 2, 5, 10, 20, 50}. Raw data: `docs/batch-curve.csv` (regenerable by one grep, see §10). Every curve fits **exactly** `gas(N) = intercept + N · marginal`:

| Baseline | Intercept (once per batch) | Marginal (per recipient) |
|---|---:|---:|
| 0 — no policy | 714 | 9,704 |
| 1 — E2 only | 8,582 | 10,026 |
| 2 — full E3 | 20,938 | **10,026** |

The decisive observation: **baselines 1 and 2 have identical marginals.** All E3 checks (revocation, expiry, cumulative cap) execute at *batch level* — they appear in the intercept (Δ = 12,356: three cold policy SLOADs, the `dailyState` cold SLOAD + RESET SSTORE, and E3 arithmetic) and never enter the per-recipient loop. The per-recipient floor (~9.7k) is the inner value-bearing `CALL` itself plus a ~322-gas E2 check.

Consequences at N = 50: per-request cost falls from 30,964 (N = 1) to **10,445**; full E3 costs **+7.5%** over no policy at all, and **+2.4%** over E2-only.

> **Claim 1 (priced ceiling).** E3-grade enforcement — expiry + revocation + cumulative daily cap — is effectively free at batch scale: its cost is per-batch, not per-payment, and amortizes to single-digit percent.

## 6. Results II — the two structural breaks

### 6.1 r_conf: the byte-identical settlement (Section F)

`test/rconf/CalldataIdentical.t.sol` stages an honest provider (`reportedUsage = 100`) and a malicious one (`reportedUsage = type(uint256).max / 2 ≈ 5.79 × 10⁷⁶`). When each bills the *same* amount, the settlement calldata the agent submits is **bit-identical** — asserted both as `assertEq(honestCalldata, maliciousCalldata)` and as keccak256 equality — and the escrow accepts both on equal footing.

The negation test makes the gap structural rather than incidental: the `settle` surface is exactly 4 selector bytes + 3 × 32-byte words (`agent`, `to`, `amount`) = **100 bytes**, with no field that could carry usage, an attestation, or a receipt. If the contract's entire input cannot differ, no on-chain rule it could contain can act on the difference.

Closing r_conf requires importing the off-chain truth through a trusted channel — oracle, signed attestation, TEE, ZK proof. Each *relocates* trust (to the oracle, signer, chip, prover) rather than removing it. A bare payment primitive cannot decide semantic honesty because the needed information is not in its input. (Figure: `figures/rconf_calldata_identity.svg`.)

**Claim status.** This is an empirical demonstration plus a structural argument scoped to this settlement surface — not a general impossibility theorem. Widening the surface (e.g., adding a `usage` field) does not escape the argument: the contract would then check a *claim* made by an interested party, and binding the claim to truth re-requires a trusted source — which is tier (iii) of §2, with the trust relocated and priced (signature verification, oracle fees, or ZK verification gas), not eliminated.

### 6.2 Cross-hop r_scope: the delegation escape (Section G)

`src/delegation/TwoHopDelegation.sol` implements local-only enforcement: every permission tracks its own `spent` against its own cap in its own slot. `test/delegation/CrossHopEscape.t.sol`:

- User grants Agent A a **2-ether** budget from a single funding pool.
- A spends 1.5 ether (≤ 2 — locally legal), then re-delegates a *fresh* 2-ether budget to B.
- B spends 2.0 ether (≤ 2 — locally legal).
- The pool pays out **3.5 ether against a 2-ether authorization**, with assertions confirming *no local cap was ever violated* — the assertion targets the global total drained, not any local state.

A control test shows a single hop cannot exceed its own cap (the third spend reverts), proving the escape is **compositional**: it lives in the gap between local caps and absent global accounting, not in a bug in the local checks. (Figure: `figures/crosshop_escape.svg`.)

A follow-up module isolates *which* mechanism is missing. `src/delegation/DepthBoundedDelegation.sol` adds a hard delegation-depth bound (`E3_DelegationDepth`, `MAX_DEPTH = 2`) on top of the same local-only enforcement; `test/delegation/DepthBoundEscape.t.sol` shows the bound is real (a depth-3 grant reverts `DepthExceeded`) yet the **exact same 3.5-ether escape replays at legal depth** (User→A→B, both within the bound). The depth bound constrains chain *length*, not *budget* — confirming the missing mechanism is root-anchored accounting, orthogonal to and unaffected by depth limits.

What closing it would require (see also §7.2): every spend must answer a *global* question — either (a) one shared budget object that the root grant creates and every descendant debits, or (b) ancestor traversal decrementing every ancestor's remaining allowance per spend. Both add state and gas scaling with delegation depth; with the measured single-hop cumulative check at ~2,954 read / ~5,900 read+write, option (b) multiplies roughly that per hop.

> **Claim 2 (the breaks).** r_conf fails by construction at the calldata boundary; cross-hop r_scope fails under local-only state. Both are missing-mechanism problems, not implementation bugs.

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

Decomposition (H3.3): the regime-① total splits into ~6.5–7k of policy checks (reconciling with the matching Section D rows), ~22.5k of state SSTORE, and ~34k of **account-abstraction transfer chain** (`account.execute` → `receive()` → `safeTransferETH` — three external calls). Once the AA chain is stripped, the residual reconciles with the host opcode model to within ~15%.

> **Claim 3a.** Production-grade enforceability is not a gas problem at the policy layer: Coinbase's policy logic costs about what our minimal escrow's does; the premium pays for ERC-4337/smart-wallet infrastructure.

### 7.2 MetaMask: cross-hop closed, and what it costs

Source walk (H5.1): `DelegationManager.redeemDelegations` fires **every caveat on every delegation in the chain** (beforeAll/before/after/afterAll hooks), and execution runs against the **root delegator's account**. State key (H5.2): every cumulative enforcer keys state as `spentMap[msg.sender][delegationHash]`, and only the manager calls the hooks — so the effective key is the delegation hash, which is **identical** whether User→A is redeemed directly by A or as the parent inside B's chain `[A→B, User→A]`.

Behavioral tests (`casestudy/metamask/test/h5-crosshop/CrossHopEnforcement.t.sol`, 2 PASS) replicate Section G's exact scenario inside the production framework:

| Test | Outcome |
|---|---|
| A spends 1.5 of a 2-ether root cap; B attempts 1.0 through the chain (total 2.5) | **Reverts** `allowance-exceeded`; counter and pool unchanged — the Section G escape does not survive |
| A 1.5 + B 0.5 (exactly cap); then either party attempts 1 wei more | First two succeed, both follow-ups revert — one shared counter, exactly enforced. B's 2-layer redemption: **63,396 gas** (caller-side `gasleft`; asserted ±2; not summable with callee-frame rows) |

The closure matches the mechanism our Section G analysis said would be necessary: a counter anchored to the root delegation that every redemption path debits. Caveat (H5.6): the guarantee is keyed to the delegation hash — issuing a second User→A delegation with a different `salt` creates a fresh counter and re-opens the escape; the root principal must treat each issued hash as the budget.

> **Claim 3b.** Cross-hop r_scope *is* on-chain-enforceable, but only by paying for chain-walked, root-anchored state — measured at ~63k gas for two layers in a production framework. Coinbase avoids the question; MetaMask pays it. **Neither system attempts r_conf**, confirming Section F's conclusion from the production side.

### 7.3 The third strategy: x402 leaves the chain

x402 — the Coinbase/Cloudflare HTTP-402 standard for agentic payments, and the highest-volume rail in this space — was surveyed during target selection and deliberately *not* vendored, because it has almost no on-chain policy surface to measure: per-request payments are signed EIP-3009 `transferWithAuthorization` payloads settled by a facilitator, and every standing-authority policy (budgets, counterparty rules, rate limits) lives client-side or facilitator-side, off-chain. Read structurally against the grid (protocol-spec reading, not vendored tests): the on-chain remainder is an exact per-payment amount (E2, enforced by the token contract), a validity window (E3-time), a one-shot nonce, and `cancelAuthorization` (r_rev). Cumulative state, delegation, and r_conf simply do not exist on-chain.

This is not a gap in the case study — it is the third data point. Where Coinbase *restricts the surface* and MetaMask *pays to walk the chain*, x402 *exits the chain*: it relocates R(P) enforcement to an off-chain trust point, which is exactly the trade our framework predicts when on-chain enforcement is either impossible (r_conf) or priced (stateful policy). Source: the x402 specification and launch documentation (https://github.com/coinbase/x402; https://www.coinbase.com/developer-platform/discover/launches/x402).

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
| Replay of a settlement | **bounded, not prevented** — no per-settlement nonce exists; repeated valid settlements are capped by the per-request and cumulative ceilings | §5.1 caps |

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

## 9. Limitations

1. **Callee-frame ≠ end-to-end.** Numbers exclude the 21,000 transaction base and caller-side CALL overhead; they price the policy check increment, not the wallet-visible total.
2. **E1 allowlists are measured in isolation only.** `settle(agent, to, amount)` has no target/selector dimension, so C.6 integrated E2+E3 only; E1 numbers are module-level.
3. **The escrow is ETH-only.** Token/approval caps are measured as pure checks, not inside a real ERC-20 transfer path.
4. **Cross-hop closure is demonstrated in the vendored framework, not ported into our escrow.** We bound what compositional enforcement costs (§6.2, §7.2) but did not implement it host-side.
5. **The MetaMask 63,396 figure is caller-side** (their forge-std pin predates `vm.lastCallGas`) and must not be summed with callee-frame rows; the H5 tests use a minimal `MockDelegator`, not the production DeleGator signature/4337 paths (orthogonal to the chain-enforcement question, but a scope boundary).
6. **r_conf is demonstrated for a bare payment primitive.** Systems that *import* off-chain truth (oracles, attestations, TEEs, ZK) can move the boundary at the price of relocated trust — measured here only as an argument, not an implementation.
7. **The sliding-window rate limit is measured as a two-bucket approximation, not a true sliding log.** `E3_SlidingWindowRateLimit` is now implemented and measured (§5.1): the count-based two-bucket approximation packs into one slot and lands in the same three SSTORE regimes as the cumulative cap. A *true* sliding log — one that remembers each event's timestamp — is O(events) storage slots, whose cost is bounded analytically (one cold SLOAD + one SSTORE per retained event), not measured here; the two-bucket form is the standard production trade of exactness for a single slot. Delegation-depth bounds are likewise now implemented and measured (`E3_DelegationDepth`, §5.1) and, via `DepthBoundedDelegation`, shown to constrain chain length without closing the budget escape (§6.2). The remaining unimplemented item is host-side cross-hop *closure*: root-anchored compositional enforcement is bounded and answered via the vendored production framework (§7.2) rather than ported into our own escrow.
8. **Absolute gas numbers are toolchain-specific.** Under `via_ir = true` (or a different solc/optimizer), codegen changes and every absolute number shifts — which is exactly why the toolchain is pinned and treated as part of the experiment's identity. The *structural* findings (the three SSTORE regimes, exact linearity of the batch curve, equal marginals between baselines 1 and 2, the E2 equality) are expected to survive a toolchain change, but this was not re-verified under the IR pipeline.

## 10. Reproducibility

Everything is deterministic under the pinned toolchain; gas numbers reproduce exactly cross-platform (independently re-run on Linux during review — all asserted values matched to the digit).

```sh
forge --version    # must be 1.7.1 (4072e487)
forge test         # host: 100 passed / 0 failed
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
src/       Escrow.sol · policies/ (10 modules) · baselines/ (E) · mocks/ (F) · delegation/ (G, + DepthBoundedDelegation)
test/      policies/ (D) · batch/ (E) · rconf/ (F) · delegation/ (G) · BaseTest.sol
casestudy/ coinbase/ (H2–H3) · metamask/ (H4–H5), each pinned via VERSION.md
docs/      gas-results.md (D+E) · batch-curve.csv ·
           case-study{,-coinbase,-metamask}.md (H) · figures/*.svg · final-report.md
snapshots/ baseline.snap (frozen) · current.snap (live)
```

Sections and merges: A–B (`9895070`) → C (`f0591e9`, 8 modules + integration) → D (`35d8502`…`bbf0e30`, per-check gas) → E (`ba254f8`…`6ef265c`, batch curve) → F (`6e388d9`, r_conf) → G (`edab10d`, cross-hop escape) → H (`7fbab9f` → `119abbf` → `53b58e4` → `11a9d14`, case studies; merged via PR #2) → H9 post-review fixes (`23bb900`, PR #3: locked case-study gas assertions, Coinbase solc pin, doc reference cleanup).

## 12. Conclusion

The verdict on the four predictions committed in §2:

| Prediction | Verdict | Decisive evidence |
|---|---|---|
| **P1** — the expressible ceiling is enforceable, cheaply and attributably | **Held** | every per-check number opcode-accounted (residual < 46 gas); E3 premium amortizes to 2.4% at N = 50 (§5) |
| **P2** — cross-hop r_scope breaks under local-only state | **Held** | 3.5 ether drained from a 2-ether authorization, no local cap violated, control test passes (§6.2) — and the closure has a price: 63,396 gas in production (§7.2) |
| **P3** — r_conf is not locally self-verifiable | **Held, by construction** | honest and malicious settlements byte-identical; the 100-byte surface has no field for truth (§6.1); none of the three production systems attempts it (§7) |
| **P4** — deployed systems already respect the boundary | **Held, with a refinement** | not one pattern but three strategies: restrict the surface (Coinbase), pay to walk the chain (MetaMask), leave the chain (x402) — all converging on the same r_conf wall (§7) |

The project set out to measure a boundary and ended up pricing both of its sides. Inside the boundary, enforcement is cheap, linear, and explainable to the opcode: three identical 284-gas caps, a 26-gas decoder constant, a 20× SSTORE spread that careful methodology must name, and an E3 premium that amortizes to 2.4% at batch scale. Outside it, the failures are structural: a 100-byte settlement surface that cannot carry truth, and local counters that cannot see a delegation tree. Production systems trace the same line from three directions — restricting the surface until the hard questions vanish, paying ~63k gas to walk the chain and anchor state at the root, or leaving the chain entirely — and **all of them leave semantic honesty to the off-chain world**. On-chain payment policy enforces the ceiling of R(P); it does not, and cannot alone, enforce the truth beneath it.

## References

Shi, G., Du, H., Wang, Z., Liang, X., Liu, W., Bian, S., & Guan, Z. (2025). *SoK: Trust-authorization mismatch in LLM agent interactions* (arXiv:2512.06914). arXiv. https://doi.org/10.48550/arXiv.2512.06914

Zhang, Y., Xiang, Y., Lei, Y., Wang, Q., Qiu, T., Sun, Y., Zarkov, S., Yuen, T. H., Deppeler, A., Yu, J., & Lam, K.-Y. (2026). *SoK: Blockchain agent-to-agent payments* (arXiv:2604.03733). arXiv. https://doi.org/10.48550/arXiv.2604.03733
