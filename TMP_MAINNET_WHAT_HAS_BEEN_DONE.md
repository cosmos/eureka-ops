# solidity-ibc-eureka v2 → v3 upgrade + SP1 v6.1 migration — mainnet path working note

> Temporary working note (to be removed before merge). Continues from
> `TMP_WHAT_HAS_BEEN_DONE.md`, which records the **testnet** execution (Sepolia, chain
> `11155111`, executed and green). This file picks up at that file's closing *"What remains for
> mainnet"* handoff and tracks the **mainnet (chain `1`)** path. Branch:
> `operations/2026-06-15-upgrade-v2-to-v3`.
>
> **Status: mainnet NOT yet executed.** Everything below is either confirmed pre-upgrade
> on-chain state, a locked decision, tooling built/validated for the mainnet run, or a
> remaining step. The authoritative, maintained copies live in
> `runbooks/operations/2026-06-15-upgrade-v2-to-v3/RECORD.md` and `runbooks/upgrade-v2-to-v3.md`;
> this note is the narrative working log.

## Where this picks up

The testnet upgrade is done and verified. The same two coupled changes now have to land on
mainnet: the v2→v3 core auth migration (per-contract `AccessControl` → shared `AccessManager`,
four core upgrades) and the SP1 v6.1 light-client migration — cut over **atomically** in a
single timelock window.

**Mainnet differs materially from testnet and cannot be driven autonomously:**

- The proposer/executor Safe is a **4-of-7 of hardware wallets**, not a 1-of-2 hot key.
- The `TimelockController` delay is **72 h** (`259 200 s`), not 60 s — so a second
  schedule→delay→execute round is impractical; everything folds into **one** round.
- The privileged customizer account is itself a **Safe multisig**, not an EOA (see decisions).

## Confirmed mainnet pre-upgrade state (on-chain, 2026-06-16)

| Thing | Address / value |
| --- | --- |
| AccessManager | **not deployed** (`0x000…0`) — role testing is post-cutover only |
| Governance Safe (proposer/executor) | `0x7B96CD54aA750EF83ca90eA487e0bA321707559a` — **4-of-7** hardware owners |
| TimelockController (AccessManager `ADMIN_ROLE`) | `0xb3999B2D30dD8c9faEcE5A8a503fAe42b8b1b614` — delay **72 h**; Safe holds PROPOSER/EXECUTOR/CANCELLER; timelock self-administers `DEFAULT_ADMIN` |
| ICS26Router proxy | `0x3aF134307D5Ee90faa2ba9Cdba14ba66414CF1A7` |
| ICS20Transfer proxy | `0xa348CfE719B63151F228e3C30EB424BA5a983012` |
| ID + ERC20 customizer | `0x4b46ea82D80825CA5640301f47C035942e6D9A46` — **a 2-of-5 Safe** (Operational Council), not an EOA |
| Canonical MultiSendCallOnly | `0x9641d764fc13c8B624c04430C7356C1C7C8102e2` |

Role-holder sets in `deployments/mainnet/1.json` match on-chain: **4 relayers, 5 pausers,
unpauser = the Safe itself, 2 delegate senders, 1 id/erc20 customizer (`0x4b46ea82…`), 3 light
clients.**

### Light clients & escrows (mainnet)

| Client | Counterparty | Escrow | Pre-v6.1 verifier | v6.1 plan |
| --- | --- | --- | --- | --- |
| `cosmoshub-0` | `08-wasm-1369` | `0x0fA75C2c49d7dB7ed62c5Fb70bF78ba614aE6A89` | `0x2bB76Cb5…` (direct v5.0.0) | **migrate** → gateway |
| `ledger-mainnet-1` | `08-wasm-0` | `0xC76944B0159D7Dd5c4cF6936b0f45E8de9b34092` | `0xbB3FeAbf…` (direct v5.0.0) | **migrate** → gateway |
| `client-4` | `08-wasm-301` | `0x3f36Fd49251475aC17bB680D56F412Bf81Aa5778` | `0x397A5f7f…` (gateway, already set) | **DROPPED** (see decisions) |

