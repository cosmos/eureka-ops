# Final readiness report — mainnet v2→v3 + SP1 v6.1 upgrade

*Standalone entry point for a final go/no-go review. No prior context assumed.*
*Branch `operations/2026-06-15-upgrade-v2-to-v3` · 2026-06-17.*

## Verdict

**Off-window engineering, tooling, and runbooks are complete and adversarially validated** (3 review
rounds, every empirical claim reproduces). **No custom contract code** (the pinned `solidity-v3.0.1` release
is deployed as-is, including its net-new ICS27GMP app — change 3 below). The readiness items are closed.
**The C4 end-to-end proof gate has now passed** (2026-06-17) — two real cluster proofs from the new-build
prover verified on-chain against the deployed v6.1.0 verifier (see Gates). The one remaining gate is
**operational: the live cutover steps** (SP1 staging + the signer hash-table at proposal time). This is
**"ready to schedule,"** with execution gated only on the cutover window.

## The upgrade in brief

Three coupled changes to a live IBC bridge (`solidity-ibc-eureka`) on **mainnet (chain 1)**. The first two
cut over **atomically** (one MultiSend) so the chain never sits in a mixed v2/v3 state; the third is a
post-execute registration:

1. **v2→v3 core** — authorization moves from per-contract `AccessControl` to a single shared OZ
   `AccessManager` (admin = the existing 72 h `TimelockController`). Four contracts upgrade: `ICS20Transfer`,
   `ICS26Router`, the `Escrow` beacon, the `IBCERC20` beacon.
2. **SP1 v6.1 light-client migration** — Tendermint clients move to v6.1 proof programs (fresh trusted state,
   v6.1 vkeys, a verifier gateway).
3. **ICS27GMP (net-new app)** — the v3 AccessManager bootstrap also deploys a greenfield `ICS27GMP`
   message-passing app + `ICS27Account` beacon (from the pinned release), registered on the live ICS26Router
   via a post-execute **2-of-5 customizer-Safe `addIBCApp` CALL** (`verify-deployment` reverts until it is).
   **Inert without a counterparty channel** (none wired to `gmpport`), but net-new on-chain surface —
   accepted by explicit decision (see RECORD).

**Execution model:** all timelock `execute(...)` calls are packed into **one** `MultiSendCallOnly.multiSend`
via DelegateCall — atomic, ordered by a timelock predecessor (`ICS20`→`ICS26`). Governance is a **4-of-7
hardware Safe** + **72 h timelock**; a second round is impractical, so the rate-limiter re-grant is **folded
into the single round** → a **10-sub-call** bundle (4 core + 2 migrations + 4 rate-limiter grants).

**The contract code is not in this repo** — it is `@cosmos/solidity-ibc-eureka` pinned at `solidity-v3.0.1`
(commit `04b9767`). This repo is the **ops tooling** (forge scripts, `just` recipes, validators, runbooks).

| Mainnet | Address |
| --- | --- |
| Governance Safe (4-of-7) | `0x7B96CD54aA750EF83ca90eA487e0bA321707559a` |
| TimelockController (72 h) | `0xb3999B2D30dD8c9faEcE5A8a503fAe42b8b1b614` (deploy block `22188631`) |
| ICS26Router / ICS20Transfer | `0x3aF134307D5Ee90faa2ba9Cdba14ba66414CF1A7` / `0xa348CfE719B63151F228e3C30EB424BA5a983012` |
| ID/ERC20 customizer (2-of-5 Safe) | `0x4b46ea82D80825CA5640301f47C035942e6D9A46` |
| MultiSendCallOnly (delegatecall target) | `0x9641d764fc13c8B624c04430C7356C1C7C8102e2` |
| SP1 gateway → real verifier | `0x397A5f7f…` → `0xb69f2584…` (`VERSION v6.1.0`) |

**Migrate set:** `cosmoshub-0` + `ledger-mainnet-1`. `client-4` is **dropped** (not relayed in prod; its
escrow is still upgraded). Rate-limiter holders re-granted: `0x4b46ea82…`, `0x64259f72…` on both escrows.

## Status

- **Executed end-to-end on Sepolia testnet** (verified). Mainnet not yet executed.
- **C4 proof gate passed** (2026-06-17): two real Groth16 proofs from the new-build prover (reserved
  cluster, exact deployed `v2.0.0` ELF) verified on-chain against the v6.1.0 verifier. See Gates.
