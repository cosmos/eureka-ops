# Mainnet v2→v3 + SP1 v6.1 upgrade — readiness review & change plan

*Standalone document. Written so a reviewer with no prior context can read it top to bottom.*
*Date: 2026-06-17. Branch: `operations/2026-06-15-upgrade-v2-to-v3` (PR #19).*

---

## 1. Background

### 1.1 What the upgrade does

Two coupled changes to a live IBC bridge (`solidity-ibc-eureka`) on Ethereum **mainnet (chain 1)**:

1. **v2 → v3 core upgrade.** Authorization moves from per-contract OpenZeppelin `AccessControl` to a
   single shared OpenZeppelin **`AccessManager`** (whose admin is the existing `TimelockController`).
   Four core contracts are upgraded and handed to the manager: `ICS20Transfer`, `ICS26Router`, the
   `Escrow` beacon, and the `IBCERC20` beacon.
2. **SP1 v6.1 light-client migration.** The Tendermint light clients move onto SP1 v6.1 proof
   programs: fresh trusted state, fresh v6.1 verification keys, and a verifier *gateway* that routes
   v6.1.0 proofs to the real SP1 verifier.

The **core contract code is not in this repo** — it is the upstream dependency
`@cosmos/solidity-ibc-eureka`, pinned at tag **`solidity-v3.0.1`** (commit `04b9767`). This repo holds
the **operations/deploy tooling** (forge scripts, `just` recipes, runbooks, Python validators).

### 1.2 How it executes (the atomic cutover model)

- **Mandatory upgrade order:** `ICS20Transfer → ICS26Router → Escrow → IBCERC20`, enforced **on-chain**
  by an in-batch `TimelockController` predecessor (the router upgrade deletes v2 admin records the
  transfer upgrade authenticates against). Each `ICS20/ICS26` `upgradeToAndCall` carries
  `initializeV2(accessManager)`.
- **Atomicity:** all of the upgrade's timelock `execute(...)` calls are packed into **one**
  `MultiSendCallOnly.multiSend(bytes)` executed via **DelegateCall**, so the chain never settles in a
  mixed v2/v3 state. If any sub-call reverts, the whole bundle reverts (no partial upgrade).
- **Governance:** every privileged action is a `TimelockController` operation scheduled and executed
  by a **Safe multisig**. On mainnet the Safe is **4-of-7 hardware wallets** and the timelock delay is
  **72 hours**, so a second round is impractical — the rate-limiter re-grant and any role grants are
  **folded into the single round** (scheduled in the same window, packed into the same atomic execute).

### 1.3 Mainnet specifics & key addresses

| Thing | Value |
| --- | --- |
| Governance Safe (proposer/executor) | `0x7B96CD54aA750EF83ca90eA487e0bA321707559a` — **4-of-7** |
| TimelockController (AccessManager admin) | `0xb3999B2D30dD8c9faEcE5A8a503fAe42b8b1b614` — delay **72 h** |
| ICS26Router proxy / ICS20Transfer proxy | `0x3aF134307D5Ee90faa2ba9Cdba14ba66414CF1A7` / `0xa348CfE719B63151F228e3C30EB424BA5a983012` |
| ID/ERC20 customizer | `0x4b46ea82D80825CA5640301f47C035942e6D9A46` — **a 2-of-5 Safe** |
| MultiSendCallOnly (DelegateCall target) | `0x9641d764fc13c8B624c04430C7356C1C7C8102e2` |
| SP1 v6.1 Groth16 gateway → real verifier | `0x397A5f7f…` → `0xb69f2584…` (`VERSION v6.1.0`, routing selector `0x4388a21c` †) |

† The routing selector `0x4388a21c` is **derived**, not a fixed gateway constant — it is the first 4
bytes of the v6.1.0 verifier's `VERIFIER_HASH` (`check-sp1-verifier.sh:93`). Confirm it at cutover.

**Migrate set (decision):** `cosmoshub-0` + `ledger-mainnet-1` only; **`client-4` is dropped** (not
relayed in production). Its escrow is still upgraded by the core beacon upgrade.

### 1.4 What has already been done

- **Executed end-to-end and verified on Sepolia testnet** (atomic cutover, `verify-deployment`,
  `check-sp1-verifier`, role validation 32/32).
- **Mainnet pre-upgrade state confirmed on-chain**; the operational decisions are locked (client-4
  drop, SP1 tag, source-chain ids, the customizer being a Safe, the Ledger proposer).
- **Tooling hardened:** Ledger proposer signing, a packer schedule-state guard, an admin-revoke guard,
  and an independently-reviewed signer verification tool + checklist.
- **Two mainnet-fork rehearsals, both green:** a standard timelock rehearsal and a staged-v6.1 variant
  (migrating to the real v6.1 vkeys + gateway; `check-sp1-verifier` confirms routing).

Authoritative records: `RECORD.md` (this directory), `runbooks/upgrade-v2-to-v3.md` (procedure),
`CUTOVER-RUNSHEET.md` (the 72 h execution sheet), `SIGNER-CHECKLIST.md` (signer verification).

---

## 2. Review process

The readiness report above was given to **two independent reviews**:

- **Review A** — a focused 6-agent pass on the runbooks + scripts.
- **Review B** — a 33-agent, 7-dimension pass: each material finding re-checked by an adversarial
  skeptic, plus a "coverage critic" hunting for whole surfaces the dimensions missed.

Every finding below was then **re-validated against the actual code and on-chain state** (adversarial
stance — including toward the reviewers' own claims). Verification results are stated inline.

---

## 3. Conclusion

**Not ready to schedule or execute until the §5.1 "must-resolve" items are closed. This is not a
"go."** The upgrade is mechanically sound and well-instrumented — the core is *verified, not asserted*
— and it is close-able after the planned fixes; but several of those fixes are **blockers, not notes**.

Both reviews independently concluded that no bundle-bricking encoding defect exists: the **core
timelock/MultiSend execution is atomic and fail-closed** — a bad bundle reverts wholesale (no fund
loss, no silent corruption; worst case is a wasted 72 h round) — and the upstream pin matches the
audited tag byte-for-byte. **But not every path is fail-closed:** several operational paths can still
**false-green** (a check passes while something is wrong) or cause an **outage** (the early relayer
cut). Those — plus stuck in-flight packets and trust roots no tooling checks — are the real work.

Notably, when I verified the scariest "trust-root" findings on-chain, **the current state is clean** —
they are flagged because nothing *asserts* them, not because they are wrong today (see §5.4).

---

## 4. Independently verified as solid (no change needed)

- **Atomic MultiSend encoding is byte-correct**; packer/ordering tests pass; the `ICS20→ICS26`
  predecessor ordering reverts `TimelockUnexecutedPredecessor` if mis-ordered — **proven on a mainnet fork**.
- **Storage layout is byte-compatible v2.0.1 → v3.0.1** (existing clients, rate-limits, daily-usage
  preserved); `initializeV2` runs once via `reinitializer`; beacon mechanics correct.
- **AccessManager bootstrap leaves the timelock as sole ADMIN**, fail-closed defaults; the
  selector→role table is byte-correct.
- **Safe EIP-712 signing math is correct**; the signer tool recomputes the hash from first principles
  and rejects any DelegateCall whose target ≠ the canonical MultiSend.
- **Pin integrity exact:** `package.json` = `bun.lock` = tag commit `04b9767`; all contract files
  byte-match the tag.
- `VerifyDeployment` asserts a strong end-state (authority, beacon impls, the target-function-role
  table, SP1 vkeys/verifier). **Caveat:** for role *membership* it only checks that the JSON's expected
  holders are **present** (`_assertRole` per holder) — it does **not** prove exact membership or the
  **absence of unexpected/stray holders**, and it is structurally blind to the rate-limiter role (F3).
  Exact membership (via `RoleGranted`/`RoleRevoked` event reconstruction) is `validate-v3-roles.py`'s
  job, not `VerifyDeployment`'s.

---

## 5. Findings (consolidated, deduped, with verification)

Severity labels are the reviewers'. Each finding states what I confirmed.

### 5.1 Must resolve before scheduling

- **F1 — Relayer is cut to v6.1 ~72 h too early → multi-day outage of both live channels. `HIGH` (new).**
  The runsheet bumps the prod relayer to the v6.1 build in **Phase A**, but the on-chain clients keep
  the old vkey until the **Phase C** execute 72 h later. In between, every `updateClient`/`recvPacket`/
  `ackPacket` reverts on a vkey mismatch — a multi-day outage, not the "short halt" the runsheet implies.
  *Verified:* structurally correct from the runsheet ordering; trusted-state generation is
  version-independent so there is no technical reason for the early cut.

- **F2 — `check-sp1-verifier` discards the gateway route `frozen` flag → false-green. `MEDIUM` (new).**
  *Verified in code:* `scripts/check-sp1-verifier.sh:94` reads `routes(bytes4)(address,bool)` and pipes
  through `head -1`, keeping only the address. A frozen route reverts every proof
  (`SP1VerifierGateway`), yet would pass this gate. *Verified on-chain:* the live route is
  `(0xb69f2584…, false)` — **not frozen today**, so no live problem; the gate is the gap.

- **F3 — Rate-limiter re-grant is invisible to every automated check → false-green. `MEDIUM` (both reviews).**
  The mainnet `1.json` `.accessManagerRoles` has **no `rateLimiters` key**, so `validate-v3-roles.py`
  compares role 5 against an *empty* set — an omitted holder passes. `VerifyDeployment` is structurally
  blind to role 5; CI runs only `VerifyDeployment`. *Verified:* a byte-inconsistent grant **is** caught
  (the packer's byte-match guard reverts); the live vector is **omission** of a holder/escrow.
  *Nuance I confirmed:* `GrantRateLimiterRole.sol` wires `setTargetFunctionRole(escrow)` **and**
  `grantRole(holder)` in one atomic `multicall`. But because `RATE_LIMITER_ROLE` is **manager-wide**,
  membership completeness does **not** imply wiring completeness — granting the role to every holder
  satisfies the membership set while an *intended* escrow can stay unwired (e.g. all grants ran for one
  escrow). Membership and per-escrow wiring are **independent**, so the fix is pre-staging the expected
  holders (`rateLimiters`, membership) **and** a per-escrow wiring gate (`rateLimitedEscrows`).

- **F4 — The TimelockController's *own* roles are never verified. `HIGH` (new, coverage critic).**
  The entire upgrade trusts `0xb3999B2D` as a root; no tooling checks its role config. The repo's only
  timelock deployer is testnet-only. *Verified on-chain (clean today):* `EXECUTOR(addr0)=false` (the
  open-executor front-run DoS is **not** exploitable), `getMinDelay()=259200`, Safe holds
  PROPOSER/EXECUTOR/CANCELLER, `DEFAULT_ADMIN(Safe)=false`, timelock self-admins. **The risk is the
  *absence of an assertion*, not a live defect** — the "front-run DoS root" framing is overstated.

- **F5 — In-flight IBC packets during the broken-relaying window — zero coverage. `HIGH` (new, coverage critic).**
  No runbook reasons about packet state. Packets un-acked when relaying breaks stall; escrowed funds
  stay locked; a packet whose timeout elapses inside the window cannot be timed-out until after cutover.
  *Verified:* storage survives the beacon upgrade so nothing is *lost*, but there is no quiesce/drain
  plan. Directly coupled to F1.

### 5.2 Should close before the window

- **F6 — Two timelock-delay sources can desync. `MEDIUM` (new).** *Verified in code:* the rate-limiter
  grant path (`deploy.just:486-493`) reads `timelock_delay` from the generated `out/scriptHelper.json`,
  while the core path (`upgrade.just`) reads `getMinDelay()` **live**. A stale file (the local copy is a
  testnet `60`) makes the grant `schedule` revert `TimelockInsufficientDelay`, or — if larger — makes
  the grant `Ready` later than the core ops so the atomic execute reverts after the full 72 h.
  *Correction:* the reviewer called it a "committed cache"; the file is **gitignored / not tracked** —
  it is a stale-*regeneration* risk, not a committed one.

- **F7 — Step 6 is ~10 separate 4-of-7 hardware ceremonies. `MEDIUM` (new + Review A).** Schedules
  cannot be folded; ~40 device confirmations; one mis-scheduled/skipped/duplicate/wrong-nonce op
  silently reverts the execute 72 h later. *Verified:* the packer proves *included* ops are pending but
  cannot prove *completeness* (an omitted op is never examined).

- **F8 — The exact mainnet fold was never rehearsed. `MEDIUM` (new).** *Verified:* testnet RATE_LIMITER
  was empty; the best rehearsal folded **1** representative grant (7 ops). Mainnet packs **10** (4 core
  + 2 migrations + **4** rate-limiter grants). The 4-grant fold + 10-op bundle are unexercised.

- **F9 — Bundle gas unmeasured; `safeTxGas` not asserted `== 0` on the proposer side. `MEDIUM` (new).**
  If `safeTxGas` is non-zero and under-estimates, `execTransaction` *succeeds* (nonce consumed,
  `ExecutionFailure`) while the upgrade does not land. *Verified:* `signer-verify.sh` already asserts
  `safeTxGas==0` (signer side); the gap is the **proposer/propose path** and **measuring bundle gas vs
  the block limit**.

- **F10 — Safe owner set + threshold assumed, never asserted. `MEDIUM` (new).** *Verified on-chain:*
  threshold 4, 7 owners (correct) — just unasserted by tooling.

- **FA1 — `check-relayer-vkeys` default-checks all clients incl. dropped `client-4`. (Review A).**
  *Verified:* `scripts/check-relayer-vkeys.sh:102` loops all `.light_clients[]`; with `client-4` left
  pre-v6.1 it will FAIL — risking an aborted-correct-setup or a "fix" that wrongly stages client-4. The
  script already supports `--client`; the runsheet doesn't use it and the "one call validates all"
  comment is now wrong.

- **FA2 — `deploy-fresh-light-client-state` has no `client_id`↔`SRC_CHAIN` invariant. (Review A).**
  *Verified:* `deploy.just:259` reads `client_id` interactively, `SRC_CHAIN` from env, no cross-check —
  a swapped pair writes valid-looking *wrong-source* trusted state, surfacing only when a proof reverts
  post-cutover.

- **FA3 — `signer-verify.sh` warns (not REJECTs) on a non-`execute` MultiSend sub-call; exits 0 on
  duplicate same-nonce without `--expect`. (Review A).** *Verified:* `signer-verify.sh:88` is `warn`;
  the `n>1` path prints STOP but does not force a non-zero exit.

- **FA4 — Runsheet escrow-init prints calldata but does not execute. (Review A).** *Verified:*
  `CUTOVER-RUNSHEET.md:184` runs a `-params` recipe (prints, broadcasts nothing); the submission step
  isn't shown.

### 5.3 Live-window footguns (verified low, but real)

- **No abort/cancel path** despite the Safe holding `CANCELLER` — a cancel-during-delay flow and a
  "cannot execute after delay" decision tree would otherwise be improvised under pressure.
- **Stale `.eureka-env`** holds a hot testnet `PRIVATE_KEY` the runsheet never clears; Phase-A
  deploys/escrow-inits use it (gitignored, non-custodial, prompts on use — hence low).
- **On-chain pause ≠ off-chain halt** — unpause is a 4-of-7; don't reflexively pause during the window.
- **Trusted-state staleness** — safe today (14 d trusting period, ~11 d margin) but add a Phase-C
  pre-execute freshness check in case the schedule slips.
- **Packer byte-match guard skips when no RPC** (`assert_pending` returns 0) — make RPC mandatory and
  treat the "SKIPPING" warning as a stop.
- **Beacon recipes lack an impl-changed guard** — could encode a no-op self-upgrade if step 4 is
  half-done; decode every upgrade payload before proposing.
- **Pre-execute guard uses `isOperationPending`, not `isOperationReady`** — add a readiness check
  immediately before broadcast.
- `signer-verify` multiSend-decode aborts before the REJECT banner (manual mode only; fail-safe).
- **`client-4`** still in `1.json` (intentionally dropped) — fine *as long as it is never touched*.

### 5.4 Findings I assessed as overstated, refuted, or already-covered

- **F4 "front-run/DoS root":** acute risk **refuted** — `EXECUTOR(addr0)=false` on-chain. The
  assertion is still worth adding; the danger framing is not warranted today.
- **F2 frozen flag:** route **not frozen** on-chain — false-green gap is real, live exploit is not.
- **F6 "committed cache":** the file is **not tracked**; staleness risk is real, the "committed" detail is wrong.
- **F9 `safeTxGas`:** the **signer side already asserts it**; only the proposer side + gas measurement remain.
- **F3 wiring (corrected from my earlier draft):** I initially wrote "membership ⟺ wiring" under the
  bundled recipe — **that's wrong.** `RATE_LIMITER_ROLE` is manager-wide, so membership can be complete
  while an intended escrow stays unwired; the two are independent checks. A *conditional* per-escrow
  wiring gate is the correct fix, not a blunt one (a blunt gate would break the by-design
  pre-grant/testnet-empty case where escrows are intentionally unwired).

---

## 6. Planned changes

Mechanical, low-risk, **no contract changes** — only ops tooling, validators, deployment JSON, and
runbooks. Each item links to the finding(s) it closes.

> **Implementation status (2026-06-17):** §6.1–§6.3 **implemented and tested** — `verify-roots.sh` now
> **13/13** against mainnet (incl. the stray-`DEFAULT_ADMIN` event scan from block `22188631` and a
> client-`0..19` escrow probe — **no stray admin, no stray escrow**), `validate-v3-roles` still 32/32 on
> testnet. §6.4 **drafted into `CUTOVER-RUNSHEET.md`** and corrected to the real operational model
> (confirmed with the owners): there is **no clean relaying halt** — the prod relayer stays on the *old*
> build through the delay and is **upgraded after the execute** (step 8a, a brief restart, not a 72 h
> outage); the Phase-A lockstep gate runs against the **available new-build proof-api** (F1); packet quiesce
> is **best-effort** (in-flight packets are delayed-not-lost across the short gap, F5); plus the explicit
> escrow-init submission (FA4) and a cancel/abort tree. §6.5 **done**: the exact **10-op fold** rehearsed on
> a mainnet fork (≈ **616k gas**, ~1 %; all 4 grants land). **The §8 owner decisions are now resolved** (see
> §8). Remaining is the live cutover itself + a few cutover-time `‹…›` endpoints.

### 6.1 Code fixes (one-liners / small)

| Change | File | Closes |
| --- | --- | --- |
| Read both `routes()` returns; **fail if `frozen == true`** | `scripts/check-sp1-verifier.sh` | F2 |
| Non-`execute` MultiSend sub-call → **REJECT** (not warn); duplicate same-nonce → **non-zero exit**; add `--expect-subcalls <N>` | `scripts/signer-verify.sh` | FA3, F7 |
| Make RPC **mandatory** in the packer (no silent skip of the pending guard); add an `isOperationReady` check before broadcast | `safe.just` | footguns |
| Assert `timelock_delay == getMinDelay() == 259200` before generating grant blobs | `deploy.just` | F6 |
| Accept `CLIENT_ID` env (non-interactive) and **hard-fail if the client's recorded source ≠ `SRC_CHAIN`** | `deploy.just` `deploy-fresh-light-client-state` | FA2 |
| **Make `discover-v2-roles.py` fail-closed** — `sys.exit(1)` when `issues>0` (today it prints `REVIEW NEEDED` and exits 0); runsheet requires a clean exit | `scripts/discover-v2-roles.py` | F3, F7, FA1 (completeness) |

*Note on F9:* the proposer side already hardcodes `safeTxGas:"0"` (a literal in `safe-propose.sh`) and
`signer-verify.sh` already rejects non-zero — so a propose-path assertion is redundant. The substantive
F9 work is the **bundle-gas measurement** (§6.5), not an assertion.

*Optional (minor):* a structural **"new beacon impl ≠ current on-chain beacon impl"** guard on the
beacon upgrade recipes would turn the "forgot step 4 → no-op self-upgrade" footgun from procedural
("decode every payload") into structural, mirroring the existing ERC1967 `_require-already-access-managed`.

### 6.2 New verification tooling

- **A re-runnable T-minus on-chain assertion script** (`scripts/verify-roots.sh` or a `just` recipe)
  that checks, against mainnet: the timelock roots (`EXECUTOR(addr0)=false`, `getMinDelay()=259200`,
  PROPOSER/EXECUTOR/CANCELLER = the Safe, **no stray `DEFAULT_ADMIN`** via `RoleGranted`/`RoleRevoked`
  event reconstruction); the Safe (`getOwners()` = the 7 expected, `getThreshold()=4`); and the gateway
  route (`frozen == false`). Turns "manually verified once" into a gate. **Closes F4, F10**, backstops F2.
- **Escrow-set enumeration** (closes the blind spot the F3 fix rests on): `discover-v2-roles.py` and
  `initialize-known-escrows` only probe the **3 JSON clients**, so a rate-limiter holder on an escrow
  for a client *not* in the JSON stays invisible (and `RECORD.md`'s "exactly 3 escrows" is prose).
  Assert the on-chain non-zero escrow set **equals the 3 known**. *Mechanism caveat:* the mainnet client
  ids are **custom strings** (`cosmoshub-0`, `ledger-mainnet-1`, `client-4`), **not** a `client-N`
  sequence — so enumerate **event-based** (client/escrow-creation logs, as `discover` already does), not
  a numeric `getNextClientSeq()` loop. Confirm the enumeration scheme on-chain before wiring it in.
- **Record the evidence, not just the assertion:** capture the exact `cast` commands + raw outputs for
  the "clean today" checks (incl. the timelock event-reconstruction from-block) into `RECORD.md`, so a
  second reviewer reproduces them — the same bar applied to the relayer-set snapshot.

### 6.3 Deployment-JSON pre-staging (`deployments/mainnet/1.json`)

- **`.accessManagerRoles.rateLimiters`** — pre-stage the freshly-discovered holders so
  `validate-v3-roles.py` **hard-fails on an omitted grant** (the live vector). **Closes F3 (membership).**
- **`.accessManagerRoles.rateLimitedEscrows`** = `["cosmoshub-0","ledger-mainnet-1"]` — a *conditional*
  wiring gate in `validate-v3-roles.py` section D: for listed escrows, assert `setRateLimit` is wired to
  `RATE_LIMITER(5)` (hard fail); others stay informational so testnet stays 32/32. **Closes F3 (wiring).**
- **`.light_clients[].proofApiSrcChain`** (`cosmoshub-0→cosmoshub-4`, `ledger-mainnet-1→ledger-mainnet-1`)
  — consumed by FA2's invariant. Ignored by the bootstrap. **Pin these values to `RECORD.md` "Light
  clients & escrows"** (which traces to the prod relayer config) so they cannot drift from the config
  they mirror.

### 6.4 Runbook / runsheet sequencing (`CUTOVER-RUNSHEET.md`, `upgrade-v2-to-v3.md`)

- **Relayer cut → Phase C** (under halt). Explicit close condition — a canary only proves the
  *build/vkeys*, **not** that prod was cut correctly: **(a)** run the lockstep gate against a **canary /
  non-live proof-api before scheduling**; **(b)** cut the **prod** relayer under halt in Phase C;
  **(c)** re-run **`check-relayer-vkeys --client … against prod` immediately before execute/resume**.
  **Closes F1.** *(Needs relayer/infra owners' input on the canary — see §8.)*
- **Packet quiesce step** in Phase A for both channels; **confirm no packet timeout falls inside the
  window**; document the post-cutover catch-up / timeout / refund procedure. **Closes F5.**
- **Scope `check-relayer-vkeys`** to the migrated set (`--client cosmoshub-0` with `SRC=cosmoshub-4`,
  `--client ledger-mainnet-1` with `SRC=ledger-mainnet-1`); fix the "validates all" comment; note a
  client-4 FAIL is spurious. **Closes FA1.**
- **Pinned nonce layout + the expected 10-sub-call count** (4 core + 2 migrations + 4 rate-limiter),
  a per-schedule `--expect` table, and "no unrelated Safe txs queued during the window." **Closes F7.**
- **Explicit escrow-init submission** (the `cast send` per escrow + confirm `authority()`). **Closes FA4.**
- **A cancel/abort decision tree** (the Safe holds `CANCELLER`): cancel-during-delay vs
  resume-v2-and-stand-down vs cancel+reschedule. **Closes the footgun.**
- **`.eureka-env` hygiene** T-minus item (unset `PRIVATE_KEY`; confirm env = mainnet/chain 1);
  **pause ≠ halt** clarification; **trusted-state freshness** pre-execute check.
- **Strengthen the signer-prep gate** (freeze `signer-verify.sh`, post its `sha256`, generate the
  expected-hash table from source, **second reviewer regenerates and matches**). **Closes Review A F4.**

### 6.5 Additional fork rehearsal

- Rehearse the **exact 10-op mainnet bundle** on a mainnet fork (4 distinct rate-limiter grant op-ids,
  confirming the double `setTargetFunctionRole` lands), and **measure bundle gas vs the block limit**.
  **Closes F8, F9 (gas).**

### 6.6 What this does *not* change

- The atomic execute path / packer wire format, the upgrade ordering, the Safe hash math, the
  AccessManager bootstrap, and the `solidity-v3.0.1` contracts — all independently verified (§4). No
  new core fork rehearsal of the *mechanical* path is needed; only the additions above are re-validated.

---

## 7. Suggested sequencing

1. **Highest-leverage, lowest-risk first:** §6.1 code fixes + §6.2 assertion script + §6.3 JSON
   pre-staging. All locally testable (re-run the `signer-verify` battery and `validate-v3-roles testnet`
   → still 32/32).
2. **Runbook sequencing** (§6.4) — the relayer-timing and packet-quiesce rewrites are the highest-value
   here.
3. **The 10-op fork rehearsal** (§6.5) — the final end-to-end confirmation.

---

## 8. Open decisions — RESOLVED (2026-06-17)

- **Relayer canary (F1) — resolved.** There **is** an accessible new-build proof-api; the Phase-A lockstep
  gate runs against it. And the model is corrected: there's **no clean halt** — the prod relayer stays on
  the *old* build through the delay and is *upgraded* after the execute (a brief restart, not a 72 h
  outage). Cutover-time `‹…›` values: the new-build proof-api endpoint and the prod endpoint.
- **Packet quiesce (F5) — resolved.** No guarantee of zero in-flight packets is required: with the short
  gap (relayer restart, not days) in-flight packets are **delayed-not-lost** and catch up post-8a; a
  timeout in the gap is refunded once relaying resumes. Quiesce is **best-effort**. Owner for the relayer
  upgrade + catch-up watch: `‹…›` (cutover-time).
- **Stray-admin check (F4) — resolved.** Timelock deploy block = **`22188631`** (creation tx
  `0x95d263cf…`); `verify-roots.sh` reconstructs `DEFAULT_ADMIN` from there and finds **no stray admin**.
- **Proposer / SP1 tag / client-4 — decided earlier.** Proposer = the Ledger at `MNEMONIC_INDEX=1`; final
  `v2.0.0` at the rc.2 commit (vkeys fixed/known); `client-4` dropped.

**Remaining is operational, not decisional:** the live SP1 staging + scheduling + execute, the coordinator's
signer-hash table (generated + second-reviewed at proposal time), and filling the `‹…›` endpoints. The §5.1
must-resolve items are now all **implemented or resolved**.
