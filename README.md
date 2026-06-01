# Agent Payment Enforceability — Boundary Measurement

Foundry project measuring the gas cost and enforceability boundaries of
on-chain payment-policy primitives for autonomous agents (E1/E2/E3 policy
levels; r_rev / r_scope / r_conf enforcement properties).

## Toolchain (pinned — do not change without re-baselining gas)
- **forge / cast / anvil**: 1.7.1 (commit `4072e48705`, build 2026-05-08)
  - Pin YOUR exact version here after running `forge --version` on your machine.
    Gas numbers depend on the compiler and Foundry version — pinning is non-negotiable.
- **solc**: 0.8.26 (set in `foundry.toml`, auto-downloaded by forge)
- **forge-std**: v1.16.1 (vendored under `lib/forge-std`)

## Layout
```
src/
  Escrow.sol                 # Section B
  policies/                  # Section C — 8 E1/E2/E3 policy modules
  mocks/                     # Section F — Mock/Malicious providers
  delegation/                # Section G — TwoHopDelegation
test/
  BaseTest.sol               # shared actors + measureGas helper
  policies/ batch/ rconf/ delegation/
snapshots/                   # committed gas snapshots
docs/                        # methodology, gas-results, case-study
foundry.toml  Makefile  README.md
```

## Commands
- `make build`       — compile
- `make test`        — run tests (`forge test -vvv`)
- `make snap`        — write `snapshots/current.snap`
- `make snap-check`  — diff current tests against the committed snapshot
- `make gas-report`  — write `docs/gas-results.md`

## foundry.toml — line-by-line
- `src/out/libs` — source, build-artifact, and library directories.
- `solc_version = "0.8.26"` — pins the compiler; the single biggest reproducibility lever for gas.
- `optimizer = true`, `optimizer_runs = 200` — optimizer on, tuned for ~200 calls; changing either invalidates all recorded gas numbers.
- `via_ir = false` — use the legacy codegen pipeline (not the Yul/IR pipeline), so opcode-level reasoning matches what you read.
- `gas_reports = ["*"]` — emit gas reports for every contract.
- `[profile.default.fuzz] runs = 256` — fuzz iterations per property test.
- `[fmt]` — `forge fmt` style: 100-col lines, 4-space tabs, no inner bracket spacing.

## Getting started (teammates)
```bash
git clone <repo-url>
cd agent-payment-enforceability
make build && make test
```
forge-std is **vendored** under `lib/forge-std` (v1.16.1) — no submodule init needed.
Install Foundry first if you don't have it: https://getfoundry.sh
