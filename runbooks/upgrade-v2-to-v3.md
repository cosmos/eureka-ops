# RUNBOOK — solidity-ibc-eureka v2→v3 upgrade (incl. SP1 v6.1)

## Context

- **Auth model.** v3 replaces per-contract `AccessControl` with a shared OpenZeppelin `AccessManager`.
- **Core upgrade order is mandatory:** `ICS20Transfer` → `ICS26Router` → `Escrow` beacon → `IBCERC20` beacon. `ICS20Transfer.initializeV2` authenticates against v2 admin records still stored on `ICS26Router`, and `ICS26Router.initializeV2` deletes them — upgrading the router first makes the transfer upgrade revert. Each `ICS20Transfer`/`ICS26Router` `upgradeToAndCall` must call `initializeV2(accessManager)`.
- **Escrows:** after the escrow beacon upgrade, every escrow proxy needs a one-time `Escrow.initializeV2()` (callable by anyone, once each).
- **Atomic execute (step 7).** All timelock executes are submitted as one Safe MultiSend, so the chain never settles in a mixed v2/v3 state. Halt relaying around it anyway as defense-in-depth.
- **SP1 v6.1.** Light clients are standalone contracts — upgrading the core proxies does not touch them. Each client needs a fresh `SP1ICS07Tendermint` deployment plus a timelocked `ICS26Router.migrateClient(...)`, in this same operation/timelock window. `migrateClient` is now AccessManager-controlled (no per-client migrator role); integrators that need self-owned client migration must move to a proxy-style client design.
- **vkeys + relayer lockstep.** Set vkeys from the **published `sp1-programs` release** the prover loads, never the repo test fixtures (which can build non-reproducibly and differ). The prod proof-api/relayer must be cut over to a build of that same release **in lockstep** with the on-chain migration, or migrated clients' proofs will not verify.
- **Expected-failure windows — do NOT "fix":**
  - `just verify-deployment` fails between `deploy-light-client` and the migration execute (the JSON points at the new client while the router still maps the old one). Only run final verification after the migration.
  - The `verify (… .json)` CI jobs stay red from when v3 tooling lands on `main` until step 11 completes on that chain (`VerifyDeployment` asserts v3 state while the chain is still v2).
