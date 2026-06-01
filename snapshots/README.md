# Gas snapshot reproduction

## Environment
- forge version: 1.7.1 (commit 4072e48705, 2026-05-08)  <!-- replace with YOUR `forge --version` on first run -->
- solc version: 0.8.26
- optimizer: enabled, 200 runs
- via-ir: false

## Reproduction
1. Clone the repo.
2. Run `make build`.
3. Run `make snap`.
4. `diff snapshots/current.snap snapshots/baseline.snap` should be empty.

## Snapshot policy
- Numbers are committed to git alongside the code that produced them.
- Any change to foundry.toml invalidates prior snapshots and requires a new baseline.
- `baseline.snap` is currently empty: there are no tests yet (Section A only).
  It fills in once Section B/C add `test*` functions.