- **Decisions locked** (see below).
- **Tooling built + validated:** Ledger proposer signing, packer schedule-state guard, admin-revoke guard,
  signer verification tool + checklist, trust-root assertion script, role validators.
- **Rehearsed on a mainnet fork:** the core timelock path, a staged-v6.1 variant, and the **exact 10-op
  fold** (≈ 616k gas).

## Independently verified — solid, no change needed

- Atomic MultiSend encoding byte-correct; `ICS20`→`ICS26` predecessor ordering enforced (reverts on
  mis-order) — **proven on a fork**.
- Storage layout byte-compatible v2.0.1→v3.0.1; `initializeV2` runs once; beacon mechanics correct.
- AccessManager bootstrap leaves the timelock as sole ADMIN; selector→role table byte-correct.
- Safe EIP-712 signing math correct; the signer tool rejects any delegatecall not targeting MultiSendCallOnly.
- Pin integrity exact: `package.json` = `bun.lock` = tag commit `04b9767`.

## Review history

Multiple independent rounds, all of which **re-ran the validators** (not read-only): a 6-agent focused
pass, a 33-agent multi-dimension pass with a coverage critic, three round-2 follow-ups, and an 8-agent
doc-quality pass (clarity/correctness/verbosity). ~24 numbered findings + footguns + coverage gaps C1–C12.
Outcome:

- **One real bug found and fixed (proven):** pre-staged rate-limiter validation keys were nested under
  `.accessManagerRoles`, which `DeployV3AccessManager` rewrites — silently wiping them at deploy. Moved
  top-level; a fork deploy-only confirms they now survive.
- Everything else was **operational hardening / trust-root assertion / doc precision** — no architecture
  defect. Findings the reviewers overstated (a front-run DoS, a frozen route, a "committed cache") were
  **verified clean on-chain** and pushed back on.
- Full finding-by-finding mapping: **[`REVIEW-RESPONSE.md`](REVIEW-RESPONSE.md)**.

## Re-runnable evidence (reproduce these)

```bash
H1=0x4b46ea82D80825CA5640301f47C035942e6D9A46; H2=0x64259f722A0868CCf58A935C61A292cEA9dF035a
# Trust roots (FROM_BLOCK required) — expect "ALL TRUST-ROOT CHECKS PASSED" (17/17)
ETH_RPC=<mainnet> FROM_BLOCK=22188631 scripts/verify-roots.sh mainnet 1
# Role wiring (testnet) — expect "32 passed, 0 failed"
ETH_RPC=<testnet> python3 scripts/validate-v3-roles.py testnet 11155111
# Exact 10-op fold on a mainnet fork — expect "bundle gas used: 616104", "all 4 folded grants landed"
RL_GRANTS="cosmoshub-0:$H1,cosmoshub-0:$H2,ledger-mainnet-1:$H1,ledger-mainnet-1:$H2" SP1_CLIENT_IDS="cosmoshub-0,ledger-mainnet-1" \
  bash scripts/shadow-v2-to-v3-timelock-rehearsal.sh 1 mainnet shadow-mainnet <fork-rpc>
```

`verify-roots` (17/17) asserts on-chain **today**: executor **not** open, min delay 259 200, no stray
DEFAULT_ADMIN/CANCELLER/PROPOSER, governance Safe **4-of-7**, customizer Safe **2-of-5**, gateway route **not
frozen**, and no stray escrow in the `client-0..19` probe (best-effort; the 3 JSON clients + the prod relayer
config bound the set). `validate-v3-roles` includes a hard rate-limiter wiring gate. The
signer tool rejects every malicious-calldata shape (ADMIN grant, non-execute sub-call, wrong delegatecall
target, sub-call count mismatch).

## Gates

