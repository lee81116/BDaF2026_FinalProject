# MetaMask Delegation Framework — Case Study (H4 + H5)

**Pinned source**: `casestudy/metamask/` @ `MetaMask/delegation-framework` v1.3.0
(commit `bfbdf979`). See `casestudy/metamask/VERSION.md` for the full pin
manifest. All `file:line` refs in this file are to that vendored tree; the
ones in src/* are under `casestudy/metamask/src/`.

---

## H4 — Caveat enforcers ↔ our 8 policy modules

### H4.1 — Mapping table

The MetaMask framework expresses every restriction as a `Caveat = (enforcer
address, terms, args)` (`src/utils/Types.sol`, `Caveat` struct). The
`DelegationManager` walks the chain and calls each enforcer's `beforeAllHook`,
`beforeHook`, `afterHook`, `afterAllHook` (see H5.1 for the chain walk).
Mapping each of our 8 policy modules to the closest enforcer:

| Host module | Closest MetaMask enforcer | Code reference | Notes / shape difference |
|---|---|---|---|
| `E1_TargetAllowlist` | `AllowedTargetsEnforcer` | `src/enforcers/AllowedTargetsEnforcer.sol:26–51` (`beforeHook` extracts the call target from execution data, linear-scans the calldata-encoded address list) | Same semantics; different storage. Host keys an SSTORE map (one cold SLOAD); MetaMask passes the allow-list inline in `terms` and scans it. For small lists the two are within tens of gas; for large lists MetaMask grows linearly while host stays O(1). |
| `E1_SelectorAllowlist` | `AllowedMethodsEnforcer` | `src/enforcers/AllowedMethodsEnforcer.sol:27–84` (4-byte selectors packed into `terms`; identical linear-scan pattern) | Same shape difference as targets. The pair of MetaMask enforcers is the analog of our pair. |
| `E2_ValueCap` | `ValueLteEnforcer` | `src/enforcers/ValueLteEnforcer.sol:25–43` — single `require(value_ <= termsValue_)` | Direct one-to-one. Host opcode model and MetaMask's are the same (one decode + GT). Both pass r_conf-blind. |
| `E2_TokenAmountCap` | `ERC20TransferAmountEnforcer` (per-call) **or** `NativeTokenTransferAmountEnforcer` (per-call native) | `src/enforcers/ERC20TransferAmountEnforcer.sol:96–97`; `NativeTokenTransferAmountEnforcer.sol:56–57` | MetaMask's "TransferAmount" enforcers do **cumulative** accounting against `allowance` (lines 56–57: `spent_ += value_; require(spent_ <= allowance_)`) — semantically closer to our `E3_CumulativeDailyCap` than to our per-call `E2_TokenAmountCap`. There is no MetaMask enforcer that only checks a per-call max without keeping running state. |
| `E2_ApprovalCap` | (no exact analog; closest: chain a `ValueLteEnforcer` with `AllowedMethodsEnforcer(approve.selector)`) | — | MetaMask does not ship a dedicated "limit `approve()` amount" enforcer. Approval semantics get expressed by composing `AllowedMethods` + `AllowedCalldata` / `ArgsEqualityCheck`. |
| `E3_Expiry` | `TimestampEnforcer` **and** `BlockNumberEnforcer` | `src/enforcers/TimestampEnforcer.sol:22–46`; `src/enforcers/BlockNumberEnforcer.sol:22–46` | MetaMask supports both a `<` upper bound and a `>` lower bound in the same `terms`, so it covers `[earliest, latest]` windows — strictly richer than our single-bound `E3_Expiry`. |
| `E3_Revocation` | `DelegationManager.disableDelegation` (revocation lives on the manager, not in an enforcer) | `src/DelegationManager.sol:90–95` (set flag); `DelegationManager.sol:186–188` (per-redemption check) | Architectural difference: MetaMask centralises revocation in the manager (one mapping `disabledDelegations[delegationHash]`) so every caveat doesn't have to re-implement it. Our `E3_Revocation` is a discrete policy module; same effect, different placement. |
| `E3_CumulativeDailyCap` | `NativeTokenPeriodTransferEnforcer` / `ERC20PeriodTransferEnforcer` / `MultiTokenPeriodEnforcer` | `src/enforcers/NativeTokenPeriodTransferEnforcer.sol:34` (state `mapping(address ⇒ mapping(bytes32 ⇒ PeriodicAllowance))`); `ERC20PeriodTransferEnforcer.sol:35` (same shape) | Direct analog. MetaMask generalises the period (any seconds) where ours fixes 24 hours. State key shape is identical: keyed by `delegationHash` under the DelegationManager, so cumulative state is shared across redemption paths — this is the H5 evidence. |

### H4.2 — MetaMask enforcers without a host analog

| Enforcer | What it does | Why we have no analog |
|---|---|---|
| `NativeTokenStreamingEnforcer`, `ERC20StreamingEnforcer` | Linearly unlock allowance over time (`maxAmount`, `startTime`, `duration` in `terms`); `_getAvailableAmount` released grows with `block.timestamp − startTime`. See `NativeTokenStreamingEnforcer.sol:165`. | Streaming is a richer time function than our 24-h reset. Our `E3_CumulativeDailyCap` is the simplest stateful pattern; streaming is a generalisation we did not measure. |
| `NonceEnforcer` | Per-delegator monotonic nonce in `currentNonce[manager][delegator]`. Lets the delegator atomically invalidate all delegations with the same nonce. See `NonceEnforcer.sol:16, 44`. | We model revocation per-delegation. "Bump a counter and invalidate all" is a UX feature, not a new enforceability axis. |
| `LimitedCallsEnforcer` | Bounded count of redemptions per delegation (rate cap). | We have no per-delegation call-count policy; this is in spirit a degenerate `E3_CumulativeDailyCap` with `value=1` per call. |
| `NativeBalanceChangeEnforcer`, `ERC20BalanceChangeEnforcer`, `ERC721BalanceChangeEnforcer`, `ERC1155BalanceChangeEnforcer` | Before/after balance delta check on a target address (locks state in `beforeHook`, asserts in `afterHook`). | We do not currently model balance-delta caveats; this is a richer policy than our cap modules. |
| `NativeTokenPaymentEnforcer` | Charge a fee paid in native token to a recipient, atomically tied to redemption. | No host analog. |
| `ArgsEqualityCheckEnforcer`, `AllowedCalldataEnforcer`, `ExactCalldataEnforcer`, `ExactCalldataBatchEnforcer`, `ExactExecutionEnforcer`, `ExactExecutionBatchEnforcer` | Parameter-level pinning of execution calldata (full or partial match). | A finer-grained companion to `AllowedMethodsEnforcer`. Our framework matches on selector only; richer ABI-arg pinning is on the roadmap, not currently implemented. |
| `RedeemerEnforcer` | Restrict which address may redeem (e.g. spender-scoping). | We embed delegate scoping in `Escrow.settle` itself; no separate module. |
| `IdEnforcer`, `OwnershipTransferEnforcer`, `LogicalOrWrapperEnforcer`, `DeployedEnforcer`, `ERC721TransferEnforcer`, `SpecificActionERC20TransferBatchEnforcer` | One-off specialised policies. | Not in our E1/E2/E3 taxonomy. |

### H4.3 — Host modules MetaMask does not (cleanly) cover

- **Per-call value ceiling without running state.** Our `E2_ValueCap` is
  stateless (`pass = 284` gas) and re-evaluates against the *current* call's
  value only. MetaMask's transfer-amount enforcers always accrue
  `spentMap[delegationHash] += value`. To get a stateless per-call cap you
  must use `ValueLteEnforcer` (which restricts the *single-call* value but
  has no native-token-specific semantics — it works on any execution mode).
- **`E2_ApprovalCap` as a standalone module.** MetaMask expects composition
  of `AllowedMethods(approve)` + `AllowedCalldata` (parameter pin) or
  `ArgsEqualityCheck`. The host's single-module spelling is more economical
  per-call (one SLOAD + one comparison) at the cost of an extra deployed
  contract.
- **Discrete revocation as a policy module.** MetaMask folds revocation
  into the manager (`disabledDelegations` mapping). Our `E3_Revocation`
  exists because the host's `Escrow` invokes policy libraries inline and
  there is no equivalent of a "manager that knows about every delegation".

### H4.4 — One-line summary

The MetaMask enforcer set strictly covers our 8 original modules (via direct
or near-direct analogs; see H4.5 for the two modules added after H) and adds
**streaming, balance-delta, fee-payment, nonce, and calldata-pinning**
policies our framework does not model. The *shape* of restriction is the same
in both systems: each enforcer is a small, single-purpose contract that
reverts on disallowed execution. The big architectural difference is **where
state lives** — MetaMask keys state by `(DelegationManager, delegationHash)`;
our host keys state by `(Escrow, policyId)`. This is the load-bearing fact
for H5.

### H4.5 — Addendum (post-H E3 extensions): two host modules with no enforcer analog

The two modules added after the H sweep reverse the coverage direction — the
host now measures two policies the framework does not ship:

1. **`E3_SlidingWindowRateLimit` (count-based, two-bucket sliding
   approximation).** No enforcer implements a *sliding* window: the
   `NativeToken/ERC20/MultiTokenPeriodTransferEnforcer` family is
   **fixed-window** (allowance resets at period boundaries), the streaming
   enforcers are linear-unlock, and `LimitedCallsEnforcer` is a windowless
   total count. A fixed-window cap admits up to 2× the intended rate across
   a boundary (cap at the end of period n plus cap at the start of n+1);
   the two-bucket weighting is the standard production mitigation, and it
   costs the same SSTORE regimes as the fixed window (host measurement:
   SET 23,834 / RESET 6,734 / dirty 1,934).
2. **`E3_DelegationDepth`.** No enforcer bounds delegation-chain depth, and
   under the v1.3.0 hook interface none *could*: `beforeHook` receives only
   `(terms, args, mode, executionCalldata, delegationHash, delegator,
   redeemer)` (`src/interfaces/ICaveatEnforcer.sol:49`) — an enforcer never
   observes its position in the chain or the chain's length, so a
   depth-bound caveat is not expressible without DelegationManager changes
   (`DelegationManager.sol` contains no depth accounting; chains are
   arbitrary-length arrays). Note the host-side finding cuts the other way
   too: depth bounds constrain chain *length*, not *budget* — the Section G
   escape replays at legal depth (`test/delegation/DepthBoundEscape.t.sol`),
   so MetaMask's hash-keyed shared counter (H5) addresses the part that
   matters, and a depth bound would be a complement, not a substitute.

---

## H5 — Cross-hop r_scope: redelegation enforcement

### H5.1 — Source walk (evidence level: read)

`DelegationManager.redeemDelegations` (`src/DelegationManager.sol:126–309`)
takes one or more `Delegation[]` chains and runs *every* hook on *every*
delegation in each chain. Concretely, for a single batch:

1. **Validation** — leaf-to-root signature check
   (`src/DelegationManager.sol:160–181`), then authority-chain and
   delegate consistency checks
   (`DelegationManager.sol:184–203`). The leaf delegate must equal
   `msg.sender` (line 156). The root delegation's `authority` must equal
   `ROOT_AUTHORITY` (line 200).
2. **`beforeAllHook`** — outer loop over delegations, inner loop over
   caveats, leaf-to-root order (`DelegationManager.sol:208–227`).
3. **`beforeHook`** — same iteration pattern, leaf-to-root
   (`DelegationManager.sol:234–249`).
4. **Execution** — exactly one call:
   `IDeleGatorCore(rootDelegator).executeFromExecutor(mode, executionData)`
   at `DelegationManager.sol:252–253`. Funds therefore flow from the
   **root delegator's account**, which is the single funding pool.
5. **`afterHook`** — root-to-leaf (`DelegationManager.sol:256–271`).
6. **`afterAllHook`** — root-to-leaf (`DelegationManager.sol:279–294`).

> **The chain is walked. Every caveat on every delegation fires.** There
> is no "only the leaf is checked" branch — the loops iterate over the
> full `batchDelegations_[batchIndex_]` array.

This answers half the H5 question by source-reading alone: **caveat
enforcement is chain-wide, not leaf-only**. The second half — whether the
enforcer *state* respects the chain or splits per-hop — depends on each
enforcer.

### H5.2 — Enforcer state-key shape (evidence level: read)

Every cumulative-cap enforcer in the framework follows the same storage
pattern:

```solidity
// NativeTokenTransferAmountEnforcer.sol:20
mapping(address sender => mapping(bytes32 delegationHash => uint256 amount)) public spentMap;

// ERC20TransferAmountEnforcer.sol:20
mapping(address delegationManager => mapping(bytes32 delegationHash => uint256 amount)) public spentMap;

// LimitedCallsEnforcer.sol:16
mapping(address delegationManager => mapping(bytes32 delegationHash => uint256 count)) public callCounts;

// NativeTokenPeriodTransferEnforcer.sol:34
mapping(address delegationManager => mapping(bytes32 delegationHash => PeriodicAllowance)) public periodicAllowances;
```

The outer key is `msg.sender`, and only the `DelegationManager` ever calls
these `beforeHook`s — so the effective key reduces to the **delegation
hash**. That hash is computed via `EncoderLib._getDelegationHash` over
`(delegate, delegator, authority, caveats, salt)` — i.e. it is **the same
hash whether the delegation appears as the root of a chain redemption or
as a mid-chain link in someone else's chain**.

Therefore: every redemption that includes the User→A delegation in its
chain charges the *same* `spentMap[DM][hash(User→A)]` counter. There is no
per-hop split.

### H5.3 — Behavioural test (evidence level: local pass)

Source walk + state-key reasoning predicts that the host's Section G
cross-hop escape (`test/delegation/CrossHopEscape.t.sol`) is **closed** by
this framework. The two tests in
`casestudy/metamask/test/h5-crosshop/CrossHopEnforcement.t.sol` make the
prediction empirical:

| Test | Setup | Expected | Result |
|---|---|---|---|
| `test_crossHop_parentCaveat_blocksOverspend` | A directly redeems 1.5 ether through `[User→A]`. B then tries to redeem 1.0 ether through `[A→B, User→A]` (would total 2.5 against 2.0 cap). | revert with `"NativeTokenTransferAmountEnforcer:allowance-exceeded"` | **PASS** — revert as predicted; counter and provider balance unchanged. |
| `test_crossHop_sharedCounter_andCost` | A → 1.5; B → 0.5 through chain (totals exactly 2.0). Then either A or B tries one more wei. | First two succeed; third reverts. B's 2-layer redemption gas captured. | **PASS** — counter = 2.0 at cap; both follow-up attempts revert. B's 2-layer redeem: **63,396 gas** (caller-side, `gasleft`-based). |

Scaffolding: the test uses `casestudy/metamask/test/h5-crosshop/MockDelegator.sol`,
a minimal `IDeleGatorCore + IERC1271` shim (always-valid `isValidSignature`;
`executeFromExecutor` decodes a single execution and calls). The User and A
accounts are both `MockDelegator` instances; B is an EOA. No
`HybridDeleGator` / `MultiSigDeleGator` / EIP-7702 production paths are
exercised — those add owner-keyed signature verification and ERC-4337
entry-point gates orthogonal to the chain-enforcement question.

### H5.4 — Gas note (methodology caveat)

`vm.lastCallGas` is **not** available in the forge-std version MetaMask
pins (`lib/forge-std @ ae570fec`), so the cross-hop gas in H5.3
(**63,396 gas**) is captured caller-side via `gasleft()` deltas — closer to
a `forge --gas-report` Min than to the host repo's Section D callee-frame
primitive (~32k for `Escrow.settle` with `E3_CumulativeDailyCap`). The
caller-side number includes the ABI encoding of two chains plus all
sub-call overhead. We surface it as the **cross-hop column number** for
the gradient-table comparison, with the explicit caveat that it must not
be summed with our Section D rows.

### H5.5 — Section G reconciliation

| Section G fact | MetaMask answer |
|---|---|
| Per-delegation isolated counter (`TwoHopDelegation.spentOf[permId]`) lets A's 1.5 + B's 2.0 escape the User's 2-ether root cap. | Closed by construction — `spentMap` is keyed by `delegationHash` and the chain walk fires the parent caveat on every redemption that touches it. |
| Mechanism: a *global* counter anchored to the root delegation would have caught it. | MetaMask implements that global counter under a different name: it is `spentMap[DM][hash(rootDel)]`, and chain redemption walks through it because parent caveats fire. |
| Cost: in our Section G the escape is free (no extra opcodes). | MetaMask pays one extra `beforeHook` call per parent layer (one cold SLOAD on `spentMap`, one SSTORE update, plus the calldata + framework dispatch). Measured: **63,396 gas** for a 2-layer cross-hop redemption that successfully enforces both layers. |
| Conclusion in our methodology: "cross-hop r_scope on-chain only works if every link's caveat sees a counter anchored to the root." | MetaMask satisfies that condition for **all cumulative-cap enforcers** (Native/ERC20 TransferAmount, Native/ERC20 Period, MultiTokenPeriod, LimitedCalls, both Streaming enforcers). Stateless enforcers (`ValueLte`, `AllowedTargets`, `AllowedMethods`, `Timestamp`, `BlockNumber`) trivially enforce the parent rule because their check has no state to split. |

### H5.6 — Caveat (what would re-open the escape)

The shared-counter guarantee depends on **the delegation hash being
unchanged** between the direct-redeem path and the cross-hop path. Two
ways to break it:

1. **Different `salt`.** A could re-issue a `salt=1` copy of User→A with
   different terms and use that as the parent of A→B. The two
   "User→A" delegations would have distinct hashes → distinct counters
   → escape re-opens. The User must therefore treat *each issued
   delegation hash* as the authoritative budget; you can't "approve
   another copy because it's the same allowance".
2. **`ANY_DELEGATE` shortcuts.** `DelegationManager.sol:41, 156` allows
   `ANY_DELEGATE = address(0xa11)` to bypass the leaf-delegate check.
   This does **not** reset the cumulative counter (the hash still
   identifies the delegation), but it changes who can drive a
   redemption, which is a different surface to audit.

Neither is a defect — both are documented features — but both are
relevant when porting MetaMask's guarantee into an on-chain agent system.

---

## Net read

For cumulative-cap caveats — the only ones where a cross-hop escape is
even possible — the MetaMask Delegation Framework **enforces the root
delegation's caveat across every redemption path** by combining
(a) `redeemDelegations` walking the full chain, and (b) every cumulative
enforcer keying state on the delegation hash under the manager. Our
host Section G escape (test `test/delegation/CrossHopEscape.t.sol`) does
not survive being lifted into this framework — `test_crossHop_parentCaveat_blocksOverspend`
is the closure proof, at a measured cost of ~63k gas for the 2-layer
redemption that performs the enforcement.
