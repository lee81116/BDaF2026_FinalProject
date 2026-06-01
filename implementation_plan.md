# Implementation Plan: Enforceability Boundary Measurement Project

This is the working document. Follow it section by section. Each section ends with a *verification* checkpoint — do not move on until that checkpoint passes.

A guiding principle throughout: **a number you cannot explain at the opcode level is not yet a result.** AI can write boilerplate and scaffolding; you must read every gas measurement and ask "where does this come from." If you cannot answer, you have a debt, not a deliverable.

---

## Section A — Setup and Substrate

### A.1 — Install Foundry and verify

```bash
curl -L https://foundry.paradigm.xyz | bash
foundryup
```

Verify versions:

```bash
forge --version
cast --version
anvil --version
```

Pin the version. Note the exact `forge --version` output in `README.md`. Gas numbers depend on the compiler and Foundry version — pinning is non-negotiable.

### A.2 — Initialize the project

```bash
mkdir agent-payment-enforceability && cd agent-payment-enforceability
forge init --no-git
git init
git add . && git commit -m "forge init baseline"
```

Project layout (create the empty directories now so you do not improvise later):

```
agent-payment-enforceability/
├── src/
│   ├── Escrow.sol
│   ├── policies/
│   │   ├── E1_TargetAllowlist.sol
│   │   ├── E1_SelectorAllowlist.sol
│   │   ├── E2_ValueCap.sol
│   │   ├── E2_TokenAmountCap.sol
│   │   ├── E2_ApprovalCap.sol
│   │   ├── E3_Expiry.sol
│   │   ├── E3_Revocation.sol
│   │   └── E3_CumulativeDailyCap.sol
│   ├── mocks/
│   │   ├── MockPaidEndpoint.sol
│   │   ├── MockProvider.sol
│   │   └── MaliciousProvider.sol
│   └── delegation/
│       └── TwoHopDelegation.sol
├── test/
│   ├── BaseTest.sol
│   ├── policies/
│   │   └── [one test file per policy module]
│   ├── batch/
│   │   └── BatchCurve.t.sol
│   ├── rconf/
│   │   └── CalldataIdentical.t.sol
│   └── delegation/
│       └── CrossHopEscape.t.sol
├── snapshots/
│   ├── README.md
│   └── [committed gas snapshot files]
├── docs/
│   ├── methodology.md
│   ├── gas-results.md
│   └── case-study.md
├── foundry.toml
└── README.md
```

### A.3 — Configure `foundry.toml`

This is where reproducibility lives. The exact content matters:

```toml
[profile.default]
src = "src"
out = "out"
libs = ["lib"]
solc_version = "0.8.26"
optimizer = true
optimizer_runs = 200
via_ir = false
gas_reports = ["*"]

[profile.default.fuzz]
runs = 256

[fmt]
line_length = 100
tab_width = 4
bracket_spacing = false
```

Commit this. Any change to optimizer settings invalidates all previously recorded gas numbers — treat this file as a contract with yourself.

### A.4 — Set up the gas snapshot mechanism

```bash
forge snapshot --snap snapshots/baseline.snap
git add snapshots/baseline.snap && git commit -m "baseline snapshot"
```

Add a `Makefile` for repeatable runs:

```makefile
.PHONY: build test snap snap-check gas-report

build:
	forge build

test:
	forge test -vvv

snap:
	forge snapshot --snap snapshots/current.snap

snap-check:
	forge snapshot --diff snapshots/current.snap

gas-report:
	forge test --gas-report > docs/gas-results.md
```

### A.5 — Write the base test contract

`test/BaseTest.sol`:

```solidity
// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";

abstract contract BaseTest is Test {
    address constant USER = address(0xA11CE);
    address constant AGENT = address(0xB0B);
    address constant PROVIDER = address(0xC0C);
    address constant MALICIOUS = address(0xDEAD);

    function setUp() public virtual {
        vm.label(USER, "User");
        vm.label(AGENT, "Agent");
        vm.label(PROVIDER, "Provider");
        vm.label(MALICIOUS, "MaliciousProvider");
        vm.deal(USER, 100 ether);
        vm.deal(AGENT, 1 ether);
    }

    /// @dev Measure gas cost of a single call, asserting on whether it should
    /// revert. Returns gas used on the successful path.
    function measureGas(address target, bytes memory data, bool expectRevert)
        internal
        returns (uint256 gasUsed)
    {
        uint256 g0 = gasleft();
        (bool ok,) = target.call(data);
        uint256 g1 = gasleft();
        gasUsed = g0 - g1;
        if (expectRevert) {
            assertFalse(ok, "expected revert");
        } else {
            assertTrue(ok, "unexpected revert");
        }
    }
}
```

