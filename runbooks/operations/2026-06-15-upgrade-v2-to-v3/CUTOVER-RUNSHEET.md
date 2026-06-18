# Mainnet (chain 1) v2→v3 + SP1 v6.1 — cutover runsheet

Pre-filled, ordered execution sheet for the **one-shot 72 h** mainnet window. Mainnet values and
the locked decisions are inlined; `‹…›` marks a value only known at run time (deployed address,
nonce). This is the operating sheet — the **why** lives in
[`../../upgrade-v2-to-v3.md`](../../upgrade-v2-to-v3.md), the **record** in
[`RECORD.md`](RECORD.md). Fill `RECORD.md` as you go.

> **One-shot.** Everything that must take effect at cutover is scheduled in **one** step-6 window
> and folded into **one** atomic step-7 MultiSend; a second 72 h round is the failure mode to avoid.
> **Relaying is NOT halted on mainnet** — there is no clean halt. The prod relayer stays on the *old*
> build through the window and is *upgraded* right after the execute (steps 5e / 5f / 8a), so the gap is a
> brief restart, not an outage. Do not try to stop relaying.

## Fixed mainnet values

| Thing | Value |
| --- | --- |
| Governance Safe (proposer/executor) | `0x7B96CD54aA750EF83ca90eA487e0bA321707559a` — **4-of-7** |
| Proposer signer | **Ledger**, `LEDGER=1 MNEMONIC_INDEX=1` (`m/44'/60'/0'/0/1`) |
| TimelockController (AccessManager ADMIN) | `0xb3999B2D30dD8c9faEcE5A8a503fAe42b8b1b614` — delay **259 200 s / 72 h** |
| ICS26Router proxy | `0x3aF134307D5Ee90faa2ba9Cdba14ba66414CF1A7` |
| ICS20Transfer proxy | `0xa348CfE719B63151F228e3C30EB424BA5a983012` |
| ID/ERC20 customizer | `0x4b46ea82D80825CA5640301f47C035942e6D9A46` — **a 2-of-5 Safe** (step 8 signer) |
| MultiSendCallOnly | `0x9641d764fc13c8B624c04430C7356C1C7C8102e2` |
| SP1 v6.1 Groth16 gateway → real verifier | `0x397A5f7f3dBd538f23DE225B51f532c34448dA9B` → `0xb69f2584CBcFf99a58C4e7002E8b89Af54a6f4e2` (`VERSION v6.1.0`, selector `0x4388a21c`) |

**Migrate set (decision): `cosmoshub-0` + `ledger-mainnet-1` only. `client-4` is DROPPED** (its
escrow is still upgraded + initialized in step 9).