> The committed `deployments/mainnet/1.json` is still **pre-v6.1**: all three clients carry the
> *current* on-chain vkeys (`updateClient=0x009443d9…`), and two of three still point `.verifier`
> at direct v5.0.0 verifiers. The SP1 v6.1 staging (procedure step 5) is **real, not-yet-done
> work** for the two migrated clients. The SP1 v6.1 Groth16 trio is the **same as testnet**:
> gateway `0x397A5f7f…` → real `0xb69f2584…` (`VERSION()==v6.1.0`, selector `0x4388a21c`); the
> broken `0xf0f70E15…` is testnet-only and absent on mainnet.

## Decisions locked (2026-06-16 / 06-17)

1. **SP1 tag.** Final `sp1-programs v2.0.0` is cut **at the same commit hash as `v2.0.0-rc.2`**,
   so the vkeys are **byte-identical** to the rc.2 set testnet already validated
   (`updateClient=0x00d38536…`, membership `0x000bd8ec…`, ucAndMembership `0x009fe47d…`,
   misbehaviour `0x0010008d…`). Either tag at that commit is fine; the prod relayer must load the
   same build.
2. **`client-4` DROPPED.** Not migrated to v6.1. Backed by the prod relayer config
   (`ibc-manifests/relayer-api/config/prod/relayer.json`): the only mainnet (`dst/src "1"`)
   modules are `cosmoshub-4` and `ledger-mainnet-1` — there is no module for
   `client-4`/`provider`/`08-wasm-301`, so it is not a live relayed channel. **Migrate set =
   `cosmoshub-0` + `ledger-mainnet-1` (2 clients).** Its *escrow* is still upgraded + initialized
   by the core beacon upgrade; only its light-client migration is skipped.
3. **Dropped v2 capabilities — acceptable.** `TOKEN_OPERATOR` (in-place IBCERC20 relabel;
   replacement `setCustomERC20`/`ERC20_CUSTOMIZER` retained by `0x4b46ea82…`) and per-client
   `LIGHT_CLIENT_MIGRATOR` (migration now ADMIN-gated) are intentionally gone.
4. **Proof-api endpoint + `SRC_CHAIN`.** At cutover the proof-api is a **localhost** endpoint
   (k8s port-forward): `PROOF_API_ADDR=localhost:<port>`, `DST_CHAIN=1`. From the prod config the
   `cosmos_to_eth` source per eth-side client is **`cosmoshub-0` ← `cosmoshub-4`** and
   **`ledger-mainnet-1` ← `ledger-mainnet-1`** (differs from testnet, where the hub source is
   `provider`). Prod relayer currently loads `sp1-programs/v1.2.0`; the lockstep cutover bumps
   those paths to the v2.0.0 build in that config.
5. **Customizer `0x4b46ea82…` is a 2-of-5 Safe** (v1.4.1; verified on-chain). **Step 8
   (`addIBCApp`) is a Safe CALL tx from that Safe, not a Ledger broadcast** — the
   `register-ics27-gmp` forge recipe cannot be used. Build
   `addIBCApp("gmpport", <mainnet ics27Gmp.proxy>)` (`to` = ICS26Router `0x3aF13430…`, value 0)
   and 2-of-5 sign it after the router upgrade.
6. **Governance-Safe proposer is a Ledger at `MNEMONIC_INDEX=1`** (`m/44'/60'/0'/0/1`).

## Mainnet grant-set & token audit (pre-cutover; re-run before the window)

Discovered with `scripts/discover-v2-roles.py mainnet 1` (reconstructs v2 holders from
`RoleGranted`/`RoleRevoked` and reconciles vs the JSON):

- The **6 bootstrap-migrated roles match the JSON exactly** (relayers, pausers, unpausers,
  delegate senders, id/erc20 customizer) — no action.
- **`RATE_LIMITER` is the only grant not covered by the JSON** and, unlike testnet, is
  **non-empty**: held by `0x4b46ea82…` and `0x64259f72…` on **both** the `cosmoshub-0`
  (`0x0fA75C2c…`) and `ledger-mainnet-1` (`0xC76944B0…`) escrows; `client-4`'s escrow has none.
  These must be re-granted (folded into the single round — below).