### A.6 — Reproducibility README

`snapshots/README.md` documents how to reproduce all numbers. Update this every time you record a snapshot. Sample content:

```markdown
# Gas snapshot reproduction

## Environment
- forge version: [paste output of `forge --version`]
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
```

### Verification checkpoint A

- [ ] `forge build` passes.
- [ ] `forge test` runs (even with zero tests).
- [ ] `foundry.toml` is committed with explicit solc version and optimizer settings.
- [ ] `make snap` produces a snapshot file under `snapshots/`.
- [ ] You can explain what every line of `foundry.toml` does.

---

## Section B — Minimum Escrow Contract

### B.1 — Design the storage layout

Decisions to make explicitly *before* writing code:

- `AgentPolicy` is per-agent, not global. Storage: `mapping(address => AgentPolicy) public policies`.
- `dailySpent` needs a reset rule. Decision: store `(uint128 dayStart, uint128 spent)`. When a settlement comes in on a new day (relative to `dayStart`), reset spent to zero and bump `dayStart`.
- Balance can be ETH for simplicity; an ERC-20 variant is added later for E2 token-amount tests.

### B.2 — Implementation skeleton

`src/Escrow.sol`:

```solidity
// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

contract Escrow {
    struct AgentPolicy {
        uint256 maxPerRequest;
        uint256 maxPerDay;
        uint256 validUntil;
        bool active;
    }

    struct DailyState {
        uint128 dayStart;
        uint128 spent;
    }

    address public immutable user;
    mapping(address => AgentPolicy) public policies;
    mapping(address => DailyState) public dailyState;
    mapping(address => uint256) public balances;

    error PolicyInactive();
    error PolicyExpired();
    error ExceedsPerRequest();
    error ExceedsDailyCap();
    error InsufficientBalance();
    error NotUser();

    constructor() {
        user = msg.sender;
    }

    modifier onlyUser() {
        if (msg.sender != user) revert NotUser();
        _;
    }

    function deposit(address agent) external payable {
        balances[agent] += msg.value;
    }

    function withdraw(uint256 amount) external onlyUser {
        // ... user-only withdrawal logic
    }

    function setPolicy(address agent, AgentPolicy calldata p) external onlyUser {
        policies[agent] = p;
    }

    function revokePolicy(address agent) external onlyUser {
        policies[agent].active = false;
    }

    /// @dev Single-payment settlement. Used for per-check gas measurement.
    function settle(address agent, address payable to, uint256 amount) external {
        AgentPolicy memory p = policies[agent];
        if (!p.active) revert PolicyInactive();
        if (block.timestamp > p.validUntil) revert PolicyExpired();
        if (amount > p.maxPerRequest) revert ExceedsPerRequest();

        DailyState memory d = dailyState[agent];
        uint256 today = block.timestamp / 1 days;
        if (today != d.dayStart) {
            d.dayStart = uint128(today);
            d.spent = 0;
        }
        if (uint256(d.spent) + amount > p.maxPerDay) revert ExceedsDailyCap();
        if (balances[agent] < amount) revert InsufficientBalance();

        d.spent += uint128(amount);
        dailyState[agent] = d;
        balances[agent] -= amount;

        (bool ok,) = to.call{value: amount}("");
        require(ok, "transfer failed");
    }

    /// @dev Batched settlement. Used for batch-curve measurement.
    function batchDeduct(
        address agent,
        address payable[] calldata recipients,
        uint256[] calldata amounts
    ) external {
        require(recipients.length == amounts.length, "length mismatch");
        AgentPolicy memory p = policies[agent];
        DailyState memory d = dailyState[agent];

        uint256 today = block.timestamp / 1 days;
        if (today != d.dayStart) {
            d.dayStart = uint128(today);
            d.spent = 0;
        }

        // Hoist invariant checks out of the loop where possible.
        if (!p.active) revert PolicyInactive();
        if (block.timestamp > p.validUntil) revert PolicyExpired();

        uint256 totalAmount;
        for (uint256 i = 0; i < amounts.length; ++i) {
            if (amounts[i] > p.maxPerRequest) revert ExceedsPerRequest();
            totalAmount += amounts[i];
        }
        if (uint256(d.spent) + totalAmount > p.maxPerDay) revert ExceedsDailyCap();
        if (balances[agent] < totalAmount) revert InsufficientBalance();

        d.spent += uint128(totalAmount);
        dailyState[agent] = d;
        balances[agent] -= totalAmount;

        for (uint256 i = 0; i < recipients.length; ++i) {
            (bool ok,) = recipients[i].call{value: amounts[i]}("");
            require(ok, "transfer failed");
        }
    }

    function getBalance(address agent) external view returns (uint256) {
        return balances[agent];
    }

    function getPolicy(address agent) external view returns (AgentPolicy memory) {
        return policies[agent];
    }
}
```

