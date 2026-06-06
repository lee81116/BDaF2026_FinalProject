# CLAUDE.md

Project conventions for Claude Code. Read this first every session. Task-specific
detail (predicted gas for a section, a given parallel run's worktree commands)
lives in the handoff prompts, not here.

## Project

Measures the **enforceability boundary** and **gas cost** of on-chain payment
policies for autonomous agents. Two axes:

- **Expressiveness** E1 (access) / E2 (transaction) / E3 (contextual & stateful)
- **Enforcement** r_rev (revocation) / r_scope (scope, incl. cross-hop) / r_conf (semantic honesty)

**Thesis**: on-chain mechanisms can only enforce the *ceiling* of R(P); **r_conf
and cross-hop r_scope break**. A–G demonstrate and quantify this; H (case study)
checks it against real systems.

Status: **A–G done**; **H planned** (`docs/case-study-impl-plan.md`,
`docs/case-study-handoff.md`). `forge test` is green (100 tests across A–H + the E3 extensions: sliding-window rate limit and delegation-depth bounds).

## Golden rules (non-negotiable)

1. **Never change the default `foundry.toml`** (solc 0.8.26 / optimizer 200 /
   `via_ir=false`; forge 1.7.1). Any change invalidates every recorded gas number.
   If a task seems to need it, stop and ask the human first.
2. **A number/claim you can't explain at the opcode or source level is not a
   result.** If a measurement is off by more than the tolerance, open a trace
   (`forge test --match-test <name> -vvvv`) and fix the *model* — never widen the
   assertion to make it pass.
3. **Tests passing ≠ the test asserts what you think.** Read every assertion.
4. **Thesis check**: the smart account replaces the absent human, not the credit
   card. If something you write contradicts that, change one of them.

## Toolchain & commands

- forge **1.7.1** (`4072e487`) · solc **0.8.26** · optimizer **200** · `via_ir=false`. Confirm with `forge --version`.
- `make build` / `make test` / `make snap` (writes `current.snap`) / `make snap-check` / `make gas-report`.
- Format new files with `forge fmt`. Keep `forge test` green and `git diff foundry.toml` empty.

## Code conventions

- **Policy module = `library`** (internal `check`, inlined into `Escrow`) **+
  `*_Harness`** (external wrapper, for clean isolated measurement). One harness →
  one focused test file under `test/policies/`.
- **Library errors are canonical**: since C.6, `Escrow.settle`/`batchDeduct` call
  the libraries and revert with *their* errors (`ExceedsValueCap`, `Expired`,
  `PolicyInactive`, `ExceedsDailyCap`). `Escrow` keeps only `NotUser` /
  `InsufficientBalance`.
- Branch per section, PR into `main`. Don't commit `.claude/`, `.DS_Store`, or
  `casestudy/*/lib`.

## Gas measurement (Section D methodology — reuse it)

- **Primitive**: `vm.lastCallGas().gasTotalUsed` (callee-frame). Helper:
  `test/policies/GasMeasure.sol` → `_measure(target, data, expectOk)`. Account
  cold/warm does NOT affect this number; **storage** cold/warm does, and is
  controlled by call ordering within a single tx.
- **TDD**: predict the number from an opcode model, assert
  `assertApproxEqAbs(measured, PRED, TOL=2)`. Numbers are deterministic under the
  pinned toolchain.
- **Do NOT** use `forge --gas-report` Min/Max for stateful checks — it mixes
  cold/warm runs and adds caller-side overhead (it once reported a phantom 44,505
  for `checkReadWrite` whose true cold value is 23,041).
- `setUp` runs in a separate tx from each `test_*` (EIP-2929 access list resets),
  so the first SLOAD inside the measured call is genuinely **cold**.
- **Cumulative-cap SSTORE has three regimes**, name them: ① SET zero→nonzero
  (~23k, first settle), ② RESET nonzero→nonzero (~5.9k, repeat-day, cross-tx),
  ③ dirty same-tx 2nd write (~1.1k — NOT a realistic per-tx cost; the plan's
  "warm" example lands here).
- For batch measurements: fresh contract per N (no cross-contamination),
  pre-`vm.deal` recipients 1 wei (avoid 25k account-creation), prime `dailyState`
  non-zero so the measured SSTORE is RESET not SET.

## Snapshots

- `snapshots/baseline.snap` = phase-1 record — **never overwrite**.
- `snapshots/current.snap` = live; `make snap` regenerates it; `make snap-check`
  must show 0 drift.

## External / case-study source

Vendor each system under `casestudy/<system>/` **with its own foundry config**;
**never** merge external solc/optimizer settings into our default profile.
gitignore `casestudy/*/lib`. Record the exact commit hash + deployed address read
in a `VERSION.md`. To answer behavioural questions (e.g. cross-hop r_scope),
deploy the vendored framework **locally** in a Foundry test — no mainnet fork / RPC.

## Layout & key docs

```
src/      Escrow.sol · policies/ (10 modules) · mocks/ (F) · delegation/ (G) · baselines/ (E)
test/     BaseTest.sol · policies/ · batch/ · rconf/ · delegation/
docs/     implementation_plan.md (the working plan) · gas-results.md (D+E numbers)
          methodology.md (F/G) · case-study-*.md · figures/ (SVGs for slides)
snapshots/ baseline.snap · current.snap
```

Start by reading `implementation_plan.md` for the section you're working on, then
the relevant `docs/*` and this file's measurement section.
