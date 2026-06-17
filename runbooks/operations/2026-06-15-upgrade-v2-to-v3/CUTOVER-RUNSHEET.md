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

- [ ] **Shadow-fork dress rehearsal green**, incl. the rate-limiter fold:
      `REHEARSE_RATE_LIMITER_GRANT=1 just shadow-v2-to-v3-mainnet-timelock` (and the staged-v6.1
      variant — preserve a `shadow-mainnet` JSON carrying the v6.1 vkeys + gateway and run with
      `SHADOW_FORK_PRESERVE_DEPLOYMENT=1`).
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

**5e. Relayer lockstep gate** — cut the prod relayer to the same `v2.0.0` build (bump
`v1.2.0`→`v2.0.0` in `ibc-manifests/relayer-api/config/prod/relayer.json`), then:
```bash
PROOF_API_ADDR=localhost:<port> SRC_CHAIN=cosmoshub-4 DST_CHAIN=1 just check-relayer-vkeys   # one call validates all
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

**Just before executing:** confirm the delay elapsed; **halt packet relaying** (assigned owner);
re-run `discover-v2-roles.py mainnet 1` to confirm the grant set didn't change. Confirm each folded
op is ready:
```bash
cast call <timelock> 'isOperationReady(bytes32)(bool)' <opId>   # per folded grant
```

**Build + propose the atomic MultiSend** — the 6 core/migration executes + the rate-limiter grant
executes folded via `EXTRA_TIMELOCK_OPS` (`;`-separated raw blobs captured above). The packer also
auto-verifies every sub-op is a pending timelock op before building:
```bash
EXTRA_TIMELOCK_OPS='0x<rl-grant-exec-1>;0x<rl-grant-exec-2>;0x<rl-grant-exec-3>;0x<rl-grant-exec-4>' \
  just execute-v3-upgrade-multisend <execute_nonce> cosmoshub-0 ledger-mainnet-1
# prints to/value/operation(=1)/data/safeTxHash — verify, then propose as DelegateCall at the SAME nonce:
EXTRA_TIMELOCK_OPS='…' LEDGER=1 MNEMONIC_INDEX=1 \
  just safe-propose 0x9641d764fc13c8B624c04430C7356C1C7C8102e2 <multisend_data> <execute_nonce> 1
```
4-of-7 sign + execute in the Safe UI / device. **Verify on-device: `to == 0x9641d764…`,
`operation == DelegateCall`, `safeTxHash` == the recipe's recomputed value.** Atomic + ordered
(ICS20 before ICS26) — if any sub-execute reverts, nothing lands.

→ record the `execTransaction` tx hash in `RECORD.md`.

---

## Phase D — Post-cutover (relaying still halted)

**8. Register ICS27GMP** — a **2-of-5 Safe CALL tx from `0x4b46ea82…`** (NOT a broadcast recipe):
```bash
# data:
cast calldata 'addIBCApp(string,address)' "gmpport" <ics27Gmp.proxy>
# Safe tx: to=ICS26Router 0x3aF134307D5Ee90faa2ba9Cdba14ba66414CF1A7, value=0, operation=0 (CALL); 2-of-5 sign.
```

**9. Initialize every escrow** (permissionless, once each) — **all three**, incl. `client-4`'s:
```bash
just initialize-known-escrows-v2-params      # cosmoshub-0, ledger-mainnet-1, client-4
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

## Abort / failure notes

- A sub-execute reverting in step 7 reverts the **whole** bundle — nothing lands; diagnose, re-build,
  re-propose. A folded grant whose execute blob doesn't byte-match its scheduled op (or whose
  schedule didn't execute) is the usual cause; the packer's `isOperationPending` guard catches most
  of these at build time.
- A migration left unscheduled / mistyped → the packer aborts the build (won't silently shorten the
  MultiSend). Confirm both client ids are in the args and scheduled.
- `verify-deployment` is expected to fail between `deploy-light-client` and the step-7 migration
  execute — only run it after cutover.