### B.3 — Unit tests for the escrow

`test/EscrowBasic.t.sol`. Cover at minimum:

- happy path: `deposit` → `setPolicy` → `settle` within cap → success.
- revert: not user → `setPolicy` reverts.
- revert: amount > maxPerRequest → `ExceedsPerRequest`.
- revert: cumulative > maxPerDay → `ExceedsDailyCap`.
- revert: past validUntil → `PolicyExpired`.
- revert: revoked → `PolicyInactive`.
- revert: insufficient balance → `InsufficientBalance`.
- state: daily counter resets on a new day (use `vm.warp`).

### B.4 — First gas snapshot

After Section B passes all tests:

```bash
make snap
git add snapshots/current.snap && git commit -m "phase-1 escrow snapshot"
```

### Verification checkpoint B

- [ ] All unit tests pass.
- [ ] You can describe in one sentence what each error condition checks.
- [ ] `dailySpent` reset behavior is verified by a test that uses `vm.warp` to cross a day boundary.
- [ ] First gas snapshot is committed.

---

## Section C — Policy Modules

The modules in Section A.2 each isolate one policy check. They are written as `library`-style internal functions (cheap to call) plus a thin wrapper contract that exposes them for isolated measurement.

### C.1 — The module pattern

Every policy module follows the same shape:

```solidity
library E2_ValueCap {
    error ExceedsValueCap();

    function check(uint256 amount, uint256 cap) internal pure {
        if (amount > cap) revert ExceedsValueCap();
    }
}

contract E2_ValueCap_Harness {
    function checkExternal(uint256 amount, uint256 cap) external pure {
        E2_ValueCap.check(amount, cap);
    }
}
```

The harness contract is what tests call — calling an external function gives clean, isolated gas numbers. The library is what the escrow integrates with later.

### C.2 — E1: Target allowlist

`src/policies/E1_TargetAllowlist.sol`:

```solidity
library E1_TargetAllowlist {
    error TargetNotAllowed();

    function check(mapping(address => bool) storage allowlist, address target)
        internal
        view
    {
        if (!allowlist[target]) revert TargetNotAllowed();
    }
}

contract E1_TargetAllowlist_Harness {
    mapping(address => bool) public allowlist;

    function setAllowed(address target, bool ok) external {
        allowlist[target] = ok;
    }

    function checkExternal(address target) external view {
        E1_TargetAllowlist.check(allowlist, target);
    }
}
```

### C.3 — E1: Selector allowlist

Same pattern, but check `bytes4 selector`.

### C.4 — E2: Three caps

- `E2_ValueCap`: pure check on `amount <= cap`.
- `E2_TokenAmountCap`: same but typed for ERC-20 amounts.
- `E2_ApprovalCap`: same but typed for `approve` calls; the point of having three is to measure that they have the same gas (or to discover that they do not, and explain why).

### C.5 — E3: Three stateful checks

- `E3_Expiry`: `block.timestamp <= validUntil`. One storage read.
- `E3_Revocation`: `active == true`. One storage read.
- `E3_CumulativeDailyCap`: read `dailyState`, compare, write `dailyState`. The most stateful sprint-scope check.

For `E3_CumulativeDailyCap`, write both the pure storage-read variant *and* a variant that performs the storage write inline (to measure the difference cleanly).

### C.6 — Integration into the escrow

Once the modules are validated in isolation, integrate them into `settle()` and `batchDeduct()`. The integration test should produce *the same gas overhead* per check as the isolated test — if it does not, you have an integration bug or an inlining surprise. Either way, find and explain it.

### Verification checkpoint C

- [ ] Eight policy modules exist as library + harness pairs.
- [ ] Each harness has its own focused test file.
- [ ] All policy unit tests pass.
- [ ] You understand why each policy is at its expressiveness level (E1/E2/E3).

---

## Section D — Per-Check Gas Measurement

### D.1 — Measurement methodology

For each policy:

1. Measure the **pass** path with a single isolated call to the harness.
2. Measure the **revert** path the same way.
3. For stateful checks, run the test once with cold storage and once with warm storage. The pattern:

