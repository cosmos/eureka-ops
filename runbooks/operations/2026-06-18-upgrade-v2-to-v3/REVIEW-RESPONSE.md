# Review response & re-validation guide

*For the reviewers who produced Review A (6-agent), Review B (33-agent), and the two `READINESS-REVIEW.md`
feedbacks. Maps every finding to its resolution, the commit that made it, and a concrete way to re-validate.*
*Branch `operations/2026-06-18-upgrade-v2-to-v3`. Date 2026-06-17.*

---

## TL;DR

- Addresses **all findings from Review A, Review B (F1–F10 + footguns), and the two `READINESS-REVIEW`
  feedbacks**, plus **Round 2** (this section's reviewers): a real bug they caught (**F3-keys-wiped**), the
  doc contradictions, and the coverage-critic gaps **C1–C12** — each now fixed or explicitly scoped (see
  "Round 2" below and the C1–C12 table). *Earlier drafts of this doc over-claimed "every actionable finding";
  that was wrong and is corrected here.* No contract changes.
- Two findings were **owner-clarified**: **F1 relayer timing** (no clean halt — relayer stays on the old
  build through the delay, *upgraded* after the execute; brief restart) and **F5 packets** (delayed-not-lost
  ⇒ best-effort quiesce).
- I **corrected three of my own errors** caught across rounds (the "membership ⟺ wiring" claim; the
  "amber-go" wording; **the F3 keys nested under `.accessManagerRoles` were silently wiped by the deploy** —
  now moved top-level and **proven to survive** a fork deploy), and **pushed back** where findings were
  overstated (F4 front-run DoS not exploitable; F2 route not frozen; F6 file not a "committed cache").
- Empirical evidence, re-runnable: **`verify-roots.sh` 17/17** on mainnet (with `FROM_BLOCK=22188631`),
  **`validate-v3-roles` 32/32** on testnet, the **exact 10-op fold** on a mainnet fork (**≈ 616k gas**), the
  `signer-verify` attack battery, and the **F3-survives-deploy** fork test.

## Commits to review (newest first)

| Commit | What it covers |
| --- | --- |
| *(round 2 — this batch)* | F3 keys → top-level (proven to survive deploy); verify-roots C1/C2 (customizer Safe, stray CANCELLER/PROPOSER); doc contradictions (line 11, canonical halt, RECORD :196, orphan ref); C3/C4/C5/C7/C9/C10/C12 runbook; REVIEW-RESPONSE corrections |
| `3a86cc5` | review-response doc + 3 footgun items (env hygiene, pause≠halt, trusted-state) |
| `629ca1c` | corrected relayer/halt model (F1/F5); `verify-roots` from-block + escrow probe (F4, escrow blind spot) |
| `1e5ca10` | 10-op fold rehearsal (F8/F9) + runbook sequencing (F1/F5/F7/FA4 + cancel tree) |
| `823af00` | the two `READINESS-REVIEW` feedbacks (amber-go, fail-closed, VerifyDeployment scope, membership⟺wiring, canary, …) |
| `22ef1f0` | the §6.1–6.3 hardening batch (F2/F3/F4/F6/F9/F10/FA1/FA2/FA3 + `verify-roots.sh` + JSON pre-stage + validate gate + discover fail-closed + RPC/ready guards) |
| `8414c36` | signer verification tool + checklist (predates the reviews; underlies F7/FA3) |
| `568ed99` | ledger proposer + timelock-pending & admin-revoke guards (predates the reviews) |

`git diff 188912e..HEAD` is the full delta (≈19 files, **no contract changes**).

---

## One-shot re-validation (run these — all literally runnable)

```bash
H1=0x4b46ea82D80825CA5640301f47C035942e6D9A46; H2=0x64259f722A0868CCf58A935C61A292cEA9dF035a

# 1. Trust roots (17/17). FROM_BLOCK is REQUIRED — without it the stray-admin/CANCELLER/PROPOSER scan is
#    skipped and you get a smaller count. Expect "ALL TRUST-ROOT CHECKS PASSED".
ETH_RPC=<mainnet> FROM_BLOCK=22188631 scripts/verify-roots.sh mainnet 1

# 2. Role validation incl. the conditional rate-limiter wiring gate (expect "32 passed, 0 failed")
ETH_RPC=<testnet> python3 scripts/validate-v3-roles.py testnet 11155111

# 3. Discovery is fail-closed: a missing holder / unidentified role => non-zero exit
ETH_RPC=<mainnet> ETHERSCAN_API_KEY=<key> python3 scripts/discover-v2-roles.py mainnet 1; echo "exit=$?"

# 4. Signer tool attack battery (manual mode, needs only cast) — each bad case prints REJECT, exit 1:
G=0x7B96CD54aA750EF83ca90eA487e0bA321707559a
# (a) delegatecall to a non-MultiSend target:
scripts/signer-verify.sh 1 $G --to 0x000000000000000000000000000000000000dEaD --data 0x12345678 --operation 1 --nonce 1
# (b) build a schedule(grantRole(ADMIN/role 0, attacker)) and feed it --operation 0 -> "grants role 0" REJECT
# (c) a multiSend with --expect-subcalls 10 vs an actual 1-subcall bundle -> count-mismatch REJECT
# (full reproducible battery in the earlier validation run / git history)

# 5. The exact 10-op mainnet fold on a fork (4 core + 2 migrations + 4 rate-limiter grants)
RL_GRANTS="cosmoshub-0:$H1,cosmoshub-0:$H2,ledger-mainnet-1:$H1,ledger-mainnet-1:$H2" \
SP1_CLIENT_IDS="cosmoshub-0,ledger-mainnet-1" \
  bash scripts/shadow-v2-to-v3-timelock-rehearsal.sh 1 mainnet shadow-mainnet <fork-rpc>
#   -> "10 total sub-calls", safeTxHash matches on-chain, "bundle gas used: 616104", "all 4 folded grants landed"
```

On-chain facts the amber posture relied on, now reproducible via (1): `EXECUTOR(address(0))=false`,
`getMinDelay()=259200`, no stray `DEFAULT_ADMIN` (events from block `22188631`), Safe `4/7`, gateway route
`(0xb69f2584…, frozen=false)`, exactly 3 escrows (no stray in `client-0..19`).

---

## Findings → resolution → how to validate

### Review B — must-resolve

| # | Resolution | Commit / file | Re-validate |
| --- | --- | --- | --- |
| **F1** relayer timing | **Owner-corrected.** No clean halt: relayer stays on the OLD build through the 72 h delay; the Phase-A lockstep gate runs against the accessible **new-build proof-api**; the prod relayer is **upgraded after the execute** (new step **8a**) — a brief restart. | `629ca1c`, `1e5ca10` · `CUTOVER-RUNSHEET.md` 5e/5f/8a; `upgrade-v2-to-v3.md` step 7 | Read 5e/5f/8a — confirm no Phase-A prod cut; the cut is post-execute. |
| **F2** `check-sp1-verifier` drops `frozen` | Reads both `routes()` returns; **FAILs if `frozen==true`**. | `22ef1f0` · `check-sp1-verifier.sh:94-100` | Read the diff; `verify-roots` prints the live route `(…,false)`. |
| **F3** rate-limiter false-green | `rateLimiters` **pre-staged top-level** in `1.json` (membership hard-fail on a miss) + a **conditional per-escrow wiring gate** (`rateLimitedEscrows`) in `validate-v3-roles.py` section D + `discover-v2-roles.py` made **fail-closed**. | `22ef1f0` · `validate-v3-roles.py:162`, `discover-v2-roles.py` tail, `deployments/mainnet/1.json` | `validate-v3-roles testnet` still **32/32** (empty list ⇒ informational); inspect the section-D gate. |
| **F4** timelock own roles unverified | **`scripts/verify-roots.sh` (new):** asserts `EXECUTOR(addr0)=false`, min delay, PROPOSER/EXECUTOR/CANCELLER=Safe, **no stray `DEFAULT_ADMIN`** (event reconstruction from block `22188631`). | `22ef1f0`, `629ca1c` · `verify-roots.sh` | Run (1) → 17/17. *Note: acute "front-run DoS" was **not** exploitable — executor is not open.* |
| **F5** in-flight packets | **Owner-corrected.** With the short gap (relayer restart, not 72 h) packets are **delayed-not-lost** and catch up post-8a; quiesce is **best-effort**. | `629ca1c` · `CUTOVER-RUNSHEET.md` 5f | Read 5f. |

### Review B — should-close

| # | Resolution | Commit / file | Re-validate |
| --- | --- | --- | --- |
| **F6** delay desync | `deploy.just` `_timelock-params` asserts `out/scriptHelper.json timelock_delay == live getMinDelay()` before building schedule blobs. (Note: the file is gitignored, not a "committed cache".) | `22ef1f0` · `deploy.just:495-507` | Read the diff. |
| **F7** ~10 ceremonies / completeness | `signer-verify.sh --expect-subcalls <N>` (REJECT on count≠N); runsheet states the **expected 10** + a per-schedule `--expect` table + "no unrelated Safe txs queued". | `22ef1f0`, `1e5ca10` · `signer-verify.sh`, `CUTOVER-RUNSHEET.md` | `signer-verify … --expect-subcalls 10`. |
| **F8** exact fold never rehearsed | Rehearsal extended (`RL_GRANTS`) to fold the **4-grant / 10-op** bundle; ran green on a mainnet fork. | `1e5ca10` · `shadow-v2-to-v3-timelock-rehearsal.sh` | Run (5). |
| **F9** gas unmeasured / `safeTxGas==0` | Bundle gas **measured** in the rehearsal: **≈ 616k / ~60M limit (~1 %)**. `safeTxGas==0` was already asserted on **both** sides (`safe-propose.sh` literal + `signer-verify.sh:135`), so the assert was redundant — effort went to the measurement. | `1e5ca10` · rehearsal `execute_atomic` | Run (5), see "bundle gas used". |
| **F10** Safe owners/threshold | Asserted by `verify-roots.sh` (`getThreshold()=4`, `getOwners()` count 7, owners printed). | `22ef1f0` · `verify-roots.sh` | Run (1). |

### Review B — footguns

Implemented: **cancel/abort tree** (`1e5ca10`/`629ca1c`), **RPC mandatory in the packer** + opt-in
**`isOperationReady`** (`22ef1f0`, `safe.just`; `ALLOW_NO_RPC` escape for offline preview), **`.eureka-env`
hygiene** + **pause≠halt** + **trusted-state freshness** T-minus items (this batch, `CUTOVER-RUNSHEET.md`).
Deferred (documented, not coded): the optional **beacon impl-changed structural guard** (mitigated
procedurally — "decode every payload"); `client-4` left in `1.json` (intentional — never passed to a migrate).

### Review A

| # | Resolution | Commit / file |
| --- | --- | --- |
| **FA1** `check-relayer-vkeys` all-clients | Runsheet scopes it `--client cosmoshub-0` / `--client ledger-mainnet-1` (per-`SRC_CHAIN`); "validates all" comment fixed; client-4 FAIL flagged spurious. | `1e5ca10`, `629ca1c` |
| **FA2** `deploy-fresh` client↔source | `deploy.just` accepts `CLIENT_ID` and **hard-fails if `.proofApiSrcChain` ≠ `SRC_CHAIN`**; field added to `1.json`. | `22ef1f0` |
| **FA3** signer-verify warn / dup-nonce | non-`execute` MultiSend sub-call → **REJECT**; `>1` tx at a nonce → **non-zero exit**. | `22ef1f0` |
| **FA4** escrow-init prints only | Runsheet step 9 now shows the explicit `cast send` + `authority()` confirm. | `1e5ca10` |
| signer SHA/table placeholders | Reframed: the table is **intrinsically cutover-time** (hashes depend on deployed addrs + nonces); the SHA is the coordinator's freeze-step. Not a current "blocker". | `823af00` |

### `READINESS-REVIEW.md` feedbacks (both)

| Feedback | Resolution | Commit |
| --- | --- | --- |
| "amber-go" misreadable | Conclusion → **"not ready to schedule until §5.1 closed; not a go."** | `823af00` |
| "all fail-closed" overclaim | Softened — core execute is atomic/fail-closed, but false-greens + the relayer cut are not. | `823af00` |
| `VerifyDeployment` role scope | Clarified: it checks **expected holders present**, not exact membership / no stray holders — that's `validate-v3-roles.py`. | `823af00` |
| **"membership ⟺ wiring" (my error)** | **Corrected** — `RATE_LIMITER` is manager-wide, so membership can be complete while an escrow stays unwired; hence the independent `rateLimitedEscrows` gate. | `823af00` |
| canary close-condition | Tightened to canary-before → prod-cut → prod-recheck; then owner-corrected to the real (no-halt, upgrade-at-8a) model. | `823af00`, `629ca1c` |
| `discover` is a soft gate | Made **fail-closed** (`sys.exit(1)` on issues). | `22ef1f0` |
| escrow-set not enumerated | **`verify-roots.sh` probes `client-0..19`** → no stray escrow (cross-checked vs the prod relayer config); event-scan caveat for unrelated names noted. | `629ca1c` |
| F9 over-scoped | Acknowledged the redundant assert; kept the substantive gas measurement. | `823af00` |
| record the on-chain evidence | `RECORD.md` "Trust-root verification" subsection (commands + results + deploy block). | `823af00`, `629ca1c` |
| selector not a constant / pin `proofApiSrcChain` | Footnoted the derived selector; pinned `proofApiSrcChain` to RECORD. | `823af00` |

---

## Round 2 — response to the three follow-up reviews

The follow-up reviewers re-ran the validators (reproducing 17/17, 32/32, 616k gas, the attack battery) and
found a **real bug**, **doc contradictions**, and additional **coverage gaps C1–C12** that the earlier
REVIEW-RESPONSE neither fixed nor acknowledged. All verified against source and addressed:

**The real bug (HIGH):** `DeployV3AccessManager._writeAccessManagerRoles` (`Deployments.sol:74-83`) rewrites
the whole `.accessManagerRoles` object from struct fields, so the F3 keys I'd pre-staged *under* it were
silently wiped at step 2 (the reviewer confirmed via the shadow JSON). **Fix:** moved `rateLimiters` /
`rateLimitedEscrows` **top-level** (the deploy's path-scoped `writeJson` leaves siblings intact) and updated
`validate-v3-roles.py` to read them there. **Proven:** a fork deploy-only ran (`.accessManagerRoles`
rewritten to exactly its 7 fields), and the **top-level keys survived**. testnet validate still 32/32.

**Doc contradictions (all fixed):** runsheet line 11 ("Halt relaying…") → the no-halt framing; canonical
runbook halt lines `:8`/`:282`; RECORD `:196` ("still wants a rehearsal" → done); the orphan "Closes Review A
F4"; and the vacuous verify-roots §D escrow `chk` (dropped — the `client-0..19` stray-probe is the real
assertion). `FROM_BLOCK=22188631` baked into the runsheet gate command.

**Coverage gaps C1–C12:**

| # | Gap | Disposition |
| --- | --- | --- |
| **C1** | customizer 2-of-5 Safe (un-timelocked) unasserted | **Done** — `verify-roots.sh` §B2 (threshold 2 / 5 owners) |
| **C2** | stray CANCELLER/PROPOSER not enumerated | **Done** — event reconstruction in `verify-roots.sh` (now 17/17) |
| **C5** | no pre-execute client `isFrozen` stop | **Done** — runsheet Phase-C gate 3 (getClient→getClientState) |
| **C3** | trusted-state freshness soft / "~11d" prose | **Done** — concrete ⅔-trusting-period threshold in T-minus |
| **C4** | end-to-end proof path (vkey-only) | **Wired** — DEFINITIVE T-minus gate: real `updateClient` proof on the staged-v6.1 fork + record prover SDK version |
| **C10** | execute-succeeds-but-verify-fails | **Done** — forward-fix branch in the abort tree |
| **C9** | no 72h monitoring | **Done** — Phase-C monitoring note (Cancelled event, reserved nonce, route freeze, proof-api health) |
| **C7 / C12** | go/no-go authority; single-point roles | **Decided** — single authority/proposer/coordinator, **no backups accepted** (recorded in T-minus) |
| **C6 / C8 / C11** | counterparty expiry / §6 owners / external comms | Mooted by the no-outage model / done / reduced — noted |

**Honesty corrections to this doc:** removed "every actionable finding addressed" (it omitted C1–C12); the
trust-root number is **17/17 and requires `FROM_BLOCK`**; the validation block is now literally runnable; file
count ≈19; `safeTxGas` assert is at `signer-verify.sh:135`; commit `3a86cc5` + the round-2 commit added above.

---

**No contract changes** — the verified-solid mechanical core (atomic encoding, ordering, storage layout,
bootstrap, signing math, pin) is untouched; see READINESS-REVIEW §4.

## Remaining (operational — not for re-review)

The §5.1 must-resolve items are now all implemented or resolved. What's left is the **live cutover**: SP1
step-5 staging (needs the proof-api at the window), the schedule → 72 h → execute → 8a-relayer-upgrade →
init/verify/validate sequence, and the coordinator's signer-hash table (generated + second-reviewed at
proposal time). A few cutover-time `‹…›` endpoints (the new-build / prod proof-api, the relayer-upgrade
owner) are placeholders in `CUTOVER-RUNSHEET.md`.