1. **C4 — end-to-end proof test — PASSED (2026-06-17).** The open risk: every other check matched *recorded
   values*, but none proved the prover actually emits proofs the on-chain v6.1.0 verifier *accepts* — proof
   format depends on the prover SP1-SDK version, so a vkey match is necessary but not sufficient. Closed
   empirically: two real **Groth16** proofs from the new-build prover — operator-run against the **reserved
   private cluster**, using the exact deployed `sp1-programs v2.0.0` ELF (sha `6a6a40df`) — verified on-chain
   against the deployed **v6.1.0** verifier (`0xb69f2584…`, selector `0x4388a21c`) via
   `gateway.verifyProof(bytes32,bytes,bytes)` (the same call `_verifySP1Proof` makes) **and** the direct
   verifier. Prover SDK recorded: `sp1-sdk 6.1.0`, circuit `v6.1.0`, image `proof-api:10a6a10`. *Scope note:*
   this proves the cryptographic accept-path via the verifier view call; it does not drive a full
   `updateClient` against a fork-migrated client — not needed, since the format/acceptance risk the gate
   existed for is gone. Tooling: `scripts/verify-c4-proof.sh`, `script/helpers/decode_update_client.py`.
2. **Live cutover (remaining).** SP1 step-5 staging (fresh trusted state + v6.1 vkeys + verifier repoint), the
   schedule → 72 h → execute → relayer-upgrade → init/verify/validate sequence, and the coordinator's signer
   hash-table (generated + second-reviewed at proposal time). **Relayer-upgrade note:** the new-build proof-api
   must run an image carrying [ibc-manifests#91](https://github.com/skip-mev/ibc-manifests/pull/91) (larger
   `/dev/shm`) **and** the pod must be restarted to pick up the mount — otherwise proving for `cosmoshub-0`
   (chainId `cosmoshub-4`) fails. See Risk posture.

## Risk posture

- **Fail-closed core:** a malformed/incomplete bundle reverts atomically — no fund loss, no mixed state;
  worst case is a wasted 72 h round. Storage survives the upgrade, so in-flight packets are delayed-not-lost.
- **No clean relaying halt** (owner-confirmed): the prod relayer stays on the old build through the 72 h
  delay and is *upgraded* right after the execute — the gap is a brief restart, not an outage.
- **Proof-api `/dev/shm` (found + fixed this cycle):** the new-build proof-api proves Cosmos Hub through the
  SP1 native executor's shared-memory trace ring in `/dev/shm`, which Kubernetes defaults to 64 MiB — a single
  `cosmoshub-4` proof needs ~63 MiB, so it fails under any concurrency (surfacing as `Program simulation
  failed`). Fixed by a 2 GiB RAM-backed `/dev/shm` in the **shared** relayer template
  ([ibc-manifests#91](https://github.com/skip-mev/ibc-manifests/pull/91), merged), so prod inherits it.
  Because the prod relayer is upgraded to the new build right after execute, **the cutover relayer-upgrade
  step must deploy an image with this fix and restart the pod** (mount size is fixed at mount time). Full
  write-up: [`../../../PROOF_API_FAILURE_MODE.md`](../../../PROOF_API_FAILURE_MODE.md).
- **Residual:** **single-operator** risk — accepted (see decisions), which raises the bar for thorough
  pre-window checks (the now-passed C4 test being the key one). The C4 integration risk is **closed**.

## Decisions on record

`client-4` dropped · final `sp1-programs v2.0.0` at the rc.2 commit (vkeys fixed/known) · ID/ERC20 customizer
is a 2-of-5 Safe (step 8 = a Safe CALL, not a broadcast) · proposer = a single Ledger at `MNEMONIC_INDEX=1` ·
**single authority/proposer/coordinator, no backups accepted** · packet quiesce best-effort.

## Supporting documents

- **[`CUTOVER-RUNSHEET.md`](CUTOVER-RUNSHEET.md)** — the pre-filled 72 h execution sheet (T-minus gates,
  phases A–D, abort tree).
- **[`RECORD.md`](RECORD.md)** — durable record (addresses, tx hashes, decisions, grant-set audit, trust-root
  evidence).
- **[`REVIEW-RESPONSE.md`](REVIEW-RESPONSE.md)** — finding-by-finding resolution + re-validation guide.
- **[`READINESS-REVIEW.md`](READINESS-REVIEW.md)** — the consolidated review + change plan.
- **[`SIGNER-CHECKLIST.md`](SIGNER-CHECKLIST.md)** — the one-page signer flow.
- Procedure: [`../../upgrade-v2-to-v3.md`](../../upgrade-v2-to-v3.md). Scripts: `scripts/verify-roots.sh`,
  `validate-v3-roles.py`, `discover-v2-roles.py`, `signer-verify.sh`, `safe-propose.sh`.

*This effort: 16 commits / 23 files / 0 contract-source changes since the review baseline (`188912e..HEAD`).*