```solidity
function test_E3_Expiry_Cold() public {
    uint256 g0 = gasleft();
    harness.checkExternal();  // first read → cold
    uint256 g1 = gasleft();
    emit log_named_uint("gas (cold)", g0 - g1);
}

function test_E3_Expiry_Warm() public {
    harness.checkExternal();  // warm the storage
    uint256 g0 = gasleft();
    harness.checkExternal();
    uint256 g1 = gasleft();
    emit log_named_uint("gas (warm)", g0 - g1);
}
```

4. Record the result in `docs/gas-results.md` with the date and snapshot commit hash.

### D.2 — Expected ranges

Use these as sanity checks. If a number is wildly off, do not "fix" the test — find out why.

| Check | Expected range (very rough) | Notes |
|---|---|---|
| `E1_SelectorAllowlist` (pass) | ~500–2,000 gas | stateless if hardcoded; mapping read if dynamic |
| `E1_TargetAllowlist` (pass) | ~2,500–4,500 gas | one cold mapping read |
| `E2_ValueCap` (pass) | ~200–500 gas | pure comparison |
| `E3_Expiry` (cold) | ~2,300–3,000 gas | one cold SLOAD + timestamp compare |
| `E3_Expiry` (warm) | ~150–300 gas | one warm SLOAD |
| `E3_Revocation` (cold) | ~2,300–3,000 gas | one cold SLOAD |
| `E3_CumulativeDailyCap` (cold, R) | ~2,500–3,500 gas | one cold SLOAD |
| `E3_CumulativeDailyCap` (cold, R+W) | ~22,000–24,000 gas | cold read + first SSTORE |
| `E3_CumulativeDailyCap` (warm, R+W) | ~5,500–6,500 gas | warm read + warm SSTORE |

If your numbers do not roughly land in these ranges, the most common causes are:

- forgot to disable the optimizer (or changed `runs` setting) — check `foundry.toml`.
- harness function is doing extra work — check it has nothing else in the body.
- measurement is including the call overhead — Foundry's per-test gas reporting subtracts this; manual `gasleft()` measurement does not. Pick one approach and stay consistent.

### D.3 — Snapshot collection

After all per-check measurements pass, run:

```bash
forge test --gas-report > docs/gas-report-raw.txt
make snap
git add . && git commit -m "phase-2 per-check gas"
```

Then write `docs/gas-results.md` as a human-readable table — this is what goes into the final report.

### Verification checkpoint D

- [ ] All eight policy modules have measured pass and revert gas.
- [ ] Stateful checks have both cold and warm numbers.
- [ ] You can explain every number to within ~100 gas of expected.
- [ ] `docs/gas-results.md` exists and is sortable.

---

## Section E — Batch Settlement Curve

### E.1 — The three baselines

To make the curve meaningful, measure each batch size *N* under three policy regimes:

- **Baseline 0:** plain `transfer` in a loop, no policy. This is the floor.
- **Baseline 1:** `batchDeduct` with E2-only checks (per-call value cap).
- **Baseline 2:** `batchDeduct` with full E3 (E2 + expiry + revocation + cumulative cap).

### E.2 — Test design

`test/batch/BatchCurve.t.sol`:

```solidity
function test_Batch_E3_FullStack() public {
    uint256[] memory sizes = new uint256[](6);
    sizes[0] = 1; sizes[1] = 2; sizes[2] = 5;
    sizes[3] = 10; sizes[4] = 20; sizes[5] = 50;

    for (uint256 i = 0; i < sizes.length; ++i) {
        // reset state between runs to avoid warm/cold cross-contamination
        _resetState();
        uint256 g0 = gasleft();
        escrow.batchDeduct(AGENT, _recipients(sizes[i]), _amounts(sizes[i]));
        uint256 g1 = gasleft();
        emit log_named_uint(string.concat("batch_size=", _toStr(sizes[i])), g0 - g1);
    }
}
```

Run this three times (one per baseline). Capture output and produce a CSV.

### E.3 — CSV format

`docs/batch-curve.csv`:

```csv
N,baseline_0_no_policy,baseline_1_e2_only,baseline_2_full_e3
1,21845,22431,24987
2,29102,30245,33112
...
```

Plot per-request gas (column / N) — that is the metric the analysis turns on.

### E.4 — The analytical note

A short paragraph in the final report:

> Per-request gas approaches a floor as N grows because the per-batch overhead (one transaction's base cost, one policy-state update for the cumulative cap) amortizes across N requests. The marginal cost per added request is dominated by the per-recipient `call` plus per-call value-cap check, which the cumulative cap does not need to re-amortize. At N = 50 the difference between baselines 0 and 2 reduces to approximately a [TBD-X]% premium for full E3 enforcement.

Fill in the percentage when you have numbers.

### Verification checkpoint E

- [ ] Three baseline measurements complete for N = 1, 2, 5, 10, 20, 50.
- [ ] CSV is produced and committed.
- [ ] The per-request curve clearly approaches a floor.
- [ ] You can name the floor's dominant components.

---

## Section F — Mock Contracts and r_conf Demonstration

This is one of the two highest-leverage sections of the project. Read F.3 very carefully before writing the test.

### F.1 — Mock surface

```solidity
contract MockPaidEndpoint {
    event PaidCall(address indexed caller, uint256 value, bytes32 indexed reqId);
    function pay(bytes32 reqId) external payable {
        emit PaidCall(msg.sender, msg.value, reqId);
    }
}

contract MockProvider {
    uint256 public reportedUsage;
    function setReportedUsage(uint256 u) external { reportedUsage = u; }
    function reportUsage(bytes32) external view returns (uint256) {
        return reportedUsage;
    }
}

contract MaliciousProvider {
    function reportUsage(bytes32) external pure returns (uint256) {
        return type(uint256).max / 2;  // wildly inflated
    }
}
```

### F.2 — The conceptual setup

The `r_conf` demonstration needs to show: **the escrow contract treats two settlement transactions identically when their on-chain-observable settlement fields match, even though their underlying off-chain truth differs.**

The "off-chain truth" in our setup is the value of `reportedUsage`. The "settlement fields" are the calldata to `escrow.settle()`. If the off-chain reporter ultimately translates `reportedUsage` into the same `amount`, the escrow cannot distinguish honest from malicious reporting.

### F.3 — The calldata-identical test

`test/rconf/CalldataIdentical.t.sol`:

```solidity
function test_HonestAndMalicious_AreIndistinguishableToEscrow() public {
    uint256 amountFromHonest = 0.5 ether;
    uint256 amountFromMalicious = 0.5 ether;  // the dishonest path,
                                              // having inflated reportedUsage upstream,
                                              // still translates to the same on-chain amount

    bytes memory honestCalldata = abi.encodeWithSelector(
        Escrow.settle.selector, AGENT, payable(PROVIDER), amountFromHonest
    );
    bytes memory maliciousCalldata = abi.encodeWithSelector(
        Escrow.settle.selector, AGENT, payable(PROVIDER), amountFromMalicious
    );

    assertEq(honestCalldata, maliciousCalldata,
        "calldata is bit-identical: contract cannot distinguish");

    // Both calls succeed against the escrow.
    (bool okHonest,) = address(escrow).call(honestCalldata);
    (bool okMalicious,) = address(escrow).call(maliciousCalldata);
    assertTrue(okHonest);
    assertTrue(okMalicious);
}
```

This is the **claim** version. Now write the **negation** version — the test that would *break* if the escrow could distinguish:

```solidity
function test_NoPolicyPrimitiveCanDistinguish() public {
    // For every public function on Escrow that the agent can call to settle,
    // demonstrate that none of them takes a parameter that would reveal the
    // off-chain truth distinguishing honest from malicious.
    // This is a documentation test: enumerate the surface.
}
```

The point of writing the negation is to force you to look at the escrow surface and ask: is there any field at all that could distinguish? If your answer is "no, and here is the enumeration," you have the empirical claim for r_conf.

### F.4 — Asserting the right thing — a warning

The most common failure here is to write a test that *appears* to demonstrate r_conf but actually demonstrates something weaker. Specifically:

- A test showing "malicious provider drains the account" only demonstrates the cumulative cap is missing, not r_conf.
- A test showing "the contract accepts both calls" without proving the calldata is identical is weaker.
- A test that uses `vm.expectEmit` to compare event payloads is showing the receipt-level identity, not the calldata-level identity.

The **claim** is: bit-identical calldata, divergent off-chain truth, contract accepts both. If your test does not literally assert calldata equality, rewrite it until it does.

### Verification checkpoint F

- [ ] `MockProvider` and `MaliciousProvider` exist as separate contracts.
- [ ] The calldata-identical test literally asserts `assertEq(honestCalldata, maliciousCalldata)`.
- [ ] Both calls succeed against the escrow.
- [ ] You have written, in your own words, in `docs/methodology.md`, a paragraph explaining why this test demonstrates r_conf non-enforceability.

---

## Section G — Cross-Hop Delegation Experiment

This is the other highest-leverage section. The contract logic here must be hand-designed; do not let AI auto-generate the delegation logic and trust it. AI is fine for the test scaffolding.

### G.1 — The design

A minimal two-hop model in plain Solidity:

```solidity
contract TwoHopDelegation {
    struct Permission {
        address parent;       // who delegated this permission (address(0) = the user)
        address subject;      // who holds this permission
        uint256 perCallCap;
        uint256 cumulativeCap;
        uint256 spent;
        bool active;
    }

    mapping(bytes32 => Permission) public permissions;

    function grant(
        address subject,
        uint256 perCallCap,
        uint256 cumulativeCap
    ) external returns (bytes32 permId) {
        permId = keccak256(abi.encodePacked(msg.sender, subject, block.timestamp));
        permissions[permId] = Permission({
            parent: msg.sender,
            subject: subject,
            perCallCap: perCallCap,
            cumulativeCap: cumulativeCap,
            spent: 0,
            active: true
        });
    }

    /// @dev LOCAL-ONLY enforcement. Checks only the immediate permission.
    function executeLocalOnly(bytes32 permId, address payable to, uint256 amount) external {
        Permission storage p = permissions[permId];
        require(p.subject == msg.sender, "not subject");
        require(p.active, "inactive");
        require(amount <= p.perCallCap, "per-call cap");
        require(p.spent + amount <= p.cumulativeCap, "cumulative cap");
        p.spent += amount;
        (bool ok,) = to.call{value: amount}("");
        require(ok);
    }
}
```

### G.2 — The escape scenario

Phrased explicitly: Account → A grants to B → B exceeds the budget A originally received from Account, *without violating B's own per-call or cumulative cap*.

The setup that makes this work:

- User grants A a permission of `perCallCap=1 ether, cumulativeCap=2 ether`.
- A grants B a permission of `perCallCap=1 ether, cumulativeCap=2 ether`.
- A also itself spends `1.5 ether`. Under local-only enforcement, A's spending and B's spending are tracked separately. B's permission knows about *B*'s cumulative spend, not about A's.
- B now spends `2 ether`. From B's perspective, B is within cap (B has spent 2 ether of B's allowed 2 ether). From A's perspective, A has spent 1.5 ether of A's allowed 2 ether. **Globally, the user has been charged 3.5 ether, exceeding the original 2 ether grant.**

