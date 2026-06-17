# Mainnet (chain 1) v2→v3 + SP1 v6.1 — cutover runsheet

Pre-filled, ordered execution sheet for the **one-shot 72 h** mainnet window. Mainnet values and
the locked decisions are inlined; `‹…›` marks a value only known at run time (deployed address,
nonce). This is the operating sheet — the **why** lives in
[`../../upgrade-v2-to-v3.md`](../../upgrade-v2-to-v3.md), the **record** in
[`RECORD.md`](RECORD.md). Fill `RECORD.md` as you go.

> **One-shot.** Everything that must take effect at cutover is scheduled in **one** step-6 window
> and folded into **one** atomic step-7 MultiSend; a second 72 h round is the failure mode to avoid.
> Halt relaying for the execute→verify span only.

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

**5e. Relayer lockstep gate — against a CANARY, NOT prod.** ⚠️ **Do not cut the prod relayer here.**
Cutting prod to `v2.0.0` (vkey `0x00d38536…`) while the on-chain clients still hold `0x009443d9…` makes
every `updateClient`/`recvPacket`/`ackPacket` revert `VerificationKeyMismatch` for the **entire 72 h
window** — a multi-day outage of both channels. The prod cut happens in **Phase C under halt** (step 7e).
Here, only prove the *build* serves the right vkeys: point the gate at a **‹canary / non-live proof-api
running the v2.0.0 build›**, scoped to the migrated clients (an *unscoped* run FAILs on the still-pre-v6.1
`client-4`, and per-client `SRC_CHAIN` differs):
```bash
PROOF_API_ADDR=‹canary:port› SRC_CHAIN=cosmoshub-4      DST_CHAIN=1 just check-relayer-vkeys --client cosmoshub-0
PROOF_API_ADDR=‹canary:port› SRC_CHAIN=ledger-mainnet-1 DST_CHAIN=1 just check-relayer-vkeys --client ledger-mainnet-1
```

**5f. Quiesce relaying & packet state (plan the gap).** Owner: ‹…›. The relaying gap begins at the
Phase-C cut and ends at resume (step 11). Before opening the window:
- **Drain both channels** (`cosmoshub-0`, `ledger-mainnet-1`) to a clean state — relay all in-flight
  packets to recv **and** ack, so nothing is left un-acked when relaying stops. Un-acked packets stall
  (recv/ack/timeout all revert on the vkey mismatch) and their **escrowed funds stay locked** until catch-up.
- **Confirm no packet's timeout falls inside the window.** A timeout that elapses during the gap cannot
  be processed until after cutover.
- **Record the post-cutover catch-up / timeout / refund procedure.** Storage survives the beacon upgrade
  so nothing is lost — this is about not stranding users mid-window.

**Trust-root gate (T-minus, re-run right before scheduling — roots can change):**
```bash
ETH_RPC=<rpc> FROM_BLOCK=‹timelock deploy block› scripts/verify-roots.sh mainnet 1   # must be 11/11
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

**Just before executing — in order:**
1. Confirm the **72 h delay elapsed**.
2. **Halt off-chain relaying** for both channels (owner ‹…›). This starts the gap (kept short: steps 7→11).
3. **Cut the prod relayer to `v2.0.0` now** (bump `v1.2.0`→`v2.0.0` in
   `ibc-manifests/relayer-api/config/prod/relayer.json`) and re-run the lockstep gate **against prod**:
   ```bash
   PROOF_API_ADDR=‹prod:port› SRC_CHAIN=cosmoshub-4      DST_CHAIN=1 just check-relayer-vkeys --client cosmoshub-0
   PROOF_API_ADDR=‹prod:port› SRC_CHAIN=ledger-mainnet-1 DST_CHAIN=1 just check-relayer-vkeys --client ledger-mainnet-1
   ```
4. Re-run the discovery gate (now **fail-closed** — must exit **0**) and the trust-root gate:
   ```bash
   python3 scripts/discover-v2-roles.py mainnet 1 && echo OK
   ETH_RPC=<rpc> FROM_BLOCK=‹timelock deploy block› scripts/verify-roots.sh mainnet 1   # 11/11
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

## Phase D — Post-cutover (relaying still halted)

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

**11. Verify**, then **resume relaying** only after both pass:
```bash
just verify-deployment
just check-sp1-verifier
```

**13. Validate roles.** Populate `.accessManagerRoles.rateLimiters` with the re-granted holders
first so role 5 matches, then:
```bash
ETH_RPC=<rpc> FROM_BLOCK=<accessManager-deploy-block> python3 scripts/validate-v3-roles.py mainnet 1
# expect ~33 passed / 0 failed (3 escrows)
```

**Resume packet relaying.** Fill the mainnet execution record in `RECORD.md`.

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

- **Found a problem during the 72 h delay (nothing executed yet):** the v2 system is still fully live and
  un-halted. **Cancel** the affected scheduled op(s) and re-schedule (another 72 h):
  ```bash
  cast call <timelock> 'hashOperation(address,uint256,bytes,bytes32,bytes32)(bytes32)' … # the opId
  # propose a Safe CALL to the timelock: cancel(bytes32 id), 4-of-7 sign
  cast calldata 'cancel(bytes32)' <opId>
  ```
- **Step-7 atomic execute reverts** (after halt): nothing landed (atomic). Diagnose, re-build, re-propose
  *without* re-scheduling — the ops are still pending. Usual cause: a folded grant blob that doesn't
  byte-match its scheduled op, or a schedule that never executed (the packer's pending/ready guard catches
  most at build time). If it can't be fixed in-window: **resume v2 relaying and stand down** (the upgrade
  simply hasn't happened), then regroup.
- **Cannot proceed after the delay elapses:** choose explicitly — (a) resume v2 relaying and stand down,
  or (b) cancel + reschedule a fresh 72 h round. Either way, **un-halt relaying** so the gap doesn't extend.

## Abort / failure notes

- A migration left unscheduled / mistyped → the packer aborts the build (won't silently shorten the
  MultiSend). Confirm both client ids are in the args and scheduled.
- `verify-deployment` is expected to fail between `deploy-light-client` and the step-7 migration
  execute — only run it after cutover.