| Client (migrated) | Counterparty | Escrow | `SRC_CHAIN` |
| --- | --- | --- | --- |
| `cosmoshub-0` | `08-wasm-1369` | `0x0fA75C2c49d7dB7ed62c5Fb70bF78ba614aE6A89` | `cosmoshub-4` |
| `ledger-mainnet-1` | `08-wasm-0` | `0xC76944B0159D7Dd5c4cF6936b0f45E8de9b34092` | `ledger-mainnet-1` |
| `client-4` *(dropped; escrow still init'd)* | `08-wasm-301` | `0x3f36Fd49251475aC17bB680D56F412Bf81Aa5778` | — |

**SP1 v6.1 vkeys** (final `v2.0.0` cut at the `rc.2` commit → identical to testnet):
`updateClient 0x00d38536…`, `membership 0x000bd8ec…`, `ucAndMembership 0x009fe47d…`,
`misbehaviour 0x0010008d…`.

**RATE_LIMITER re-grant pairs** (fold into step 7; **re-confirm with `discover-v2-roles.py` first**):
`0x4b46ea82…` and `0x64259f72…`, each on **both** the `cosmoshub-0` and `ledger-mainnet-1` escrows.

Shell context for every command below (the proposer machine):
```bash
export EUREKA_ENVIRONMENT=mainnet EUREKA_CHAIN=1
export ETH_RPC=<mainnet RPC>        # also exported as FOUNDRY_ETH_RPC_URL by the recipes
export ETHERSCAN_API_KEY=<key>      # required by discover-v2-roles.py (the fail-closed grant-set gate)
# proposing/executing Safe txs (steps 6/7): add LEDGER=1 MNEMONIC_INDEX=1 to the command
```

---

## T-minus (before opening the window)

- [ ] **Shadow-fork dress rehearsal green**, incl. the **exact 10-op fold** (4 core + 2 migrations + 4
      rate-limiter grants) via `RL_GRANTS="cosmoshub-0:0x4b46ea82…,cosmoshub-0:0x64259f72…,ledger-mainnet-1:0x4b46ea82…,ledger-mainnet-1:0x64259f72…"
      SP1_CLIENT_IDS=cosmoshub-0,ledger-mainnet-1 bash scripts/shadow-v2-to-v3-timelock-rehearsal.sh 1 mainnet shadow-mainnet <fork>`,
      plus the staged-v6.1 variant (`SHADOW_FORK_PRESERVE_DEPLOYMENT=1`). *(Rehearsed 2026-06-17: the
      10-op bundle executes for ≈ 616k gas (~1 % of the block limit); all 4 grants land.)*
- [ ] **SP1 go/no-go** on the `sp1-programs` tag (final `v2.0.0` at the `rc.2` commit).
- [ ] **Relayer owners + the 2-of-5 customizer Safe signers + the 4-of-7 governance signers** lined up.
- [ ] **Ledger** confirmed: `cast wallet address --ledger --mnemonic-index 1` == a governance-Safe
      owner; blind signing / EIP-712 enabled on the Ethereum app.
- [ ] Branch builds: `forge build` green; `deployments/mainnet/1.json` `.accessManagerRoles.*`
      complete (esp. the **full relayer set** — a missing relayer breaks relaying at cutover).
- [ ] **Signers prepped:** distribute [`SIGNER-CHECKLIST.md`](SIGNER-CHECKLIST.md) + `scripts/signer-verify.sh`
      (+ its `sha256`) to **both** signer sets over a trusted channel; each signer has run the one-time setup
      and `cast --version` works (Windows signers on WSL). The per-nonce **expected-hash table** is generated
      from source and **independently re-checked by a second reviewer**, then published the same way.
- [ ] **Env hygiene:** `.eureka-env` ships a hot *testnet* `PRIVATE_KEY` the Phase-A broadcasts would use —
      **unset `PRIVATE_KEY`** and confirm the env points at mainnet (`just info-env` / `echo $EUREKA_CHAIN` = 1)
      before any deploy/escrow-init.
- [ ] **On-chain pause ≠ off-chain halt.** Do **not** `ops-pause-transfers` for the cutover — the on-chain
      pause is a 4-of-7 governance action (unpause is *also* 4-of-7) and is unrelated to the relayer transition
      (steps 5e/8a). The cutover needs no contract pause. See `runbooks/pause.md`.
- [ ] **Trusted-state freshness (C3):** the SP1 trusted state from step 5a is valid for the client's
      **trusting period** (≈ the unbonding period, ~14 d). Re-derive the **age** at ceremony time
      (now − trusted-state timestamp) and **re-run step 5a if age > ⅔ of the trusting period**, so the 72 h
      delay + execute land with margin. A lapse → the migrated client can't be updated → another 72 h round.
- [ ] **End-to-end proof test (C4) — DEFINITIVE.** vkey-matching (`sp1-vkeys` / `check-relayer-vkeys`) proves
      the relayer loaded the right *programs* but NOT that its prover emits proofs the on-chain v6.1.0 verifier
      accepts (proof format depends on the prover's SP1-SDK version). Before scheduling: drive the new-build
      proof-api to produce a real `updateClient` proof and **verify it lands against a fork-migrated mainnet
      client** (the staged-v6.1 fork), and **record the prover SP1-SDK version** so prod runs the identical
      prover. *(Single operator, no backup ⇒ the definitive test, not just a testnet witness.)*
- [ ] **Prod proof-api `/dev/shm` (the post-cut prover footgun).** The new build proves `cosmoshub-4` through a
      `/dev/shm` trace ring; the 64 MiB k8s default fails as `Program simulation failed` (RAM idle, no
      OOMKills — easy to misread). Confirm [ibc-manifests#91](https://github.com/skip-mev/ibc-manifests/pull/91)
      (≥2 GiB RAM-backed `/dev/shm`) is **merged and Argo-synced to prod**, and that the prod relayer pod
      actually has it (needs a pod restart to take effect): `kubectl -n ibc exec ‹prod relayer pod› -- df -h
      /dev/shm` shows **≥2.0G, not 64M**. The new-build proof-api used for C4 (above) and step 5e should carry
      the same mount. Full write-up: [`../../../PROOF_API_FAILURE_MODE.md`](../../../PROOF_API_FAILURE_MODE.md).
- [x] **Authority & roles (decided):** single **authority** = the operator (go/no-go **and** abort); single
      **proposer** (Ledger idx 1) + single **coordinator**; **single-point roles accepted, no backups** (C7/C12).
      The 4-of-7 governance + 2-of-5 customizer Safes provide signing breadth, not operator redundancy.

---

## Phase A — Deploy (no on-chain governance yet)

**2. Deploy the v3 AccessManager + ICS27GMP.** Writes `.accessManager`, `.accessManagerRoles`,
`.ics27Gmp`; ADMIN = the timelock; copies role holders from the JSON.
```bash
just deploy-v3-access-manager
```
→ record `‹accessManager›`, `‹ics27Gmp.proxy›`.

**3–4. Deploy the four v3 implementations** (once each: ICS20Transfer, ICS26Router, Escrow,
IBCERC20), then write them into the JSON (`.ics20Transfer.implementation`,
`.ics26Router.implementation`, `.ics20Transfer.escrowImplementation`,
`.ics20Transfer.ibcERC20Implementation`).
```bash
just deploy-implementation     # x4
```

**5. Stage + deploy SP1 v6.1** for `cosmoshub-0` and `ledger-mainnet-1` (NOT `client-4`).
Proof-api via localhost port-forward.
```bash
PROOF_API_ADDR=localhost:<port> SRC_CHAIN=cosmoshub-4      DST_CHAIN=1 just deploy-fresh-light-client-state   # cosmoshub-0
PROOF_API_ADDR=localhost:<port> SRC_CHAIN=ledger-mainnet-1 DST_CHAIN=1 just deploy-fresh-light-client-state   # ledger-mainnet-1
just sp1-vkeys --version <v2.0.0-tag> --write mainnet 1 cosmoshub-0 ledger-mainnet-1   # --version BEFORE --write
# set .verifier = gateway 0x397A5f7f… for both clients in the JSON, then:
just check-sp1-verifier            # must route v6.1.0 -> 0xb69f2584…
CLIENT_ID=cosmoshub-0      SP1_DEPLOY_COPY=true just deploy-light-client
CLIENT_ID=ledger-mainnet-1 SP1_DEPLOY_COPY=true just deploy-light-client
```

**5e. Relayer lockstep gate — against the NEW-build proof-api; prod stays on the OLD build.** ⚠️ **Do not
touch the prod relayer here.** It must stay on the **old** build through the 72 h delay so relaying
continues normally (old proofs ⇿ not-yet-migrated clients). Cutting prod now would make every proof revert
`VerificationKeyMismatch` for the whole window. We have an accessible **new-build proof-api** (latest
sp1-programs / v6.1) — run the gate against *it*, scoped per migrated client (an unscoped run FAILs on the
still-pre-v6.1 `client-4`; per-client `SRC_CHAIN` differs):
```bash
PROOF_API_ADDR=‹new-build proof-api:port› SRC_CHAIN=cosmoshub-4      DST_CHAIN=1 just check-relayer-vkeys --client cosmoshub-0
PROOF_API_ADDR=‹new-build proof-api:port› SRC_CHAIN=ledger-mainnet-1 DST_CHAIN=1 just check-relayer-vkeys --client ledger-mainnet-1
```
(The vkeys are fixed and known; `sp1-vkeys` already proves them from the released ELFs — this just confirms
the running service serves them. The prod relayer is upgraded to this same build **after** the execute lands,
step 8a.)

**5f. Packet state — best-effort (no hard halt exists).** There is no clean "stop relaying" switch; the
"cut" = **upgrading the relayer at step 8a, which briefly restarts it (minutes, not 72 h)**. So the relaying
gap is short and in-flight packets are **delayed, not lost** — once the upgraded relayer is up it relays them
against the migrated clients (commitments survive the byte-compatible upgrade; a timeout that lands in the gap
is simply refunded once relaying resumes). Therefore:
- **Best-effort** drain both channels before the window (fewer in-flight packets → shorter catch-up). A
  guarantee of zero in-flight packets is **not** required.
- Keep step 7→8a tight (execute → relayer upgrade) so the gap stays minimal.
- Owner for the relayer upgrade + catch-up watch: ‹…›.

**Trust-root gate (T-minus, re-run right before scheduling — roots can change):**
```bash
ETH_RPC=<rpc> FROM_BLOCK=22188631 scripts/verify-roots.sh mainnet 1   # must end "ALL TRUST-ROOT CHECKS PASSED"
```

---

## Phase B — Schedule the step-6 window (Ledger proposer)

**Take the RATE_LIMITER snapshot now** (escrows are still v2 `AccessControl`):
```bash
python3 scripts/discover-v2-roles.py mainnet 1     # confirm the (escrow, holder) pairs above
```

**Verify each upgrade payload before proposing** (decode and confirm `upgradeToAndCall` →
`initializeV2(accessManager)`):
```bash
just schedule-v3-ics20transfer-upgrade-params                    # prints `data:` only
cast decode-calldata 'upgradeToAndCall(address,bytes)' <data>
cast decode-calldata 'initializeV2(address)' <inner>             # == .accessManager
```

**Propose each schedule** (auto-queued consecutive nonces). Note the printed nonce for each:
```bash
LEDGER=1 MNEMONIC_INDEX=1 just propose-schedule schedule-v3-ics20transfer-upgrade-params
LEDGER=1 MNEMONIC_INDEX=1 just propose-schedule schedule-v3-ics26router-upgrade-params
LEDGER=1 MNEMONIC_INDEX=1 just propose-schedule schedule-escrow-upgrade-params
LEDGER=1 MNEMONIC_INDEX=1 just propose-schedule schedule-ibcerc20-upgrade-params
LEDGER=1 MNEMONIC_INDEX=1 just propose-schedule schedule-v3-light-client-migration-params cosmoshub-0
LEDGER=1 MNEMONIC_INDEX=1 just propose-schedule schedule-v3-light-client-migration-params ledger-mainnet-1
```

**Schedule the rate-limiter re-grants** (one per (client_id, holder); these recipes prompt, so
they go through `safe-propose`, not `propose-schedule`). For each pair, **capture both the schedule
AND the byte-identical execute blob now**:
```bash
just timelock-grant-rate-limiter-role schedule <nonce>     # interactive: client + rate-limiter
LEDGER=1 MNEMONIC_INDEX=1 just safe-propose <timelock> <schedule-calldata> <nonce> 0
just timelock-grant-rate-limiter-role execute              # -> save `timelock calldata: 0x…` for step 7
```

**All schedule Safe txs must EXECUTE** (4-of-7) before step 7. Each signer independently verifies
each `safeTxHash` (see appendix) before approving.

---

## Phase C — Wait the 72 h delay, then atomic execute (step 7)

**During the delay — monitor (C9).** Don't just re-check at the end; over the 72 h watch for:
a `Cancelled(bytes32)` event on the timelock (someone cancelled a scheduled op); any **unexpected Safe
transaction queued at the reserved execute nonce** (would change what executes at that nonce); a gateway
**route freeze** (re-run `verify-roots.sh`); and **new-build proof-api health**. Any surprise → investigate
before executing.

**Just before executing — in order:**
1. Confirm the **72 h delay elapsed**. (Leave the prod relayer **on the old build** — it's still relaying
   normally; the upgrade happens *after* the execute, step 8a. There is no clean halt, and none is needed.)
2. Re-run the gates — both must be clean:
   ```bash
   python3 scripts/discover-v2-roles.py mainnet 1 && echo OK          # fail-closed; must exit 0
   ETH_RPC=<rpc> FROM_BLOCK=22188631 scripts/verify-roots.sh mainnet 1 # must end "ALL TRUST-ROOT CHECKS PASSED"
   ```
3. **No migrated client is frozen (C5).** A freeze applied during the window (misbehaviour) would be
   silently undone by `migrateClient` — confirm `isFrozen=false` for each, and **investigate any frozen
   client before migrating over it**:
   ```bash
   for cid in cosmoshub-0 ledger-mainnet-1; do
     cl=$(cast call 0x3aF134307D5Ee90faa2ba9Cdba14ba66414CF1A7 'getClient(string)(address)' "$cid")
     cast call "$cl" 'getClientState()(bytes)'   # decode field 6 (isFrozen bool) — must be false
   done
   ```

**Build + propose the atomic MultiSend** — the 6 core/migration executes + the **4** rate-limiter grant
executes folded via `EXTRA_TIMELOCK_OPS`. Set `REQUIRE_READY=1` so the packer asserts every sub-op is not
just *pending* but *ready* (delay elapsed) before building:
```bash
EXTRA_TIMELOCK_OPS='0x<rl-1>;0x<rl-2>;0x<rl-3>;0x<rl-4>' REQUIRE_READY=1 \
  just execute-v3-upgrade-multisend <execute_nonce> cosmoshub-0 ledger-mainnet-1
# prints to/value/operation(=1)/data/safeTxHash — verify, then propose as DelegateCall at the SAME nonce:
EXTRA_TIMELOCK_OPS='…' LEDGER=1 MNEMONIC_INDEX=1 \
  just safe-propose 0x9641d764fc13c8B624c04430C7356C1C7C8102e2 <multisend_data> <execute_nonce> 1
```
4-of-7 sign + execute in the Safe UI / device. **Verify on-device: `to == 0x9641d764…`,
`operation == DelegateCall`, `safeTxHash` == the recipe's recomputed value.** Signers should also run
`signer-verify.sh … --expect-subcalls 10` (4 core + 2 migrations + 4 rate-limiter). Atomic + ordered
(ICS20 before ICS26) — if any sub-execute reverts, nothing lands. *(Rehearsed on a mainnet fork: the exact
10-op bundle executes for ≈ 616k gas, ~1 % of the block limit.)*

→ record the `execTransaction` tx hash in `RECORD.md`.

---

## Phase D — Post-cutover

> **Order:** execute → **9** (escrow init) → **8** (register ICS27GMP) → **11** (verify) → **8a** (relayer
> upgrade) → **13** (validate). **Verify (11) gates the relayer roll (8a):** if verify fails, do **not** roll
> the relayer — it stays on the old build (see C10). `verify-deployment` reverts unless ICS27GMP is
> registered, so **8 must precede 11**. *(8a runs last among the cut steps so the relayer only moves to the
> new build once the on-chain end-state is confirmed good.)*

**8a. Upgrade the prod relayer to the new build — once verify (11) is green.** This is the "cut": bump
`v1.2.0`→`v2.0.0` (latest sp1-programs / v6.1) in `ibc-manifests/relayer-api/config/prod/relayer.json` and roll
the relayer. It restarts (it does not cleanly stop), so the **relaying gap = execute → relayer up** (minutes).
The migrated clients now hold the v6.1 vkeys, so the new-build proofs match.

⚠️ **`/dev/shm` precondition — re-confirm on the rolled pod.** The new build proves Cosmos Hub through the SP1
native executor's shared-memory trace ring in `/dev/shm`; the 64 MiB k8s default is exhausted by a single
`cosmoshub-4` proof and fails as `Program simulation failed`. The fix
([ibc-manifests#91](https://github.com/skip-mev/ibc-manifests/pull/91), ≥2 GiB RAM-backed `/dev/shm`) is in the
shared template but takes effect only on a pod restart — so after the roll, confirm the **new** pod actually
has it (full write-up: [`../../../PROOF_API_FAILURE_MODE.md`](../../../PROOF_API_FAILURE_MODE.md)):
```bash
kubectl -n ibc exec ‹prod relayer pod› -- df -h /dev/shm      # must show >= 2.0G, NOT 64M
```
Then confirm vkeys against **prod** — but note `check-relayer-vkeys` only checks `CreateClient` calldata, it
**never runs the prover**, so it passes even on a broken 64 MiB pod:
```bash
PROOF_API_ADDR=‹prod:port› SRC_CHAIN=cosmoshub-4      DST_CHAIN=1 just check-relayer-vkeys --client cosmoshub-0
PROOF_API_ADDR=‹prod:port› SRC_CHAIN=ledger-mainnet-1 DST_CHAIN=1 just check-relayer-vkeys --client ledger-mainnet-1
```
**Gate on a real proof, not just the vkey check or the catch-up watch:** confirm a `cosmoshub-0` packet actually
relays (an `updateClient` / recvPacket landing on-chain) within a few minutes. If proofs don't land and
`/dev/shm` shows 64M, the pod missed #91 — redeploy/restart it before declaring the cut done. In-flight packets
queued during the restart relay through once it's up.

**8. Register ICS27GMP** — a **2-of-5 Safe CALL tx from `0x4b46ea82…`** (NOT a broadcast recipe):
```bash
# data:
cast calldata 'addIBCApp(string,address)' "gmpport" <ics27Gmp.proxy>
# Safe tx: to=ICS26Router 0x3aF134307D5Ee90faa2ba9Cdba14ba66414CF1A7, value=0, operation=0 (CALL); 2-of-5 sign.
```

**9. Initialize every escrow** (permissionless, once each) — **all three**, incl. `client-4`'s. The
`-params` recipe only **prints** `to`/`data`; you must then **submit** each as a normal tx (any funded
EOA — no Safe/timelock):
```bash
just initialize-known-escrows-v2-params      # PRINTS to/data for cosmoshub-0, ledger-mainnet-1, client-4
# for each printed pair, broadcast it:
cast send <escrow_to> <data> --rpc-url <rpc> --private-key <funded EOA>   # or --ledger
# then confirm each escrow flipped:
cast call <escrow> 'authority()(address)' --rpc-url <rpc>                 # == <accessManager>
```

**11. Verify — BEFORE the relayer roll (8a); this gates the cut.** Confirm the on-chain end-state is good, and
only then roll the relayer. A failure here means **do not roll the relayer** — fix forward (C10). Requires
ICS27GMP already registered (step 8) and escrows initialized (step 9), or `verify-deployment` reverts:
```bash
just verify-deployment
just check-sp1-verifier
```

**13. Validate roles.** `rateLimiters` + `rateLimitedEscrows` are **pre-staged top-level** in `1.json` (NOT
under `.accessManagerRoles`, which `DeployV3AccessManager` rewrites — the validator reads them top-level and
hard-fails on a miss) — re-confirm they match the grants you actually folded,
then:
```bash
ETH_RPC=<rpc> FROM_BLOCK=<accessManager-deploy-block> python3 scripts/validate-v3-roles.py mainnet 1
# expect ~33 passed / 0 failed (3 escrows; rate-limiter wiring now a hard gate via rateLimitedEscrows)
```

**Confirm relaying caught up** (the post-8a catch-up drained). Fill the mainnet execution record in `RECORD.md`.

---

## Appendix — independent `safeTxHash` verification

**Signers** use [`SIGNER-CHECKLIST.md`](SIGNER-CHECKLIST.md) + `scripts/signer-verify.sh` — one command per
tx (`bash ~/signer-verify.sh 1 <safe> <nonce> --expect <table hash>`) that recomputes the hashes, decodes
what the tx does, and prints PASS/REJECT. It needs only `cast` (manual mode) — no repo clone / `just` / env.

**Coordinator** generates the expected-hash table from source and has a **second reviewer** regenerate it
before publishing. The recipes print each `safeTxHash` (`just schedule-…-params <N>`,
`EXTRA_TIMELOCK_OPS='…' just execute-v3-upgrade-multisend <execute_nonce> cosmoshub-0 ledger-mainnet-1`), or
run `signer-verify.sh <chain> <safe> <nonce>`. Reject any step-7 proposal whose `to != 0x9641d764…` or
`operation != DelegateCall`.

## Abort / cancel decision tree

The Safe holds `CANCELLER_ROLE`, so a scheduled op can be cancelled during the delay. Decide the path
*before* the window so it isn't improvised:

Relaying needs no special handling on abort — the prod relayer stays on the old build until step 8a, so a
cancel/stand-down just means **never doing 8a** (relaying keeps working on v2 the whole time).

- **Found a problem during the 72 h delay (nothing executed yet):** the v2 system is still fully live (the
  relayer is untouched). **Cancel** the affected scheduled op(s) and re-schedule (another 72 h):
  ```bash
  cast call <timelock> 'hashOperation(address,uint256,bytes,bytes32,bytes32)(bytes32)' … # the opId
  # propose a Safe CALL to the timelock: cancel(bytes32 id), 4-of-7 sign
  cast calldata 'cancel(bytes32)' <opId>
  ```
- **Step-7 atomic execute reverts:** nothing landed (atomic), and the relayer is still on the old build, so
  v2 keeps running. Diagnose, re-build, re-propose *without* re-scheduling — the ops are still pending. Usual
  cause: a folded grant blob that doesn't byte-match its scheduled op, or a schedule that never executed (the
  packer's pending/ready guard catches most at build time). If it can't be fixed in-window: **don't do 8a**
  (the upgrade simply hasn't happened) and regroup.
- **Cannot proceed after the delay elapses:** choose explicitly — (a) stand down (skip 8a; v2 keeps relaying),
  or (b) cancel + reschedule a fresh 72 h round.
- **Execute SUCCEEDED but step-11 verification FAILS (C10):** you **cannot cancel** — it already landed, the
  chain is v3, and `cancel()` only works pre-execute. Because **8a now runs *after* verify**, the relayer is
  **still on the old build** — simply **do not roll it** (don't upgrade the relayer into a bad state). The fix
  is **forward-only**: identify the specific defect (a mis-wired role, a missed escrow init, a
  bad migration), and correct it via a **new timelock round** (schedule the corrective op → 72 h → execute) —
  the same machinery, scoped to the fix. Escrow `initializeV2` and role grants are independently re-issuable;
  a bad SP1 migration is re-done with a fresh `migrateClient`. Until corrected, relaying stays on the old
  build (down for the affected client) — communicate the extended window. There is no "undo" to v2.

## Abort / failure notes

- A migration left unscheduled / mistyped → the packer aborts the build (won't silently shorten the
  MultiSend). Confirm both client ids are in the args and scheduled.
- `verify-deployment` is expected to fail between `deploy-light-client` and the step-7 migration
  execute — only run it after cutover.