That is the escape.

### G.3 — The escape test

`test/delegation/CrossHopEscape.t.sol`:

```solidity
function test_LocalOnly_AllowsEscape() public {
    // Setup
    vm.prank(USER);
    bytes32 permA = delegation.grant(AGENT_A, 1 ether, 2 ether);

    vm.prank(AGENT_A);
    bytes32 permB = delegation.grant(AGENT_B, 1 ether, 2 ether);

    // Phase 1: A spends 1.5 ether through permA.
    vm.startPrank(AGENT_A);
    delegation.executeLocalOnly{value: 0}(permA, payable(PROVIDER), 0.8 ether);
    delegation.executeLocalOnly{value: 0}(permA, payable(PROVIDER), 0.7 ether);
    vm.stopPrank();

    // Phase 2: B spends 2 ether through permB.
    vm.startPrank(AGENT_B);
    delegation.executeLocalOnly{value: 0}(permB, payable(PROVIDER), 1 ether);
    delegation.executeLocalOnly{value: 0}(permB, payable(PROVIDER), 1 ether);
    vm.stopPrank();

    // Total drained = 3.5 ether, despite original grant being 2 ether.
    // The escape succeeded under local-only enforcement.
    assertEq(PROVIDER.balance, 3.5 ether);
}
```

### G.4 — Pitfalls

1. **Make sure the test actually proves the escape.** If your test only shows B exceeded A's cap, it does not yet show the escape; it has to show that the *total amount paid out* exceeded what the *user* originally authorized.
2. **The funds source matters.** In the design above I omitted the actual funding flow for clarity. In your real contract, decide whether grants reference funds in an escrow (and the escrow checks the chain) or whether each layer holds its own balance. The cleanest demonstration is when funds are pulled from a single source, because then the global overspend is unambiguous.
3. **Do not let AI write the `grant` and `executeLocalOnly` logic for you and then trust it without reading.** Read the function line by line. If you cannot explain why the escape happens, the test is not yet a demonstration.

### Verification checkpoint G