- **TOKEN_OPERATOR / per-client migrator** are dropped by design (decision 3).
- **IBCERC20 metadata** customization *was* used (5 of 13 beacon tokens carry custom
  name/symbol/decimals) and **survives** the beacon upgrade unchanged (identical storage layout,
  proxies never re-initialized). `setCustomERC20` registers external tokens with no event, so the
  registered-denom set is larger than `IBCERC20ContractCreated` implies (13 beacon + 6 external =
  19). Informational; no action.

## Mainnet-specific tooling & hardening added this session

Beyond the testnet tooling (carried over), three changes were made specifically to make the
4-of-7 / 72 h mainnet path safe, all rehearsed on a mainnet fork (below):

- **Ledger proposer signing** — `scripts/safe-propose.sh` gained a Ledger branch
  (`LEDGER=1` / `--ledger`, `MNEMONIC_INDEX`, `MNEMONIC_DERIVATION_PATH`) that blind-signs the
  EIP-712 `safeTxHash`; it takes precedence over `PRIVATE_KEY` and is inherited by the
  `propose-schedule` / `safe-propose` recipes through the env. Mainnet proposer uses
  `LEDGER=1 MNEMONIC_INDEX=1 just propose-schedule …` / `… just safe-propose …`. The
  `PRIVATE_KEY` path is byte-for-byte unchanged. **Not yet exercised with a physical device** —
  do one testnet dry-run with the real Ledger before the window (the device must have blind
  signing enabled; confirm the on-device hash equals the recipe's).
- **Packer schedule-state guard** — `safe.just` `execute-timelock-multisend` now verifies on-chain
  that **every** packed sub-op is a *pending* `TimelockController` operation
  (`isOperationPending`) before building the bundle. This catches a mistyped/unscheduled client
  id or a byte-mismatched folded grant, which would otherwise pack into a silently-shorter-but-
  valid MultiSend or revert only at execute time after the 72 h delay. Uses `isOperationPending`
  (not `Ready`) so it still passes while previewing the `safeTxHash` during the delay window;
  skipped with a loud warning if no RPC. It catches a *wrong/extra* op but **not an omitted one**
  (an id you forget to pass is never examined) — so the manual client-id reconciliation in step 7
  still applies.
- **Admin-revoke guard** — `script/RevokeRole.sol` refuses `REVOKE_ROLE=0` (the AccessManager
  `ADMIN_ROLE`) unless `ALLOW_REVOKE_ADMIN=true`, so a fat-fingered admin revoke cannot brick
  governance.

### Branch commits (mainnet-path)

| Commit | Subject |
| --- | --- |
| `568ed99` | feat: ledger proposer signing + timelock-pending & admin-revoke guards |
| `ed4d9ae` | docs: lock mainnet decisions; document ledger + execution guards |

(Plus earlier this branch: `01559c8` RECORD/runbook docs, `659052e` discover/validate script
fixes, `188912e` remove stale `bun.lockb`.)

## Mainnet-fork rehearsal — green end-to-end (2026-06-17)

Ran `scripts/shadow-v2-to-v3-timelock-rehearsal.sh 1 mainnet shadow-mainnet …` against a **real
Ethereum-mainnet Anvil fork**, with the drop-aware migrate set
(`SP1_CLIENT_IDS=cosmoshub-0,ledger-mainnet-1`) and the rate-limiter fold
(`REHEARSE_RATE_LIMITER_GRANT=1`). It exercises the production path: deploy the v3 stack
(proxies left on v2), schedule each op through the **real** governance Safe (impersonated) and
timelock, advance past the 72 h delay, prove the ICS26-before-ICS20 ordering revert, then execute
the whole upgrade as **one atomic Safe MultiSend** (`execTransaction`, `operation=1`), register
ICS27, initialize escrows, and verify.

Result — all green:

- v3 stack deployed against the real Safe `0x7B96CD54…` (threshold 4, nonce 18) and timelock
  `0xb3999B2D…`.
- 6 core/migration ops + the folded rate-limiter grant scheduled; ICS26-before-ICS20 reverted
  with `TimelockUnexecutedPredecessor` (ordering enforced).
- **Atomic execute through the new packer:** the recipe `safeTxHash` matched the Safe's on-chain
  `getTransactionHash`, 4-of-7 `approveHash` + `execTransaction` succeeded. The schedule-state
  guard ran on **all 7 pending ops with 0 aborts and 0 RPC-skips** — i.e. it allowed every
  legitimate scheduled op without false-rejecting or changing the bundle.
- The folded rate-limiter grant **landed** via `EXTRA_TIMELOCK_OPS` (raw-`0x` op also passed the
  guard): `setTargetFunctionRole` + `grantRole` confirmed against the real `0x0fA75C2c…` escrow.
- ICS27 registered (as customizer `0x4b46ea82…`), **all 3 escrows** initialized (incl.
  `client-4`'s, confirming its escrow is upgraded even though its client is dropped),
  `VerifyDeployment` passed every section.

Combined with the unit checks — an unscheduled op → guard **refuses**; a freshly-scheduled
pre-delay op → guard **passes** — the packer guard is validated on the actual mainnet path.

> The standard **testnet** timelock rehearsal can no longer run: its deployment JSON is now
> post-upgrade, so the deploy-only step refuses (`accessManager` already set). The mainnet-fork
> rehearsal is the one to use from here.

## The mainnet cutover plan (single 72 h round)

1. **Stage SP1 v6.1 (step 5)** for `cosmoshub-0` and `ledger-mainnet-1` only: fresh trusted state
   from the localhost proof-api (`SRC_CHAIN` = `cosmoshub-4` / `ledger-mainnet-1`, `DST_CHAIN=1`),
   v6.1 vkeys from the v2.0.0-at-rc.2-commit release, repoint `.verifier` to the gateway, deploy
   the new `SP1ICS07Tendermint` per client.
2. **Relayer lockstep (step 5e)** — cut the prod proof-api/relayer to the same `sp1-programs`
   build (bump `v1.2.0` → `v2.0.0` in `relayer-api/config/prod/relayer.json`); `check-relayer-vkeys`
   must pass against the prod proof-api before scheduling.
3. **Take the `RATE_LIMITER` snapshot** (re-run `discover-v2-roles.py mainnet 1`) while escrows
   are still v2 `AccessControl`, to get the exact `(client_id, rate_limiter)` pairs.
4. **Schedule the step-6 window** via the Ledger proposer: the 4 core upgrades + 2 migrations +
   the rate-limiter re-grant(s); capture each grant's byte-identical `execute` blob.
5. **After 72 h, atomic execute (step 7)** — one Safe MultiSend (DelegateCall to MultiSendCallOnly
   `0x9641d764…`) packing the 6 core/migration executes + the rate-limiter grant via
   `EXTRA_TIMELOCK_OPS`; halt relaying around the window.
6. **Step 8** — `addIBCApp("gmpport", ics27)` as a **2-of-5 Safe CALL tx** from `0x4b46ea82…`.
7. **Steps 9–11** — initialize all 3 escrows, then `verify-deployment` + `check-sp1-verifier`;
   resume relaying only after both pass.
8. **Step 13** — `validate-v3-roles.py mainnet 1` (expect ~33 passed / 0 failed; populate
   `.accessManagerRoles.rateLimiters` with the re-granted holders first so role 5 matches).

## What remains before / at cutover

- [ ] SP1 v6.1 staging (step 5) for the two migrated clients — not yet done.
- [ ] Prod relayer cut to the v2.0.0 build; `check-relayer-vkeys` green against the prod proof-api.
- [ ] One **Ledger device dry-run** on testnet to confirm the `safe-propose.sh` `--ledger` branch
      end-to-end (blind signing enabled, on-device hash matches).
- [ ] Fresh `RATE_LIMITER` snapshot immediately before scheduling (holders can change).
- [ ] Confirm the proposer Ledger path/index and that the 2-of-5 customizer Safe owners are ready
      for the step-8 signing.
- [ ] Schedule (step 6) → wait 72 h → atomic execute (step 7) → register/init/verify (8–11) →
      validate roles (13); halt + resume relaying around the window.
- [ ] Fill the mainnet execution record in
      `runbooks/operations/2026-06-15-upgrade-v2-to-v3/RECORD.md` (addresses, tx hashes, nonces,
      final granted `(client_id, holder)` set, verification results, relaying halt/resume times).
- [ ] **PR #19** stays gated on the mainnet upgrade: the `verify (… .json)` CI jobs remain red on
      any chain still on v2 until its step 11 completes.