- **Rate limits.** In v3 `RATE_LIMITER_ROLE` is manager-wide; once any escrow's target role is configured, every holder can set limits on all configured escrows (no v2 per-escrow isolation).
- **Signing.** Broadcast recipes (`deploy-*`, `register-ics27-gmp`) sign with `PRIVATE_KEY` if set, otherwise a Ledger (`--ledger --sender $SENDER`; add `MNEMONIC_INDEX` if the address isn't Ledger account 0, and enable blind signing for contract calls). The Safe steps (6–7) instead sign the `safeTxHash` (Safe UI or signing device). **Step 8 must be sent from an `.accessManagerRoles.idCustomizers` account — usually *not* the deployer key.**

## Shadow fork rehearsal

Rehearse the full sequence against a local Anvil fork (uncommitted changes included). Restart the fork before each fresh rehearsal.

Sepolia — terminal 1:

```bash
export SEPOLIA_RPC=<SEPOLIA_RPC_URL>
just shadow-start-sepolia
```

Terminal 2:

```bash
just shadow-v2-to-v3-sepolia-with-sp1
```

Mainnet — terminal 1:

```bash
export MAINNET_RPC=<MAINNET_RPC_URL>
just shadow-start-mainnet
```

Terminal 2:

```bash
just shadow-v2-to-v3-mainnet-with-sp1
```

Generic form for non-default environments:

```bash
just shadow-v2-to-v3-with-sp1 <chain_id> <source_env> <shadow_env> <port>
```

The rehearsal copies the real deployment JSON into an ignored `deployments/shadow-*` env, deploys the v3 AccessManager/ICS27/implementations, impersonates `.accessManagerRoles.admin` to run the upgrades, deploys + migrates the SP1 clients, registers ICS27, initializes escrows, and verifies. SP1 clients default to every `clientId` in the JSON, and the rehearsal asserts the on-fork migration count matches that list — so it cannot silently pass as a core-only upgrade. Pass a comma-separated client list as the final argument to rehearse a subset.

To rehearse staged SP1 v6.1 state that is not yet in the source JSON:

```bash
just shadow-copy-deployment <chain_id> <source_env> <shadow_env>
# edit deployments/<shadow_env>/<chain_id>.json with the planned SP1 v6.1 trusted state + vkeys
just shadow-v2-to-v3-preserve <chain_id> <source_env> <shadow_env> <port> <expected_migrations> <client_ids_csv>
```

### Timelock rehearsal (real schedule/execute path)

The `-with-sp1` recipes impersonate the admin and call the proxies directly — they validate contract mechanics but not the timelock. To exercise the production path (recipe calldata through the real `TimelockController`, including the predecessor that enforces ICS20-before-ICS26 ordering):

```bash
just shadow-v2-to-v3-sepolia-timelock
```

Mainnet form:

```bash
just shadow-v2-to-v3-mainnet-timelock
```

The proposer/executor Safe and SP1 client ids are read from the JSON (set `SP1_CLIENT_IDS` to migrate a subset). It deploys the v3 stack (proxies left on v2), schedules each op via the impersonated Safe, advances past `getMinDelay()`, asserts that executing ICS26Router before ICS20Transfer reverts, executes the upgrades + migrations, registers ICS27, initializes escrows, and verifies.

**Before a mainnet run that folds in grants (step 7), rehearse the fold:** set `REHEARSE_RATE_LIMITER_GRANT=1` to also schedule a representative rate-limiter grant, fold its execute into the atomic MultiSend via `EXTRA_TIMELOCK_OPS`, and assert on-chain that it landed — exercising the `EXTRA_TIMELOCK_OPS` path end-to-end before it runs live. It's off by default (the core rehearsal is unchanged).

```bash
REHEARSE_RATE_LIMITER_GRANT=1 just shadow-v2-to-v3-sepolia-timelock
```

## Runbook

### 1. Create the operations branch

```bash
just new-operation upgrade-v2-to-v3 <environment> <chain_id>
```

### 2. Deploy the v3 AccessManager

**Before running:** `.accessManagerRoles.*` becomes the source of truth at this step (the legacy `.ics20Transfer.*` / `.ics26Router.*` keys are read only when the matching `.accessManagerRoles.*` key is absent, and editing them afterward has no effect). Confirm `delegateSenders`, `relayers`, `pausers`, `unpausers`, `idCustomizers`, and `erc20Customizers` each list **every** account that must keep working after the authority switch — in particular the full relayer set, or relaying breaks at cutover.

```bash
just deploy-v3-access-manager
```

Writes `.accessManager`, `.accessManagerRoles`, and `.ics27Gmp` to the deployment JSON; grants `.accessManagerRoles.admin` the `ADMIN_ROLE`; configures target function roles for the existing `ICS26Router`/`ICS20Transfer` proxies and the new `ICS27GMP` proxy; copies the role holders from the JSON.

### 3. Deploy the four v3 implementations

Run once per contract, selecting each when prompted (`ICS20Transfer`, `ICS26Router`, `Escrow`, `IBCERC20`):

```bash
just deploy-implementation
```

### 4. Record the new implementation addresses

Update `deployments/<environment>/<chain_id>.json`:

- `.ics20Transfer.implementation`
- `.ics26Router.implementation`
- `.ics20Transfer.escrowImplementation`
- `.ics20Transfer.ibcERC20Implementation`

### 5. Prepare and deploy the SP1 v6.1 migrations

Same branch, once per client moving to v6.1.

> **Mainnet (chain 1): the committed `deployments/mainnet/1.json` is still PRE-v6.1.** All three
> clients carry the *current* on-chain vkeys (`updateClient=0x009443d9…`), and two of three still
> point `.verifier` at direct v5.0.0 verifiers (`cosmoshub-0`→`0x2bB76Cb5…`,
> `ledger-mainnet-1`→`0xbB3FeAbf…`); only `client-4` is already on the `0x397A5f7f…` gateway. So
> this whole step **is real work for mainnet**, not already staged — but only for the two migrated
> clients. **`client-4` is DROPPED** (decided 2026-06-16): its chainId is the generic `"provider"`,
> its height is frozen, and the prod relayer config has no module for it, so it is not a live relayed
> channel. **The migrate set is `cosmoshub-0` + `ledger-mainnet-1` only** — use exactly those two
> everywhere the client list appears (rehearsal, expected-count, step-7 execute args). See
> [`runbooks/operations/2026-06-15-upgrade-v2-to-v3/RECORD.md`](operations/2026-06-15-upgrade-v2-to-v3/RECORD.md).

**a. Trusted state** — regenerate from the proof-api (version-independent, so the existing proof-api is fine). Prompts for the client ID:

```bash
just deploy-fresh-light-client-state
```

**b. Verification keys** — set from the published `sp1-programs` release the prover loads, never the repo test fixtures. Downloads the released ELFs (the exact bytes the prover `wget`s) and computes the vkeys, so they match the prover; the four vkeys are identical across clients of the same release. Override the release with `--version <tag>` (default `v2.0.0-rc.2`):

```bash
just sp1-vkeys --write <environment> <chain_id> <client_id>...
```

Put `--version <tag>` **before** `--write` — the `--write` handler greedily consumes all remaining
args as client ids, so a trailing `--version` is misparsed. `sp1-vkeys` needs a local
solidity-ibc-eureka checkout (`SOLIDITY_IBC_EUREKA`) plus the cargo + SP1 toolchain. **Tag decision
(2026-06-16): final `sp1-programs v2.0.0` is cut at the same commit hash as `v2.0.0-rc.2`.** vkeys
are a pure function of the ELFs, so the final tag's vkeys are **byte-identical** to the rc.2 set
testnet validated (`updateClient=0x00d38536…`, etc.); use either tag at that commit. The prod
relayer must run the *identical* build (gated in step 5e).

**c. Verifier** — set `.verifier` to the SP1 v6.1 gateway for the chain (Groth16 or Plonk, matching the client's `zkAlgorithm`). It must be an explicit nonzero address for `mainnet`/`testnet`/non-default shadow envs (empty or `"mock"` is only allowed for `local`/`shadow-mainnet`/`shadow-sepolia`). Validate before deploying — with `ETH_RPC` set this also checks on-chain that the gateway routes v6.1.0 proofs to the real (non-broken) verifier:

The SP1 v6.1 Groth16 verifier trio (same on **mainnet and testnet**): gateway
`0x397A5f7f3dBd538f23DE225B51f532c34448dA9B` → real v6.1.0 verifier
`0xb69f2584CBcFf99a58C4e7002E8b89Af54a6f4e2` (`VERSION()==v6.1.0`, proof selector `0x4388a21c`).
The known-**broken** v6.1.0 verifier `0xf0f70E15e9259970481c4F33bD87C3e47f161dec` is testnet-only and
absent on mainnet. On mainnet, `client-4` already has the gateway set; `cosmoshub-0` and
`ledger-mainnet-1` must be repointed from their direct v5.0.0 verifiers to the gateway.

```bash
just check-sp1-verifier
```

**d. Deploy the new SP1 client** — run once per client. It deploys a fresh `SP1ICS07Tendermint` from the JSON's trusted state + vkeys + verifier + merkle prefix, then overwrites that client's `.implementation` and re-confirms `.verifier`. Record the previous and new implementation addresses in the operation notes — the previous one is overwritten in the JSON. Answer the two prompts:

- **`Client ID to deploy (leave empty for a new deployment)`** — enter the **existing** client id (e.g. `hub-testnet-0`); leaving it empty is only for provisioning a brand-new client, not a migration. (`CLIENT_ID=<id>` sets it non-interactively.)
- **`Deployment address already exists … deploy a copy?`** — type **`y`**: the guard fires because the client already has a deployed implementation, and replacing it with the v6.1 contract is exactly the migration. Any other answer cancels with no deploy. (`SP1_DEPLOY_COPY=true` auto-confirms.)

The router still maps the client id to the OLD implementation until the step-7 `migrateClient` executes, so `just verify-deployment` is expected to fail until then.

```bash
just deploy-light-client
```

**e. Relayer lockstep gate** — the prod proof-api/relayer must be cut over to a build of the same `sp1-programs` release, in lockstep with the migration (step 7). Before scheduling/executing, confirm the running relayer serves the exact programs recorded in the JSON; a mismatch means every migrated client's proofs revert. `SRC_CHAIN` is the proof-api's source (Cosmos) chain id, not the eth-side client id; one call validates all clients (vkeys are program-derived):

```bash
PROOF_API_ADDR=<host:port> SRC_CHAIN=<cosmos_src_chain> DST_CHAIN=<chain_id> just check-relayer-vkeys
```

> `SRC_CHAIN` is the proof-api's **module identifier** (the `cosmos_to_eth` source whose
> `ics26_address` matches the mainnet `ics26Router.proxy` `0x3aF13430…`), **not** the clientId and
> **not** the chain-id; use `DST_CHAIN=1` on mainnet. **Pinned from the prod config**
> (`ibc-manifests/relayer-api/config/prod/relayer.json`, 2026-06-16): **`cosmoshub-0` ← `SRC_CHAIN=cosmoshub-4`**,
> **`ledger-mainnet-1` ← `SRC_CHAIN=ledger-mainnet-1`** (the hub source is *not* `provider` on
> mainnet, unlike testnet). At cutover the proof-api is a **localhost** endpoint via k8s
> port-forward: `PROOF_API_ADDR=localhost:<port>`. A wrong **but valid** module silently generates
> *another chain's* trusted state (a non-existent module merely errors). The prod relayer currently
> loads `sp1-programs/v1.2.0` ELFs (pre-v6.1); the lockstep cutover bumps those paths to the v2.0.0
> build in that same config file. Each `CreateClient` takes ~3–4 min — don't abort/retry mid-call.
> `deploy-fresh-light-client-state` (step 5a) takes the same `SRC_CHAIN`.

### 6. Schedule all timelocked operations

Each upgrade/migration is scheduled by a Safe transaction that calls `TimelockController.schedule(...)`. The `schedule-v3-*` recipes only **generate** that calldata + the Safe `safeTxHash` (they broadcast nothing); `propose-schedule` signs and posts it to the Safe as a pending tx. An operation is scheduled only once its Safe tx **executes**.

**1. Verify the payload first.** `propose-schedule` signs *and* posts in one invocation, so decode the calldata **before** proposing. Run the bare recipe to print its `data:` (the call the timelock will make), and for the `ICS20Transfer`/`ICS26Router` upgrades confirm it decodes to `upgradeToAndCall(newImplementation, initializeV2(accessManager))` — `newImplementation` = the step-4 `.ics20Transfer.implementation` / `.ics26Router.implementation`, inner call `initializeV2` carrying `.accessManager`. The paired `initializeV2` is mandatory: it hands the contract to the shared AccessManager (the router's also deletes the v2 admin records the transfer upgrade authenticates against); without it, authorization breaks.

```bash
just schedule-v3-ics20transfer-upgrade-params                  # no nonce: prints `data:` (no safeTxHash yet)
cast decode-calldata 'upgradeToAndCall(address,bytes)' <data>  # -> newImplementation, inner bytes
cast decode-calldata 'initializeV2(address)' <inner-bytes>     # -> accessManager
```

**2. Propose each schedule.** Signs the `safeTxHash` with your owner `PRIVATE_KEY` and posts it to the Safe Transaction Service; the nonce is auto-queued so consecutive calls stack into a queue. It prints `auto-nonce: … -> proposing at nonce N` and the `safeTxHash`, and prompts before posting:

```bash
just propose-schedule schedule-v3-ics20transfer-upgrade-params
just propose-schedule schedule-v3-ics26router-upgrade-params
just propose-schedule schedule-escrow-upgrade-params
just propose-schedule schedule-ibcerc20-upgrade-params
just propose-schedule schedule-v3-light-client-migration-params <client_id>   # once per SP1 client
```

`PRIVATE_KEY` must be a Safe owner; set `SAFE_API_KEY` if the transaction service requires auth; override the auto nonce with `SAFE_NONCE=<n>`. The migration schedules are calldata-only, so they can be proposed before the `ICS26Router` proxy is upgraded. No CLI access? Build the Safe tx by hand instead: `just get_safe_nonce`, then `just schedule-v3-ics20transfer-upgrade-params <nonce>`, and submit a Safe tx with `to` = the TimelockController (`.accessManagerRoles.admin`), `value` = `0`, `data` = the printed `timelock calldata`. (The `to:`/`data:` above `timelock calldata` are the timelock op's *target* — the proxy — not the Safe tx destination.)

**3. Each signer independently verifies the `safeTxHash` before approving** — don't simply trust the proposer's printout. Using the queued nonce `N` from the `auto-nonce … nonce N` line, recompute it and confirm it matches both the Safe UI and your signing device:

```bash
just schedule-v3-ics20transfer-upgrade-params <N>   # prints the safeTxHash for nonce N
```

**4. Execute each** pending Safe tx once it has the threshold's signatures (a 1-of-1 Safe needs only yours). All schedules must be executed before step 7.

Folding steps 10/12 into one round (mainnet)? **First take the step-7 `RATE_LIMITER_ROLE` holder snapshot now** — it's valid here because escrows stay v2 `AccessControl` until the step-7 execute — so you have the `(client_id, rate_limiter)` pairs the grant recipes will prompt for. Then schedule each grant in this window and propose it (these recipes prompt, so they don't go through `propose-schedule`):

```bash
just timelock-grant-rate-limiter-role schedule <nonce>   # interactive: prompts for client + rate-limiter
just timelock-grant-role schedule <nonce>                # interactive
just safe-propose <timelock> <schedule-calldata> <nonce> 0
```

Capture each grant's `execute` blob **at the same time, with byte-identical prompt inputs** (run `… execute` right after `… schedule`, save both) — step 7 packs it, and any mismatch with the scheduled op reverts the entire atomic execute.

### 7. Execute the upgrade atomically (after the delay)

**Before running:** confirm the timelock delay has elapsed and the relayer lockstep gate (step 5e) passed. **Snapshot the current v2 `RATE_LIMITER_ROLE` holders on each live `Escrow` now** — you need them to re-grant in step 10, and this execute flips escrows to the AccessManager authority. The escrows are plain (non-enumerable) `AccessControl`, so run **`scripts/discover-v2-roles.py`** (Etherscan logs API, no 50k-block cap) — it reconstructs and `hasRole`-confirms every live v2 holder of *all* roles and reconciles them against the deployment JSON, so it doubles as the completeness check for the whole grant set (rate limiters, plus any role missing from / extra in the JSON). See `runbooks/post-upgrade-role-testing.md`. If none are configured, step 10 is a no-op. Halt packet relaying now and keep it halted until verification passes (step 11).

```bash
just execute-v3-upgrade-multisend <execute_safe_nonce> <client_id_1> <client_id_2> ...
```

Packs each `TimelockController.execute(...)` — `ICS20Transfer`, `ICS26Router`, `Escrow`, `IBCERC20`, then one per SP1 client — into one `MultiSendCallOnly.multiSend(bytes)` Safe transaction (`to` = the canonical MultiSendCallOnly `0x9641d764fc13c8B624c04430C7356C1C7C8102e2` on mainnet/Sepolia, overridable via `MULTISEND_CALL_ONLY`; `value` = `0`; `operation` = `1` delegatecall) and **prints** it — it broadcasts nothing; you propose it via the `safe-propose` step below. The delegatecall runs each `execute` with the Safe as `msg.sender` so it passes the `EXECUTOR_ROLE` check. The recipe prints `to`/`value`/`operation`/`data`/`safeTxHash` (computed with `operation = 1`) for signer verification; pass a non-empty nonce to also print the per-signer signing hashes. Execution is atomic and ordered by the in-batch predecessor (ICS20 before ICS26): if any sub-execute reverts, nothing lands.

**Folding other timelock ops into this one round (mainnet).** A second schedule→delay→execute window is usually impractical on mainnet, so fold the rate-limiter re-grant (step 10) and any role grants (step 12) into *this* atomic execute. Schedule them in the step-6 window too, then add their `execute(...)` calldata via `EXTRA_TIMELOCK_OPS` (`;`-separated). The grant recipes prompt, so they can't run headless inside the packer — generate each once interactively (`just timelock-grant-rate-limiter-role execute` / `just timelock-grant-role execute`), copy its `timelock calldata: 0x…`, and pass the raw blobs:

```bash
EXTRA_TIMELOCK_OPS='0x<rate-limiter-execute>;0x<role-grant-execute>' \
  just execute-v3-upgrade-multisend <execute_safe_nonce> <client_id_1> <client_id_2> ...
```

Or build the bundle explicitly with `just execute-timelock-multisend <nonce> '<op>;<op>;…'`, where each op is an `execute-*` recipe invocation or a raw `0x` `execute(...)` calldata. Every sub-call must be a timelock `execute()` (the packer rejects anything else), and predecessor-linked ops must keep their order (ICS20 before ICS26).

A folded grant's `execute` blob must **byte-match its step-6 scheduled op** (identical prompt inputs) **and that schedule must already be executed** — otherwise `timelock.execute` reverts and the whole atomic bundle reverts with it (after the delay, with relaying halted, forcing the very second round you're avoiding). Before packing, confirm each folded op is scheduled and ready: `cast call <timelock> 'isOperationReady(bytes32)(bool)' <opId>` where `opId = hashOperation(<accessManager>,0,<inner call>,0,0)` and `<inner call>` is the AccessManager call the timelock makes (a `multicall` for the rate-limiter grant — it wires `setTargetFunctionRole` + `grantRole` in one op — and a plain `grantRole` for a bare role grant). Re-verify the `safeTxHash` and decode every sub-call before signing.

**Also reconcile the typed `client_id` args against what you scheduled.** As a backstop, `execute-v3-upgrade-multisend` now verifies on-chain that **every** packed sub-op is a *pending* timelock operation (`isOperationPending`) before building the bundle — so a mistyped id, an unscheduled migration, or a byte-mismatched folded grant aborts the build instead of silently packing into a shorter-but-valid MultiSend (this check needs an RPC; it warns and skips if none is set). That catches a *wrong/extra* op, but **not an omitted one** (an id you simply forgot to pass is never examined), so still confirm manually: for every `.light_clients[]` you intend to migrate, confirm its migration op is scheduled (`isOperationPending` on its `opId`) and that its id is in the args — otherwise a forgotten migration is caught only later by step-11 `verify-deployment`, forcing a second 72 h round.

Propose it as a **DelegateCall** Safe tx (`operation = 1`) at the **same nonce** you printed the hash with — so the hash that gets signed equals the one you verified — then sign and execute it in the Safe UI:

```bash
just safe-propose <multisend_to> <multisend_data> <execute_safe_nonce> 1
```

> **Mainnet (4-of-7 hardware Safe) proposal path.** The designated proposer (2026-06-16) is a
> governance-Safe owner signing with a **Ledger at `MNEMONIC_INDEX=1`** (derivation
> `m/44'/60'/0'/0/1`). `scripts/safe-propose.sh` now has a Ledger branch (`LEDGER=1` / `--ledger`,
> `MNEMONIC_INDEX`, `MNEMONIC_DERIVATION_PATH`), inherited by `propose-schedule` / `safe-propose`
> through the env, so either (a) propose with the Ledger —
> `LEDGER=1 MNEMONIC_INDEX=1 just safe-propose <multisend_to> <multisend_data> <nonce> 1` (and
> `LEDGER=1 MNEMONIC_INDEX=1 just propose-schedule …` for the step-6 schedules) — or (b) reconstruct
> the bundle in the Safe Transaction Builder as a **delegatecall to MultiSendCallOnly `0x9641d764…`**.
> The Ledger blind-signs the 32-byte `safeTxHash`, so enable blind signing and confirm the on-device
> hash equals the recipe's recomputed value; do one testnet dry-run with the real device first. In every case each
> signer must verify **on-device** that `to == 0x9641d764…`, `operation == DelegateCall`, and the
> `safeTxHash` equals the recipe's recomputed value (next paragraph) **before** approving. Assign
> explicit owners for halting and resuming relaying around the window, and run steps 7 → 9 → 11
> back-to-back to keep it short.

**Verify before signing (critical for a DelegateCall):** a delegatecall runs the target's code with the Safe as `msg.sender`, so before signing confirm on your device that `to` == the canonical MultiSendCallOnly (`0x9641d764fc13c8B624c04430C7356C1C7C8102e2`, or your `MULTISEND_CALL_ONLY` override) and `operation` == DelegateCall — **reject any other `to`** — and that the `safeTxHash` matches `just execute-v3-upgrade-multisend <execute_safe_nonce> <client_ids>` recomputed at that nonce.

### 8. Register the ICS27GMP app

`addIBCApp` is gated by the AccessManager `ID_CUSTOMIZER_ROLE`, so it must be sent from an
`.accessManagerRoles.idCustomizers` account — **not** the deployer/Safe-owner key. Must run after
the `ICS26Router` upgrade. The call is `addIBCApp("gmpport", <ics27Gmp.proxy>)` to the ICS26Router
proxy; it reverts if the sender lacks the role.

**If the customizer is an EOA** (e.g. testnet `0x64259f72…`, a Ledger): point the wallet at it
(Ledger via `SENDER` + unset `PRIVATE_KEY`; see **Signing**) and run the broadcast recipe, which
self-verifies:

```bash
just register-ics27-gmp
```

> **Mainnet: the customizer `0x4b46ea82D80825CA5640301f47C035942e6D9A46` is a 2-of-5 Safe (v1.4.1),
> not an EOA** (verified on-chain 2026-06-16) — so `register-ics27-gmp` (a forge broadcast) **cannot
> be used**. Submit `addIBCApp` as a normal **CALL** (not delegatecall) Safe transaction from that
> Safe, signed 2-of-5:
>
> - `to` = ICS26Router proxy `0x3aF134307D5Ee90faa2ba9Cdba14ba66414CF1A7`
> - `value` = `0`, `operation` = `0` (CALL)
> - `data` = `cast calldata 'addIBCApp(string,address)' "gmpport" <mainnet .ics27Gmp.proxy>` (the
>   proxy written at step 2)
>
> No timelock is involved — `addIBCApp` is gated only by `ID_CUSTOMIZER_ROLE`, which this Safe
> holds. Each signer verifies `to`, `value=0`, `operation=CALL`, and the decoded `data` on-device.
> Step 11 `verify-deployment` confirms the registration landed.

### 9. Initialize every existing escrow proxy

Cover all known client IDs in the JSON plus any client IDs with on-chain escrow state. Submit the printed `to`/`data` as a normal transaction (no timelock unless policy requires).

Per client:

```bash
just initialize-escrow-v2-params <client_id>
```

Or for every known JSON client ID with a nonzero escrow:

```bash
just initialize-known-escrows-v2-params
```

### 10. Re-grant `RATE_LIMITER_ROLE`

> **Mainnet: fold this into the single step-6/7 round** rather than a separate timelock window — schedule it in step 6 and pack its execute into the step-7 MultiSend via `EXTRA_TIMELOCK_OPS` (see step 7). The standalone schedule/execute below is the separate-round form (e.g. a later addition).

`deploy-v3-access-manager` does **not** wire any escrow `setRateLimit` role. After the escrow beacon upgrade (step 7) flips escrows to the AccessManager authority, `setRateLimit` defaults to `ADMIN_ROLE`, so every v2 `RATE_LIMITER_ROLE` holder loses access until re-granted. Use the holder list from `scripts/discover-v2-roles.py` (it enumerates and reconciles the whole grant set, including rate limiters — see `runbooks/post-upgrade-role-testing.md`). For each `(client_id, rate_limiter)` that must keep access (this wires the escrow's `setRateLimit` selector to `RATE_LIMITER_ROLE` and grants the role):

```bash
just timelock-grant-rate-limiter-role schedule
just timelock-grant-rate-limiter-role execute <safe_nonce>
```

> **Mainnet snapshot (2026-06-16):** `RATE_LIMITER_ROLE` is held by `0x4b46ea82…` and `0x64259f72…` on **both** the `cosmoshub-0` and `ledger-mainnet-1` escrows (the `client-4` escrow has none) — confirmed on-chain via `hasRole`. These are **not** in the deployment JSON, so this step is **not** a no-op on mainnet (it was on testnet). The authoritative, maintained copy of this snapshot lives in [`runbooks/operations/2026-06-15-upgrade-v2-to-v3/RECORD.md`](operations/2026-06-15-upgrade-v2-to-v3/RECORD.md); re-confirm with `discover-v2-roles.py` immediately before cutover (holders can change).

`RATE_LIMITER_ROLE` is manager-wide once any escrow's target role is configured. `verify-deployment` does not assert these grants — confirm them manually.

### 11. Verify the deployment

```bash
just verify-deployment
```

For migrated SP1 clients, re-run the on-chain verifier check (with `ETH_RPC` set) to confirm each `.verifier` gateway still routes v6.1.0 proofs to the real verifier:

```bash
just check-sp1-verifier
```

Resume packet relaying only after both pass.

### 12. Grant any remaining roles

> **Mainnet: fold grants needed *at cutover* into the single step-6/7 round** (see step 7); the standalone schedule/execute below is for grants done as a separate, later round.

For accounts that need roles not represented in the deployment JSON, grant them through the AccessManager after the upgrade (known delegate senders should already be in `.accessManagerRoles.delegateSenders` from step 2):

```bash
just timelock-grant-role schedule
just timelock-grant-role execute <safe_nonce>
```

### 13. Validate and test the AccessManager roles

After verification passes, confirm the role wiring landed exactly as configured and is executable.
See **[`runbooks/post-upgrade-role-testing.md`](post-upgrade-role-testing.md)** (read its *Mainnet
adaptation* section first — mainnet is a 4-of-7 Safe with a 72 h timelock).

```bash
# static inventory: every (target,selector)->role, exact membership, authority() wiring
ETH_RPC=<rpc> FROM_BLOCK=<accessManager-deploy-block> python3 scripts/validate-v3-roles.py <env> <chain>
```

Then run the Tier-S gate simulations (read-only); run the Tier-L live execution tests only with
sign-off and via the production Safe/timelock path.

---

> IBCERC20 metadata customization was removed in solidity-ibc-eureka v3. Use the custom ERC20 flow instead of post-deployment IBCERC20 metadata changes.