- [ ] The two-hop delegation contract exists.
- [ ] The escape test passes and asserts on the total drained amount, not just on B's local state.
- [ ] You can explain in three sentences why local-only enforcement permits this escape.
- [ ] You have written a one-paragraph note in `docs/methodology.md` describing what compositional enforcement *would* need to track to prevent this — even though we are not implementing it.

---

## Section H — Case Study

### H.1 — Target selection (do this first)

Visit the following in order. Stop at the first one that has clean verified source you can read in a couple of hours:

1. **ZeroDev Kernel.** Check `https://github.com/zerodevapp/kernel`. Identify the `Session` or permission validator contracts. Find the deployed addresses on Etherscan/Basescan.
2. **Coinbase Smart Wallet.** Check the `coinbase-smart-wallet` repo. The spending-limit module is the relevant piece.
3. **Skyfire.** The KYA and payment contracts. Verify they are open and verified.

Lock the selection by recording in `docs/case-study.md`:

```markdown
# Case study target
- System: [name]
- Repository: [URL]
- Mainnet/L2 verified contracts:
  - [contract name]: [address] on [chain]
- Selected on: [date]
- Reason: [verified, complete, clear E1/E2/E3 use]
```

### H.2 — Source extraction

For each policy-bearing contract:

```bash
# Use cast or your block explorer of choice to pull source
cast etherscan-source --chain [chain] --etherscan-api-key $KEY [address] > src/casestudy/[name].sol
```

Or just paste from the verified-source page on Etherscan. Either way, commit the source you actually read — proxy upgrades happen and you want to record the version you analyzed.

### H.3 — Structural reading

For the selected system, fill in the following template in `docs/case-study.md`:

```markdown
## Policy mechanisms

### What this system can express
- E1 (access-level): [list with code references]
- E2 (transaction-level): [list]
- E3 (contextual/stateful): [list]

### What this system addresses on-chain
- r_rev: [yes / partial / no] — [evidence]
- r_scope (single-hop): [yes / partial / no] — [evidence]
- r_scope (cross-hop): [yes / partial / no] — [evidence]
- r_conf: [yes / partial / no] — [evidence]

### What this system delegates off-chain
- [list, e.g. dispute resolution, reputation, custody]

### Annotated gas magnitudes
Using our measured numbers, the system's per-settlement gas is approximately:
- per-call cap check: ~[X] gas (matches our E2 measurement)
- session validity check: ~[Y] gas (matches our E3 expiry + revocation)
- [etc.]

### Where the system aligns or diverges from our findings
- Aligned: [list]
- Divergent: [list, with explanation]
```

### H.4 — Producing the comparison table

The final artifact is one row added to the Section 5 gradient table — the deployed system placed into the same E1/E2/E3 × r_rev/r_scope/r_conf grid we used.

### Verification checkpoint H

- [ ] One case study target locked and source committed.
- [ ] `docs/case-study.md` populated according to the template.
- [ ] Comparison row added to the gradient table in the report.
- [ ] You can defend, in oral exam, the claim that this system's policy expressiveness falls at level [X].

---

## Section I — Report and Slides

### I.1 — Fill the gradient table

This is the central artifact. In the report, present it twice:

1. The qualitative version (which cell type each falls in: enforceable / partial / not enforceable). Same as Section 5 of the proposal.
2. The quantitative version (with measured gas numbers in the enforceable cells, with escape demonstration referenced in the cross-hop r_scope cell, and with the calldata-identical test referenced in the r_conf cells).

### I.2 — Report structure

Stay close to the proposal structure. The reader should be able to read the proposal first and then the report as a fulfilment of what the proposal promised. Specifically:

- §1 Motivation — unchanged from proposal.
- §2 Conceptual foundation — unchanged.
- §3 Research question and thesis — unchanged.
- §4 Methodology — describe what was actually done (refer to docs/methodology.md).
- §5 Results
  - §5.1 Per-check gas (table + analytical paragraph)
  - §5.2 Batch curve (CSV-derived plot + analytical paragraph)
  - §5.3 Cross-hop escape (test description + walkthrough of the scenario)
  - §5.4 r_conf calldata-identical demonstration (test description + the negation enumeration)
- §6 Case study (from docs/case-study.md)
- §7 Threat model — unchanged from proposal, possibly with adjustments from what the experiments revealed.
- §8 Limitations — be very honest here; the proposal already lists much of this.
- §9 Conclusion — close the loop: did the thesis hold?

### I.3 — Slides outline

10–14 slides for an oral defense:

