# Review response & re-validation guide

*For the reviewers who produced Review A (6-agent), Review B (33-agent), and the two `READINESS-REVIEW.md`
feedbacks. Maps every finding to its resolution, the commit that made it, and a concrete way to re-validate.*
*Branch `operations/2026-06-15-upgrade-v2-to-v3`. Date 2026-06-17.*

---

## TL;DR

- **Every actionable finding is addressed**; nothing required a contract change (the verified-solid
  mechanical core is untouched).
- Two findings were **owner-clarified** after the reviews and changed the fix: **F1 relayer timing** (there
  is *no clean halt* — the relayer stays on the old build through the delay and is *upgraded* after the
  execute; brief restart, not a 72 h outage) and **F5 packets** (delayed-not-lost ⇒ best-effort quiesce).
- I also **corrected two of my own errors** the doc-feedback caught (the "membership ⟺ wiring" claim; the
  "amber-go" wording), and **pushed back** where a finding was overstated (F4 front-run DoS not exploitable;
  F2 route not frozen; F6 file not a "committed cache"; F9 already half-done) — all verified on-chain/in-code.
- New empirical evidence, all re-runnable: **`verify-roots.sh` 13/13** on mainnet, **`validate-v3-roles` 32/32**
  on testnet, the **exact 10-op fold** rehearsed on a mainnet fork (**≈ 616k gas**), and the `signer-verify`
  attack battery.

## Commits to review (newest first)

| Commit | What it covers |
| --- | --- |
| `629ca1c` | corrected relayer/halt model (F1/F5); `verify-roots` from-block + escrow probe (F4, escrow blind spot) |
| `1e5ca10` | 10-op fold rehearsal (F8/F9) + runbook sequencing (F1/F5/F7/FA4 + cancel tree) |
| `823af00` | the two `READINESS-REVIEW` feedbacks (amber-go, fail-closed, VerifyDeployment scope, membership⟺wiring, canary, …) |
| `22ef1f0` | the §6.1–6.3 hardening batch (F2/F3/F4/F6/F9/F10/FA1/FA2/FA3 + `verify-roots.sh` + JSON pre-stage + validate gate + discover fail-closed + RPC/ready guards) |
| `8414c36` | signer verification tool + checklist (predates the reviews; underlies F7/FA3) |
| `568ed99` | ledger proposer + timelock-pending & admin-revoke guards (predates the reviews) |

`git diff 188912e..HEAD` is the full delta (18 files, ~no contract changes).

---

## One-shot re-validation (run these)

```bash
# 1. Trust roots — F2/F4/F10 + escrow enumeration, all asserted (expect "13/13 ... ALL TRUST-ROOT CHECKS PASSED")
ETH_RPC=<mainnet> FROM_BLOCK=22188631 scripts/verify-roots.sh mainnet 1

# 2. Role validation incl. the new conditional rate-limiter wiring gate (expect "32 passed, 0 failed")
ETH_RPC=<testnet> python3 scripts/validate-v3-roles.py testnet 11155111

# 3. Discovery is now fail-closed (expect a non-zero exit if any holder is MISSING/unidentified)
echo "exit code semantics: sys.exit(1) when issues>0"   # scripts/discover-v2-roles.py tail

# 4. Signer tool — the inner-calldata attack battery (manual mode, needs only `cast`)
#    a grantRole(ADMIN/role 0) inside a schedule, a non-execute MultiSend sub-call, a delegatecall to a
#    non-MultiSend target, wrong gas/value, --expect-subcalls mismatch  -> each prints REJECT.

# 5. The exact 10-op mainnet fold on a fork (4 core + 2 migrations + 4 rate-limiter grants)
RL_GRANTS="cosmoshub-0:0x4b46ea82…,cosmoshub-0:0x64259f72…,ledger-mainnet-1:0x4b46ea82…,ledger-mainnet-1:0x64259f72…" \
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
| **F3** rate-limiter false-green | `.accessManagerRoles.rateLimiters` **pre-staged** in `1.json` (membership hard-fail on a miss) + a **conditional per-escrow wiring gate** (`rateLimitedEscrows`) in `validate-v3-roles.py` section D + `discover-v2-roles.py` made **fail-closed**. | `22ef1f0` · `validate-v3-roles.py:162`, `discover-v2-roles.py` tail, `deployments/mainnet/1.json` | `validate-v3-roles testnet` still **32/32** (empty list ⇒ informational); inspect the section-D gate. |
| **F4** timelock own roles unverified | **`scripts/verify-roots.sh` (new):** asserts `EXECUTOR(addr0)=false`, min delay, PROPOSER/EXECUTOR/CANCELLER=Safe, **no stray `DEFAULT_ADMIN`** (event reconstruction from block `22188631`). | `22ef1f0`, `629ca1c` · `verify-roots.sh` | Run (1) → 13/13. *Note: acute "front-run DoS" was **not** exploitable — executor is not open.* |
| **F5** in-flight packets | **Owner-corrected.** With the short gap (relayer restart, not 72 h) packets are **delayed-not-lost** and catch up post-8a; quiesce is **best-effort**. | `629ca1c` · `CUTOVER-RUNSHEET.md` 5f | Read 5f. |

### Review B — should-close

| # | Resolution | Commit / file | Re-validate |
| --- | --- | --- | --- |
| **F6** delay desync | `deploy.just` `_timelock-params` asserts `out/scriptHelper.json timelock_delay == live getMinDelay()` before building schedule blobs. (Note: the file is gitignored, not a "committed cache".) | `22ef1f0` · `deploy.just:486-` | Read the diff. |
| **F7** ~10 ceremonies / completeness | `signer-verify.sh --expect-subcalls <N>` (REJECT on count≠N); runsheet states the **expected 10** + a per-schedule `--expect` table + "no unrelated Safe txs queued". | `22ef1f0`, `1e5ca10` · `signer-verify.sh`, `CUTOVER-RUNSHEET.md` | `signer-verify … --expect-subcalls 10`. |
| **F8** exact fold never rehearsed | Rehearsal extended (`RL_GRANTS`) to fold the **4-grant / 10-op** bundle; ran green on a mainnet fork. | `1e5ca10` · `shadow-v2-to-v3-timelock-rehearsal.sh` | Run (5). |
| **F9** gas unmeasured / `safeTxGas==0` | Bundle gas **measured** in the rehearsal: **≈ 616k / ~60M limit (~1 %)**. `safeTxGas==0` was already asserted on **both** sides (`safe-propose.sh` literal + `signer-verify.sh:128`), so the assert was redundant — effort went to the measurement. | `1e5ca10` · rehearsal `execute_atomic` | Run (5), see "bundle gas used". |
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

## What was NOT changed (and why)

No contract changes. The independently-verified mechanical core is untouched: the atomic MultiSend
encoding + predecessor ordering (proven on a fork), the storage-layout compatibility, the AccessManager
bootstrap + selector→role table, the Safe EIP-712 signing math, and the `solidity-v3.0.1` pin integrity.
The work is **operational hardening + asserting trust roots**, exactly as both reviews concluded.

## Remaining (operational — not for re-review)

The §5.1 must-resolve items are now all implemented or resolved. What's left is the **live cutover**: SP1
step-5 staging (needs the proof-api at the window), the schedule → 72 h → execute → 8a-relayer-upgrade →
init/verify/validate sequence, and the coordinator's signer-hash table (generated + second-reviewed at
proposal time). A few cutover-time `‹…›` endpoints (the new-build / prod proof-api, the relayer-upgrade
owner) are placeholders in `CUTOVER-RUNSHEET.md`.