1. Title + one-line positioning.
2. The absent-human framing (the hook).
3. The research question.
4. Conceptual foundation: B-I-P, R(P) decomposition, why on-chain can only enforce R(P) ceiling.
5. The gradient table (qualitative).
6. Per-check gas results.
7. Batch curve.
8. Cross-hop escape (walkthrough).
9. r_conf calldata-identical demonstration.
10. Case study comparison.
11. Threat model summary.
12. Limitations and future work.
13. Conclusion.
14. Backup slides: detailed gas numbers, contract source highlights, alternative case study options.

### I.4 — Oral defense rehearsal

Practice answering these specific questions, because they are the ones a careful examiner will ask:

1. **"Why is this question worth asking?"** — The absent-human story. Practice in 60 seconds.
2. **"What's new here? Two SoKs already classified this."** — The measurement axis: numbers are not in the SoKs.
3. **"Your r_conf claim — explain it without the word 'semantic'."** — Practice. The semantic-vs-syntactic phrasing is correct but jargon-heavy; you should be able to articulate it concretely.
4. **"Show me the cross-hop escape on the board."** — Be able to draw it in three boxes (User, A, B) and three arrows.
5. **"Could TEE / ZK / oracle solve r_conf? What does that cost?"** — Future-work answer, with cost vocabulary (TEE = trust the chip, ZK = compute overhead, oracle = trust the oracle).
6. **"You said cross-hop r_scope 'breaks.' What does breaks mean?"** — Show the test, walk through the numbers.
7. **"Could you have done this in [single semester / different framework / etc.]?"** — Frame as scope tradeoffs, not defensiveness.

### Verification checkpoint I

- [ ] Final report follows the structure in I.2.
- [ ] Slide deck follows the outline in I.3.
- [ ] You have rehearsed each of the seven questions in I.4 with someone else listening.
- [ ] The gradient table appears in both report and slides, with all sprint-scope cells filled.

---

## Section J — Common Pitfalls and Recovery

### J.1 — Gas snapshot drift

Symptom: numbers change between runs even though no code changed.

Possible causes:
- Foundry was updated → `foundryup` and re-snapshot. Note the version change in `snapshots/README.md`.
- Optimizer settings changed → check `foundry.toml` is committed.
- A test was added that warms storage before the measured call → re-order or reset.

### J.2 — A gas number does not match the expected range

Do not "make it match." Find out why.

1. Open the trace: `forge test --match-test [name] -vvvv`.
2. Look at the opcodes the call executed.
3. Compare against your mental model. If the call performed more SLOADs than you expected, the harness is doing something extra. If it performed fewer, the optimizer inlined something you did not expect.

### J.3 — AI-generated code passes tests but measures the wrong thing

This is the most dangerous pitfall. Symptoms:

- Two policies appear to have identical gas where you expected them to differ.
- The number is suspiciously round.
- The test passes but you cannot explain why.

Remedies:
- Read the AI-generated function line by line. If you cannot explain a line, delete it and write your own.
- Add an `emit log_named_uint` of an intermediate value, re-run with `-vvv`, and verify the intermediate value matches your expectation.
- For any test that produces a number that goes into the final report, you must be able to explain it at the opcode level.

### J.4 — Case study contract is not verified after all

You discover on Phase 0 (or worse, Phase 4) that the target's contracts are unverified or so heavily proxied that you cannot read them in the time available.

Recovery:
- Pivot to the next candidate the same day.
- If all three candidates fail, fall back to **MetaMask Delegation Toolkit** documentation + reference contracts in `https://github.com/MetaMask/delegation-framework`. This is documentation-rich and well-suited to a structural reading even without deployed addresses.

### J.5 — The cross-hop escape "doesn't work"

Symptoms: the test passes but the assertion is on the wrong thing, or you cannot get the total drain to exceed the original grant.

Diagnosis questions:
- Is your funds-source model unambiguous? (See G.4 pitfall 2.)
- Are A and B's spending tracked in separate `spent` slots? (They must be, for the escape to work.)
- Is your test actually charging real funds, or is it just bumping counters?

### J.6 — Over-engineering the policy modules

Symptoms: a module has more than ~10 lines of logic.

Remedy: the point of having eight isolated modules is to measure them cleanly. If a module is doing more than one thing, split it. If it is doing less than one thing (i.e., calling another module), inline it.

---

## Final note — the discipline you must keep

Three rules to put on the wall:

1. **A number you cannot explain at the opcode level is not yet a result.**
2. **A test that passes does not mean the test asserts what you think it asserts.** Read every assertion.
3. **The smart account replaces the absent human, not the credit card.** Every time you write something, ask: is it consistent with this thesis? If not, change one of them.
