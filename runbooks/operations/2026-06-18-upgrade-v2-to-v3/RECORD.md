# Operation record — solidity-ibc-eureka v2 → v3 upgrade + SP1 v6.1 migration

Durable record of the v2→v3 core upgrade (per-contract `AccessControl` → shared OZ
`AccessManager`) and the SP1 light-client v6.1 migration.

- **Procedure (authoritative):** [`../../upgrade-v2-to-v3.md`](../../upgrade-v2-to-v3.md) — do **not**
  follow a copy; that file is the single source of truth and is kept current.
- **Role validation / testing:** [`../../post-upgrade-role-testing.md`](../../post-upgrade-role-testing.md).
- **Mainnet cutover runsheet:** [`CUTOVER-RUNSHEET.md`](CUTOVER-RUNSHEET.md) — pre-filled, ordered
  execution sheet for the 72 h window (mainnet values + decisions inlined).
- **Status:** executed end-to-end on **Sepolia testnet (chain `11155111`)** and **Mainnet (chain `1`) —
  COMPLETE**. Phase A (deploy) + Phase B (schedule, 2026-06-20) + **Phase C (atomic execute, 2026-06-25
  14:58:11 UTC)** + **Phase D (finalize, through 2026-06-26)** all done; `verify-deployment`,
  `check-sp1-verifier`, and `validate-v3-roles.py` (**35/0**) green; live cosmoshub-0 packets relaying
  against the new v6.1 client. See "Mainnet execution record" below.
- **Branch:** `operations/2026-06-18-upgrade-v2-to-v3`.

The goal was two coupled changes executed in a single timelock/operation window, cut over
**atomically** so the chain never settles in a mixed v2/v3 state:

1. **v2 → v3 core upgrade.** Move authorization from per-contract OZ `AccessControl` to a single
   shared OZ `AccessManager`. Upgrade the four core contracts (`ICS20Transfer`, `ICS26Router`,
   `Escrow` beacon, `IBCERC20` beacon) and hand each to the shared manager. The manager's
   `ADMIN_ROLE` is held by the existing `TimelockController`, proposed/executed by the Safe.
2. **SP1 v6.1 light-client migration.** Migrate the Tendermint light clients onto SP1 v6.1
   programs: fresh trusted state, fresh v6.1 verification keys, and a verifier gateway that routes
   v6.1.0 proofs to the real (non-broken) SP1 verifier.

Mandatory upgrade order (enforced on-chain by an in-batch predecessor): `ICS20Transfer` →
`ICS26Router` → `Escrow` beacon → `IBCERC20` beacon. `ICS20Transfer.initializeV2` authenticates
against v2 admin records still on `ICS26Router`, and `ICS26Router.initializeV2` deletes them — so
upgrading the router first makes the transfer upgrade revert.

---

## Testnet execution record — Sepolia (chain `11155111`), 2026-06-16, all green

> Driven via a **1-of-2 Safe whose owner is a hot key** (`0x15C1…5DF9`) and a **60 s** timelock —
> neither holds on mainnet (see "Mainnet" below).

### Deployed addresses

| Component | Address |
| --- | --- |
| Safe (1-of-2 proposer/executor) | `0x85CF98533e3275450a0d61D9BC236225947C5882` |
| Safe owner / deployer + executor EOA | `0x15C1e4924e4f8cE261B5D5cfEB9B96c4bF035DF9` |
| TimelockController (AccessManager `ADMIN_ROLE`) | `0x8948ca6bB5E2F50A235DB3eFf7c125188c6AD14b` |
| **v3 AccessManager** | `0x56172716671657a4DF912d3665603C294DAaE10f` |
| ICS26Router proxy | `0x3fcBB8b5d85FB5F77603e11536b5E90FeE37e6c0` |
| ICS26Router v3 implementation | `0xb0d246aBAc3CC72F2C2A5528606A93707C32f577` |
| ICS20Transfer proxy | `0x3a4e076D1c5EBfC813993c497Bb284598121b515` |
| ICS20Transfer v3 implementation | `0xc2485AF16ca1eFd0878674c9BB239162282098f2` |
| Escrow v3 beacon implementation | `0xb76101cc1fe376d36e97d8f748025a30fd3d8b41` |
| IBCERC20 v3 beacon implementation | `0x49025091c182f871fd3a7f0bc85923ad3b891286` |
| **ICS27GMP proxy** | `0x94f2aCB923081204b171E804E83183d457DBBB72` |
| ICS27GMP implementation | `0xDF35Ceab98F17aad6A522fb65ac6854Bac88074F` |
| ICS27GMP account implementation | `0xc8f8b12C092c063C49851f473cF68f89dC3b8e04` |
| SP1 client `hub-testnet-0` (v6.1) | `0x4A7231eb4AcE32B3e8a3DD9C9004a06149d70E40` |
| SP1 client `ledger-testnet-1` (v6.1) | `0xA95990114e1b50FC66866f68F5C3a322119f8276` |
| SP1 verifier gateway (Groth16) — set on both clients | `0x397A5f7f3dBd538f23DE225B51f532c34448dA9B` |
| SP1 v6.1.0 real Groth16 verifier (gateway routes here) | `0xb69f2584CBcFf99a58C4e7002E8b89Af54a6f4e2` |
| ID + port customizer EOA (Ledger) | `0x64259f722A0868CCf58A935C61A292cEA9dF035a` |
| Canonical MultiSendCallOnly (mainnet/Sepolia) | `0x9641d764fc13c8B624c04430C7356C1C7C8102e2` |

Deployment record: `deployments/testnet/11155111.json`. All deploys broadcast from the deployer
EOA `0x15C1e4924e4f8cE261B5D5cfEB9B96c4bF035DF9`.

### Deploy transaction hashes

| Deploy | Tx hash |
| --- | --- |
| AccessManager (+ ICS27GMP) via `V3AccessManagerBootstrap` | `0x22f4f9cc08a567fafd6f5957f14b13ed3a228d1f781fc1df78e06f21c561bf23` |
| ICS20Transfer v3 impl | `0xb76fd7212948cc6de5e68c64559cbbf0b5da5f2e91afbfe142d28d7f2380cad0` |
| ICS26Router v3 impl | `0x78f4e9efeb81889c3e79f61c6815a0b4ae920c0a11cc2ace5037d0d3176e791a` |
| Escrow v3 beacon impl | `0xbd6518365af063a1384d40d5d4a08ba038476f7b26825cd53b6c44cd3ff4ac6d` |
| IBCERC20 v3 beacon impl | `0x1c94aff0671a08776e1824cde0a12d8847e596be64d1c262edd493226c14710f` |
| SP1 `hub-testnet-0` client deploy | `0x16c2646f928545988dfd2a143e09f4a521f83fbffe183fa062037f5043cdef3d` |
| SP1 `ledger-testnet-1` client deploy | `0x32893715d48aebc427064d8043f6871039b9ee77595dc468638b330d2fe94fd6` |

### Execution timeline

1. **Deploy v3 AccessManager + ICS27GMP** (`DeployV3AccessManager`): admin = TimelockController;
   target function roles wired for the two existing proxies + the new ICS27GMP proxy; role holders
   copied from the JSON.
2. **Deploy the 4 v3 implementations** (`DeployImplementation`, once per contract).
3. **SP1 v6.1 prep + deploy**, per client: fresh trusted state from the proof-api; v6.1 vkeys from
   the released `sp1-programs` ELFs; `.verifier` = the Groth16 gateway; `check-sp1-verifier`
   confirmed routing; new `SP1ICS07Tendermint` deployed for each client.
4. **Relayer lockstep gate** (`check-relayer-vkeys`): confirmed the running proof-api/relayer
   serves the exact v6.1 vkeys recorded in the JSON.
5. **Schedule 6 timelock ops** via Safe txs at **nonces 38–43** — ICS20/ICS26/Escrow/IBCERC20
   upgrades + the two client migrations — advancing the Safe nonce **38 → 44**.
6. **Atomic cutover** — after the timelock delay, the whole upgrade executed as **one** Safe
   MultiSend (`MultiSendCallOnly.multiSend(bytes)` via `operation = 1` DelegateCall) packing all six
   `TimelockController.execute(...)` sub-calls in predecessor order.
   - **execTransaction tx:** `0x9cb74b41ef64fdeadf6085325a946fa871e10a4009087ec8e74e70944b8d5849`
7. **Register ICS27GMP** on port `gmpport` via `ICS26Router.addIBCApp` (now gated by the
   AccessManager `ID_CUSTOMIZER_ROLE`), sent by the ID customizer
   `0x64259f722A0868CCf58A935C61A292cEA9dF035a` via Ledger.
   - **tx:** `0xa2db63b2315af8d605c70cd453001002f65da5fbb997de2908142a4e2683add7`
8. **Initialize both v3 escrows** — `Escrow.initializeV2()` (permissionless, once each) via direct
   `cast send`; escrow authority → AccessManager.

### SP1 v6.1 migration details (testnet)

- **Clients migrated:** `hub-testnet-0` (counterparty `08-wasm-262`) and `ledger-testnet-1`
  (counterparty `08-wasm-3`), merkle prefix `["ibc", ""]`.
- **vkey source — released ELFs, NOT repo fixtures.** vkeys computed from the published
  `sp1-programs` release (default tag `v2.0.0-rc.2`) — the exact bytes the prover loads. The four
  vkeys are identical across both clients (a property of the loaded programs):

  | vkey | value |
  | --- | --- |
  | updateClient | `0x00d38536f65ab10e7eff0895b1b9f7cf12f89691631742bb487fe090027e0e6d` |
  | membership | `0x000bd8ec43ea65b85c87eb57ace44692c3292ff297e01f29542b9fb476ed3e4f` |
  | ucAndMembership | `0x009fe47dbd3934f92417fbe4f17e79fe89417d61a724f66fadbc361b475dc091` |
  | misbehaviour | `0x0010008da4267c2e85d02616e853379e3c937c03a271b5b005f479cff09ccfcb` |

- **Verifier routing.** `.verifier` on both clients is the Groth16 **gateway**
  `0x397A5f7f3dBd538f23DE225B51f532c34448dA9B`. `check-sp1-verifier` confirmed the gateway routes
  the v6.1.0 proof selector (`0x4388a21c`) to the real verifier
  `0xb69f2584CBcFf99a58C4e7002E8b89Af54a6f4e2` (`VERSION() == v6.1.0`), and **not** to the known
  broken v6.1.0 verifier `0xf0f70E15e9259970481c4F33bD87C3e47f161dec`.
- **Relayer lockstep.** `check-relayer-vkeys` confirmed the running proof-api loaded the same
  release the on-chain clients were migrated to. Passed before cutover.

### Verification status (testnet)

- `just verify-deployment` — **passes** all sections (ICS26 / ICS20 / ICS27, both escrows, both SP1
  clients).
- `just check-sp1-verifier` — **passes**: both gateways route v6.1.0 proofs to the real verifier.
- `just check-relayer-vkeys` — **passes**.
- `scripts/validate-v3-roles.py testnet 11155111` — **32/32**, before and after the Part-2 role
  round-trip tests (baseline restored). See `../../post-upgrade-role-testing.md`.

---

## Mainnet (chain `1`) — confirmed pre-upgrade state

Confirmed on-chain 2026-06-16 (pre-upgrade). **Mainnet differs materially from testnet** — a
**4-of-7 Safe** of hardware wallets and a **72 h timelock**; it cannot be driven autonomously.

### Mainnet decisions locked (2026-06-16)

Team answers to the pre-mainnet open questions, each with the evidence that backs it:

1. **SP1 programs tag — resolved.** Final `sp1-programs v2.0.0` is cut **at the same commit hash as
   `v2.0.0-rc.2`**. vkeys are a pure function of the ELFs, so the final tag's vkeys are
   **byte-identical** to the rc.2 set already validated on testnet (`updateClient=0x00d38536…`,
   membership `0x000bd8ec…`, ucAndMembership `0x009fe47d…`, misbehaviour `0x0010008d…`). Step 5b may
   use either tag at that commit; the prod relayer must load the *same* build (step 5e).
2. **`client-4` (`08-wasm-301`) — DROPPED**, not migrated to v6.1. Backed by the prod relayer
   config (`ibc-manifests/relayer-api/config/prod/relayer.json`): the only mainnet (`dst/src "1"`)
   `cosmos_to_eth`/`eth_to_cosmos` modules are **`cosmoshub-4`** and **`ledger-mainnet-1`** — there
   is **no relayer module for `client-4`/`provider`/`08-wasm-301`**, so it is not a live relayed
   channel. **Mainnet migrate set = `cosmoshub-0` + `ledger-mainnet-1` (2 clients).**
3. **Dropped v2 capabilities — acceptable** (signed off). Loss of `TOKEN_OPERATOR` (in-place
   IBCERC20 relabel; the `setCustomERC20`/`ERC20_CUSTOMIZER` replacement is retained by
   `0x4b46ea82…`) and per-client `LIGHT_CLIENT_MIGRATOR` (migration now ADMIN-gated).
4. **Proof-api endpoint + `SRC_CHAIN` module ids — pinned.** At cutover the proof-api is reached
   via a **localhost** endpoint (k8s port-forward): `PROOF_API_ADDR=localhost:<port>`, `DST_CHAIN=1`.
   From the prod config the `cosmos_to_eth` source (`SRC_CHAIN`) per eth-side client is
   **`cosmoshub-0` ← `cosmoshub-4`** and **`ledger-mainnet-1` ← `ledger-mainnet-1`** (differs from
   testnet, where the hub source is `provider`). The prod relayer currently loads
   **`sp1-programs/v1.2.0`** ELFs (pre-v6.1); the lockstep cutover bumps those paths to the v2.0.0
   build in `relayer-api/config/prod/relayer.json`.
5. **ID/ERC20 customizer `0x4b46ea82…` is a Safe, not a Ledger.** Verified on-chain: **Safe v1.4.1,
   2-of-5** (owners `0x7B5Cc5B7…`, `0x05A4De18…`, `0x75D608E8…`, `0xF550B712…`, `0x5622612b…`).
   **Step 8 (`addIBCApp`) is a Safe transaction from `0x4b46ea82…`, not a direct/Ledger broadcast** —
   the `register-ics27-gmp` recipe (a forge broadcast) cannot be used as-is. Build
   `addIBCApp("gmpport", <mainnet ics27Gmp.proxy>)` (`to` = ICS26Router `0x3aF13430…`, value `0`) and
   2-of-5 sign it from that Safe, after the router upgrade.
6. **Governance-Safe proposer is a Ledger at index 1.** The owner who posts proposals to the 4-of-7
   governance Safe `0x7B96CD54…` signs with a **Ledger at `MNEMONIC_INDEX=1`** (derivation
   `m/44'/60'/0'/0/1`). **Implemented (2026-06-16):** `scripts/safe-propose.sh` now signs with a
   Ledger via `LEDGER=1` / `--ledger` (`MNEMONIC_INDEX`, plus `MNEMONIC_DERIVATION_PATH` for a
   Ledger Live path), taking precedence over `PRIVATE_KEY`; the `propose-schedule` / `safe-propose`
   recipes inherit it through the env. So on mainnet:
   `LEDGER=1 MNEMONIC_INDEX=1 just propose-schedule <recipe …>` and
   `LEDGER=1 MNEMONIC_INDEX=1 just safe-propose <to> <data> <nonce> 1`. The Ledger signs the Safe
   **EIP-712 `SafeTx` typed data** (foundry's Ledger signer cannot sign a raw hash —
   `sign_hash` is unsupported), deriving the same `safeTxHash` on-device; enable blind signing /
   EIP-712 on the Ethereum app. The script then re-checks the device signature recovers to the
   printed `safeTxHash` before posting. (The step-7 execute is still `operation=DelegateCall` to
   MultiSendCallOnly `0x9641d764…`.) **Confirmed on a real Ledger (2026-06-17)** via the script's
   `--dry-run` (EIP-712 sign + recovery check passed); the only unrun leg is the actual POST to the
   Safe Transaction Service.
7. **Execution-path hardening — IMPLEMENTED (2026-06-16).** Two defense-in-depth guards landed:
   - `safe.just` `execute-timelock-multisend` (the packer behind `execute-v3-upgrade-multisend`) now
     verifies **every** packed sub-op is a *pending* TimelockController operation on-chain
     (`isOperationPending`) before building the bundle — catching a mistyped/omitted client id, a
     forgotten schedule, or a folded grant whose `execute` blob doesn't byte-match its scheduled op
     (all of which otherwise pack into a silently-shorter-but-valid MultiSend or revert only at
     execute time). `isOperationPending` is true regardless of whether the 72 h delay has elapsed, so
     it still passes while previewing the `safeTxHash`. Skipped with a loud warning if no RPC is set.
   - `RevokeRole.sol` refuses to revoke `ADMIN_ROLE` (id 0) unless `ALLOW_REVOKE_ADMIN=true`, so a
     fat-fingered `REVOKE_ROLE=0` can't brick governance.
   Validated on-chain against a real (Sepolia-fork) timelock: a freshly-scheduled op →
   `isOperationPending=true` (passes, even pre-delay); an unscheduled op → `false` (refused). The full
   mainnet-fork rehearsal was subsequently **done** — see "Single-round folding mechanism" below (the then-10-op
   fold, 2026-06-17; now 8-op/2-grant per decision #9), and the staged-v6.1 variant (migrating to the v6.1 vkeys + gateway,
   `check-sp1-verifier` green). The testnet rehearsal can no longer run — its JSON is post-upgrade.
8. **ICS27GMP go/no-go — GO, accepted as deployed-but-inert (2026-06-18).** The v3 bootstrap deploys a
   greenfield `ICS27GMP` message-passing app + `ICS27Account` beacon (`script/DeployV3AccessManager.sol`
   lines 40-46 / 91-104) and registers it on the live ICS26Router (step 8 `addIBCApp`, decision #5);
   `VerifyDeployment` hard-reverts until it is registered, so it is not optional and is a genuine **third
   in-scope change** alongside the v2→v3 core and the SP1 v6.1 migration. It is **net-new on-chain surface**,
   but **inert without a counterparty channel**: `ICS27GMP`'s packet callbacks are `onlyRouter` + inbound-only,
   so with nothing wired to `gmpport` no packets route and no accounts are created. Reviewed sound; the
   net-new message-passing surface is **accepted** on that basis. The real **2-of-5 `addIBCApp` Safe CALL**
   is now exercised on a mainnet fork by the timelock rehearsal (2026-06-18): `execTransaction` from the
   customizer Safe `0x4b46ea82…` (threshold 2) lands, `getIBCApp(gmpport)` == the ICS27 proxy, and
   `VerifyDeployment` passes — replacing the prior impersonated single-sender broadcast.
9. **RATE_LIMITER re-grant — `0x64259f72…` DROPPED (decided 2026-06-18).** The live v2 `RATE_LIMITER_ROLE`
   set is `0x4b46ea82…` + `0x64259f72…` on both the `cosmoshub-0` and `ledger-mainnet-1` escrows. In v3 only
   **`0x4b46ea82…`** (the 2-of-5 customizer Safe) is re-granted; **`0x64259f72…` is intentionally NOT
   re-granted** and loses rate-limiter access. Effect on the atomic bundle: **2** rate-limiter grants (not 4)
   → an **8-sub-call** MultiSend (`signer-verify.sh --expect-subcalls 8`). `1.json` now
   `rateLimiters=[0x4b46ea82…]`. **CAUTION:** `discover-v2-roles.py` does **not** reconcile rate-limiters
   against the JSON (RATE_LIMITER has no JSON key in its reconcile loop) — it just **lists the live v2
   holders** (`0x4b46ea82…` **and** `0x64259f72…`) as "to re-grant" and exits 0. So it will neither fail nor
   warn here: the operator must consciously re-grant **only** `0x4b46ea82…` and **skip** `0x64259f72…`.
   **Dress rehearsal re-run (2026-06-18):** the exact 8-op bundle executed on a mainnet fork — `status 0x1`,
   **523,273 gas**, the recipe `safeTxHash` matched the Safe's on-chain `getTransactionHash`, both folded
   grants landed (`setTargetFunctionRole` + `grantRole`), and the 2-of-5 `addIBCApp` + `VerifyDeployment`
   passed (`RL_GRANTS="cosmoshub-0:0x4b46ea82…,ledger-mainnet-1:0x4b46ea82…"`, `SHADOW_FORK_PRESERVE_DEPLOYMENT=1`
   against the pre-Phase-A JSON, since the live JSON is now post-deploy).

| Thing | Address / value |
| --- | --- |
| AccessManager | **not deployed** (`0x000…0`) — role testing is **post-cutover only** |
| Governance Safe | `0x7B96CD54aA750EF83ca90eA487e0bA321707559a` — **4-of-7** (7 hardware owners) |
| TimelockController (ADMIN) | `0xb3999B2D30dD8c9faEcE5A8a503fAe42b8b1b614` — delay **259 200 s = 72 h**; Safe holds PROPOSER/EXECUTOR/CANCELLER; the timelock self-administers `DEFAULT_ADMIN` (no stray external admin) |
| ICS26Router proxy | `0x3aF134307D5Ee90faa2ba9Cdba14ba66414CF1A7` |
| ICS20Transfer proxy | `0xa348CfE719B63151F228e3C30EB424BA5a983012` |
| ID + ERC20 customizer | `0x4b46ea82D80825CA5640301f47C035942e6D9A46` |
| Canonical MultiSendCallOnly | `0x9641d764fc13c8B624c04430C7356C1C7C8102e2` |

Role-holder sets (from `deployments/mainnet/1.json`, matching on-chain): **4 relayers, 5 pausers,
unpauser = the Safe itself, 2 delegate senders, 1 id/erc20 customizer (`0x4b46ea82…`), 3 light
clients.**

#### Trust-root verification (on-chain, 2026-06-17 — reproduce with `ETH_RPC=<rpc> FROM_BLOCK=22188631 scripts/verify-roots.sh mainnet 1`)

These roots are trusted by the whole upgrade and were never asserted by tooling until now; `verify-roots.sh`
checked them (read-only) and returned **17/17**. **Timelock deploy block = `22188631`** (creation tx
`0x95d263cfe749d98ba9baa5866641de36797033906b5440b087d1d42ceab03c23`) — used as `FROM_BLOCK` for the
`DEFAULT_ADMIN` event reconstruction (result: **no stray admin; only the timelock holds it**). The
client-N escrow probe (`client-0..19`) found **no escrow beyond the 3 known** — so the
`rateLimitedEscrows` / discovery scope is the complete set (cross-checked: JSON = 3, prod relayer config
relays only `cosmoshub-0` + `ledger-mainnet-1`, `client-4` dropped).

| Root | Check | Result |
| --- | --- | --- |
| Timelock `0xb3999B2D…` | `getMinDelay()` | `259200` ✓ |
| | `hasRole(EXECUTOR_ROLE, address(0))` (open-executor DoS) | `false` ✓ |
| | PROPOSER / EXECUTOR / CANCELLER = the Safe | `true` ✓ |
| | `DEFAULT_ADMIN`: timelock self-admin `true`, Safe `false`; **no stray admin** (events from `22188631`) | ✓ |
| Governance Safe `0x7B96CD54…` | `getThreshold()` = 4, `getOwners()` count = 7 | ✓ |
| SP1 gateway `0x397A5f7f…` | route for the v6.1 selector `0x4388a21c` → `0xb69f2584…`, `frozen == false` | ✓ |
| Escrows | `getEscrow()` = `cosmoshub-0 0x0fA75C2c…`, `ledger-mainnet-1 0xC76944B0…`, `client-4 0x3f36Fd49…`; **no stray escrow** in `client-0..19` | ✓ |

Re-run immediately before scheduling (roles can change).

### Light clients & escrows (mainnet)

| Client | Counterparty | Escrow | Current verifier (pre-v6.1) |
| --- | --- | --- | --- |
| `cosmoshub-0` | `08-wasm-1369` | `0x0fA75C2c49d7dB7ed62c5Fb70bF78ba614aE6A89` | `0x2bB76Cb5EaB856ffb548320509266c5BfeD46f82` (direct v5.0.0) |
| `ledger-mainnet-1` | `08-wasm-0` | `0xC76944B0159D7Dd5c4cF6936b0f45E8de9b34092` | `0xbB3FeAbf2eAE13fcC97451877a2678895D8ffaA5` (direct v5.0.0) |
| `client-4` *(DROPPED)* | `08-wasm-301` | `0x3f36Fd49251475aC17bB680D56F412Bf81Aa5778` | `0x397A5f7f3dBd538f23DE225B51f532c34448dA9B` (gateway, already set) |

> **The committed `deployments/mainnet/1.json` is still in PRE-v6.1 state** — all three clients
> carry the *current* on-chain vkeys (`updateClient=0x009443d9…`), not the v6.1 vkeys (`0x00d38536…`).
> Step 5 (regenerate trusted state, write v6.1 vkeys, repoint `.verifier` to the gateway) **must still
> be done for mainnet** — but only for the two migrated clients (`client-4` dropped; see decision #2).

The SP1 v6.1 Groth16 verifier infrastructure on mainnet is the **same gateway/real-verifier pair
as testnet** (gateway `0x397A5f7f…` → real `0xb69f2584…`, selector `0x4388a21c`); the broken
`0xf0f70E15…` verifier is testnet-only and absent on mainnet.

### Mainnet pre-cutover grant set & token audit

> **Authoritative copy.** The procedure (`../../upgrade-v2-to-v3.md` steps 7/10) and
> `../../post-upgrade-role-testing.md` link here instead of restating these holders, to avoid
> drift. **Re-run `scripts/discover-v2-roles.py mainnet 1` immediately before cutover** — holders
> can change.

The bootstrap only grants what's in `deployments/mainnet/1.json` `accessManagerRoles`. The live v2
role model is richer; reconciled via `discover-v2-roles.py` (2026-06-16, pre-upgrade):

| v2 role(s) | live holders | v3 disposition |
| --- | --- | --- |
| RELAYER, PAUSER, UNPAUSER, DELEGATE_SENDER, PORT+CLIENT_ID_CUSTOMIZER, ERC20_CUSTOMIZER | **match the JSON exactly** | auto-granted by the bootstrap from the JSON — no action |
| **RATE_LIMITER** | live v2: `0x4b46ea82…` and `0x64259f72…` on **both** the `cosmoshub-0` (escrow `0x0fA75C2c…`) and `ledger-mainnet-1` (escrow `0xC76944B0…`) escrows; **none** on `client-4` (escrow `0x3f36Fd49…`) | **Re-grant `0x4b46ea82…` ONLY** on both escrows (**2 grants**, folded into the step-7 execute). **`0x64259f72…` intentionally DROPPED** (2026-06-18, decision #9) — loses rate-limiter access in v3. Pre-staged **top-level** in `1.json` (`rateLimiters=[0x4b46ea82…]`/`rateLimitedEscrows`) for the *validator* — kept out of `.accessManagerRoles`, which the deploy rewrites. `discover-v2-roles.py` LISTS both as live v2 holders "to re-grant" (informational — it does NOT compare to the JSON or fail), so consciously re-grant **only** `0x4b46ea82…`. |
| TOKEN_OPERATOR (ICS20) | `0x4b46ea82…`, timelock | **no v3 role** — it managed who may relabel IBCERC20 metadata (`grant/revokeMetadataCustomizerRole` → `setMetadata`). v3 removes mutable IBCERC20 metadata entirely; the replacement is `setCustomERC20` under **`ERC20_CUSTOMIZER`** (migrated), so `0x4b46ea82…` keeps the comparable power. Only the *in-place relabel of an auto-token* is gone. |
| LIGHT_CLIENT_MIGRATOR (per-client) | deployer + timelock | **no v3 role** (`migrateClient` is ADMIN-gated) — dropped; governance-held only |
| DEFAULT_ADMIN (ICS26 + ICS20) | timelock `0xb3999B2D…` | becomes v3 `ADMIN` (the timelock) |

**Takeaway:** the 6 bootstrap-migrated roles are complete; the **only grant not covered by the
JSON is `RATE_LIMITER`** (2 accounts × 2 escrows). The token-operator and per-client-migrator
capabilities are intentionally gone in v3 (token-operator's intent is covered by `setCustomERC20` /
`ERC20_CUSTOMIZER`; per-client migration is now ADMIN-gated) — confirm that's acceptable.

**IBCERC20 metadata (informational — no action).** Metadata customization *was* used in v2: on
mainnet, 5 of the 13 auto-deployed beacon tokens carry custom name/symbol/decimals
(`cosmoshub-0/uatom` → "Cosmos Hub ATOM", plus SEDA, Nillion, and two hub-testnet ATOMs). It
survives the v2→v3 IBCERC20 beacon upgrade unchanged — identical storage layout (same
`IBCERC20_STORAGE_SLOT` + struct) and the per-denom proxies are never re-initialized — so v3 just
freezes it (no more `setMetadata`). Enumeration caveat: `setCustomERC20` (the `ERC20_CUSTOMIZER`
path) registers external tokens with **no event**, so the registered-denom set is larger than the
`IBCERC20ContractCreated` logs imply — on mainnet (2026-06-16) it's **13 beacon tokens + 6 external
= 19**. A couple of the externals are plain mintable tokens (no `ics20()` getter) whose mint/burn
is keyed to the unchanged ICS20 proxy address, so the upgrade doesn't touch them.

---

## Notable findings

### Rate-limiter re-grant was a NO-OP on testnet — proven, not assumed

In v3, escrow `setRateLimit` defaults to `ADMIN_ROLE` after the beacon upgrade (upstream TODO
#559 — it is not wired to `RATE_LIMITER` at deploy), so every v2 `RATE_LIMITER_ROLE` holder loses
access unless re-granted. The escrows are plain (non-enumerable) `AccessControl`, so there is no
member list to read — we reconstructed holders from `RoleGranted`/`RoleRevoked` history. On testnet
there were **no** `RATE_LIMITER_ROLE` holders, so step 10 had nothing to re-grant. **Mainnet
differs** (non-empty snapshot — see above).

### Single-round folding mechanism for mainnet

A second schedule→delay→execute window is impractical on mainnet (72 h each). The
`EXTRA_TIMELOCK_OPS` path lets the rate-limiter re-grant (step 10) and any role grants (step 12) be
**scheduled in the step-6 window** and folded into the **same atomic step-7 MultiSend**. Each
folded `execute(...)` blob must byte-match its scheduled op (identical prompt inputs) and that
schedule must already have executed, or the whole atomic bundle reverts.

**Rehearsed on a mainnet fork (2026-06-17) — the then-10-op fold (SUPERSEDED by decision #9 → now 8-op/2-grant):** 4 core + 2 migrations
(`cosmoshub-0`, `ledger-mainnet-1`) + **4 rate-limiter grants** (`0x4b46ea82…` and `0x64259f72…` on
each of the two escrows), driven via
`RL_GRANTS="cosmoshub-0:0x4b46ea82…,cosmoshub-0:0x64259f72…,ledger-mainnet-1:0x4b46ea82…,ledger-mainnet-1:0x64259f72…"`.
All 4 grants scheduled, folded via `EXTRA_TIMELOCK_OPS`, the bundle's `safeTxHash` matched the Safe's
on-chain `getTransactionHash`, and the atomic `execTransaction` executed (`status 0x1`) for
**≈ 616,104 gas** (block limit ≈ 60M, so ~1 %). Post-execute: all 4 escrow `setTargetFunctionRole` +
holder `grantRole` landed. (The earlier single-grant `REHEARSE_RATE_LIMITER_GRANT=1` rehearsal is the
1-op fallback form.) **2026-06-18: `0x64259f72…` dropped (decision #9) → the live bundle is now 8-op/2-grant. Re-rehearsed on a mainnet fork the same day: the 8-op bundle executed `status 0x1` for ≈ 523,273 gas, safeTxHash matched on-chain, both folded grants landed, `addIBCApp` (2-of-5 Safe) + `VerifyDeployment` passed.**

---

## Mainnet execution record (chain `1`)

**COMPLETE — cutover executed and finalized.** Phase A (deploy) + Phase B (schedule, 2026-06-20) +
Phase C (atomic execute, **2026-06-25 14:58:11 UTC**) + Phase D (finalize, **2026-06-25 → 2026-06-26**)
all done. The 72 h timelock clock started 2026-06-20 12:21:59 UTC (ready 2026-06-23 12:21:59 UTC, unix
`1782217319`); the execute landed once the 4-of-7 was collected, ~2.1 days into the ready window.
Post-cutover `verify-deployment` + `check-sp1-verifier` + `validate-v3-roles.py mainnet 1` (**35 passed /
0 failed**) all green; live cosmoshub-0 packets relaying against the new v6.1 client.

### Phase A — deploy (2026-06-18, complete)

- [x] **v3 AccessManager + ICS27GMP deployed (2026-06-18)** via `deploy-v3-access-manager` (Ledger deployer
      `0x5622612bF6b4aAadd58Ee7C4680c3207caA6b442`, idx 1). All 6 contracts Etherscan-verified.
      - AccessManager: `0x3fa3f45acE1645614c80679AeEcE0A82A93c77Ec`
      - ICS27GMP proxy: `0xbebd14A66052d7dc6BDc05e7328E4fEC0a9e3B0e`
      - ICS27GMP implementation: `0x75688B39248a0a70549dA82e00FF722EcA91b1c3`
      - ICS27GMP account implementation: `0x29939DF86144f13FF030c0DCDF2d0D5E362Cf10d`
      - Deploy tx (`V3AccessManagerBootstrap` CREATE — deploys all of the above in its constructor): `0xb210640a56338eabeab516632731748b7f6501f6c6553a1e4c2401c1fb0db034`
      - On-chain checks: timelock `ADMIN_ROLE(0)`=true; deployer admin=false (bootstrap renounced); `ICS27GMP.authority()`==AccessManager.
- [x] **4 v3 implementations deployed (2026-06-18, blocks 25343331–25343387)** via `deploy-implementation` ×4
      (Ledger `0x5622612b…`). Cross-checked vs broadcast + on-chain code; all distinct from the live v2 impls;
      written to `1.json`.
      - ICS26Router impl: `0x17fa3A98D0239a399927C7c3CCdE142e08Deb7B5` (tx `0xf750380446b2061ee6b5a6b89b448177c824570972faa11c306b6829905bfb79`)
      - ICS20Transfer impl: `0x1ae0b1071a99166248a78e55547b36d44F5B0790` (tx `0x1797ff7524edbfaa40085272f45e0f5043f45becb0ae6d05a4724a3762f0fc0b`)
      - Escrow impl: `0x5474048d4305f5e588df148380535e4e4df590ad` (tx `0xfba1ae136acb43e8d468a628131e00f8ea0c5403322eb21bd6e347b92a96bc43`)
      - IBCERC20 impl: `0x0884C7752e8C95A37140A7a07b1fA9b83fD70719` (tx `0xd6365490e98bc0f8d299d2c4469b045cec9e10bd8c09a9397551b24beadf57fe`)
- [x] **SP1 v6.1 clients deployed (2026-06-18)** — tag **`sp1-programs-v2.0.0`** (`--version v2.0.0`, at the
      rc.2 commit). vkeys written + assertion-verified == validated set (`updateClient 0x00d38536…`,
      `membership 0x000bd8ec…`, `ucAndMembership 0x009fe47d…`, `misbehaviour 0x0010008d…`). Fresh trusted
      state: `cosmoshub-0` rev4/h31633794, `ledger-mainnet-1` rev1/h8325355. New `SP1ICS07Tendermint` (old→new):
      - `cosmoshub-0`: `0x2e4600f0312D791251821d5b6195c0D8578fa25D` → **`0x4bB8A05D5b40dF7a3B97770E1943461B681B62E9`** (tx `0xffab839b62b878744e1f3a2b719fc4a9af798fdfab9dcb14e5fb526672f1ec6f`)
      - `ledger-mainnet-1`: `0x279ad6E89DECDf0eBD20050FdD082EE1d20d3E0f` → **`0xD8b2576B0640EfdDe2015Fdc0DD5064f8c067Bf0`** (tx `0xdcc6f941806e801ce24605461faeead39af4b443ce73ce145f17def396978189`)
      - On-chain verified per client: `getClientState()` + `getConsensusStateHash()` == JSON; all 4 vkeys == v6.1; `VERIFIER()` == gateway.
      - NOTE: `ledger-mainnet-1` trusted state generated via a **local proxy-backed proof-api** (prod proof-api down + the Lombard empty-User-Agent 403, fixed in solidity-ibc-eureka **PR #1052**). The prod relayer image for step 8a now needs **both** ibc-manifests#91 (/dev/shm) **and** #1052 (User-Agent).
- [x] `client-4` scope decision — **DROPPED** (not relayed in prod; decided 2026-06-16)

### Phase B — schedule (2026-06-20, COMPLETE)

- [x] **All 8 timelock ops scheduled — gov-Safe nonces 18–25, bulk-executed in ONE Ethereum tx.**
      tx `0x19c6cd2ae43cdf494aba9ddf077000e7dd5b04abc7bcabfbe6615345fafeb109` (block `25358768`, mined
      **2026-06-20 12:21:59 UTC**) via canonical MultiSendCallOnly `0x9641d764fc13c8B624c04430C7356C1C7C8102e2`;
      gas relayed from non-owner `0x64259f722A0868CCf58A935C61A292cEA9dF035a` (permissionless once the
      4-of-7 sigs were collected — harmless: the collected signatures authorize each Safe tx). Pre-exec:
      all 8 at **4/4** confirmations, every `safeTxHash` matched the coordinator table, all 32 sigs from
      current owners. Post-exec on-chain: **all 8 timelock ops registered pending** (delay `259200 s`); Safe
      nonce advanced **18 → 26**; tx-service marks 18–25 `isExecuted=true`. The 8 op ids:

      | # | op id | action | target |
      | --- | --- | --- | --- |
      | 1 | `0x26caf8d7…` | ICS20Transfer upgrade (predecessor `0`) | ICS20Transfer `0xa348CfE7…` |
      | 2 | `0x0ee8f2be…` | ICS26Router upgrade (predecessor = op-1 `0x26caf8d7…`, enforces ICS20-before-ICS26) | ICS26Router `0x3aF13430…` |
      | 3 | `0x3ab60d42…` | Escrow beacon upgrade | ICS20Transfer |
      | 4 | `0x872db995…` | IBCERC20 beacon upgrade | ICS20Transfer |
      | 5 | `0x13dde19a…` | migrate `cosmoshub-0` | ICS26Router |
      | 6 | `0xa8e54e18…` | migrate `ledger-mainnet-1` | ICS26Router |
      | 7 | `0xbe6a6ec2…` | RATE_LIMITER grant `cosmoshub-0` | AccessManager `0x3fa3f45a…` |
      | 8 | `0x990e223d…` | RATE_LIMITER grant `ledger-mainnet-1` | AccessManager |
- [x] **72 h clock started.** All 8 ops `ready_at` = **2026-06-23 12:21:59 UTC** (unix `1782217319`) —
      the earliest Phase-C execute.
- [x] **Execute authority enumerated (read-only, full history).** TimelockController `0xb3999B2D…`
      (deployed 2025-04-03, block `22188631`): enumerated every `RoleGranted(EXECUTOR_ROLE)` over its
      entire history — **exactly one grant, ever**: constructor → gov Safe `0x7B96CD54…`; no other address
      at any point. `EXECUTOR_ROLE` is **not** open (`hasRole(EXECUTOR, address(0)) = false`);
      `DEFAULT_ADMIN_ROLE` is held by the timelock itself (no Safe/EOA admin). The Safe also exclusively
      holds PROPOSER + CANCELLER. ⇒ a "ready" op is executable **only** by the gov Safe, which can act only
      via a 4-of-7-signed tx.

### Phase C — atomic execute (EXECUTED 2026-06-25)

- [x] **Atomic execute bundle built + verified — gov-Safe nonce 26.** `to` = MultiSendCallOnly
      `0x9641d764fc13c8B624c04430C7356C1C7C8102e2`, `operation = 1` (DELEGATECALL), **8**
      `TimelockController.execute(...)` sub-calls (4 upgrades + 2 migrations + 2 RL grants), each `op=CALL`
      to the timelock, selector `0x134008d3`. `safeTxHash`
      **`0xe999dee7ac3a0a003383efb2fa45c9b8105ef8c21ab8322dcd9371173f0a637a`** (== gov Safe on-chain
      `getTransactionHash` for nonce 26). Built read-only:
      `EXTRA_TIMELOCK_OPS='<2 RL-grant execute blobs>' just execute-v3-upgrade-multisend 26 cosmoshub-0 ledger-mainnet-1`
      (`FOUNDRY_ETH_RPC_URL` must be set; the packer's `assert_pending` re-validates each op; `REQUIRE_READY=1`
      only at the real execute). **The proposal can be put up and 4-of-7 collected NOW during the window**;
      on-chain execute only at/after the ready time — an early execute reverts harmlessly and, with
      `safeTxGas=0`, does **not** consume nonce 26.
- [x] **Executed on-chain 2026-06-25 14:58:11 UTC** (block `25395388`) — `execTransaction` for nonce 26
      submitted via the Safe UI by gov-Safe owner `0x64ACC525DC35ebca8345fDF6e2A70D012a17740A`: tx
      **`0x65db3718cedeb62596c98efe941af8317bcd11070532513d3993920a23c3f057`**, **status 1, gas 527,847**.
      Gov Safe nonce **26 → 27**; all 8 timelock ops `isOperationDone=true`. Post-state confirmed on-chain:
      ICS20Transfer proxy → impl `0x1ae0b107…`, ICS26Router proxy → impl `0x17fa3A98…`, Escrow beacon impl
      `0x5474048d…`, IBCERC20 beacon impl `0x0884C775…`, `getClient(cosmoshub-0)=0x4bB8A05D…`,
      `getClient(ledger-mainnet-1)=0xD8b2576B…`, RATE_LIMITER(5) wired on both escrows (holder `0x4b46ea82…`).

#### Phase C current-state fork simulation — PASSED (2026-06-20, new this session)

Prior shadow rehearsals validated the *mechanism* but always deployed fresh impls and scheduled the ops
themselves — none ran against the **actual current state**. This session forked mainnet at the current
block (~`25359497`; the 8 real ops pending), warped **+72 h** (all 8 `isOperationReady`), and executed the
**exact nonce-26 bundle** through the real gov Safe via `execTransaction` → **status 1, gas 523285**
(`safeTxGas=0`, so all 8 inner `timelock.execute` ran the **real deployed impls** without reverting).
Post-state: ICS20Transfer proxy → new impl `0x1ae0b1071a99166248a78e55547b36d44F5B0790`; ICS26Router proxy
→ new impl `0x17fa3A98D0239a399927C7c3CCdE142e08Deb7B5`; rate-limiter wired on **both** escrows (role 5),
holder `0x4b46ea82D80825CA5640301f47C035942e6D9A46`.

**Phase D dress rehearsal on the same fork:** `addIBCApp("gmpport", 0xbebd14A66052d7dc6BDc05e7328E4fEC0a9e3B0e)`
via the real 2-of-5 customizer Safe `0x4b46ea82…` landed; escrow `initializeV2()` on **all 3** escrows
(`cosmoshub-0` `0x0fA75C2c…`, `ledger-mainnet-1` `0xC76944B0…`, `client-4` `0x3f36Fd49…`);
`VerifyDeployment` **passed**.

### Phase D — post-cutover (COMPLETE, 2026-06-25 → 2026-06-26)

> Executed order: **9** escrow init → **8a** relayer roll → **8** register ICS27GMP → **11/13** verify.

- [x] **9 — Escrow `initializeV2()` on all 3 escrows (2026-06-25 15:40–15:41 UTC; permissionless, from
      `0x64259f72…`; each status 1).** Post: `_initialized` 1 → 2, `authority()` → AccessManager `0x3fa3f45a…`.
      - `cosmoshub-0` `0x0fA75C2c…`: tx `0x774d7b4a78d7916c1983a9ea9795f7e27ab8c59a4382cfd74ded2c9951d42a3e` (block 25395600)
      - `ledger-mainnet-1` `0xC76944B0…`: tx `0x6d698bbce901acef28ea72709c1b116cd878f2fc89e6b5bc8a8e4e77a54b4ff6` (block 25395602)
      - `client-4` `0x3f36Fd49…`: tx `0x452ed0a860c942ea4cc3256b5fd36c5bd1010138b190cf6b7f7a4d5861581bdb` (block 25395604)
- [x] **8a — Relayer/prover rolled to the new build (2026-06-25).** Image
      `ghcr.io/cosmos/proof-api:10a6a10` (sp1-programs v2.0.0 / v6.1; carries ibc-manifests#91 `/dev/shm` +
      solidity-ibc-eureka#1052 User-Agent). **Verified end-to-end, not just by the vkey check:** an inbound
      `cosmoshub-0` `recvPacket` (tx `0x09574cb6a9c9f04ec3292ddd7f10f704d914f707993cb1eaa1eec1f3b1d6f0c2`,
      block 25395706, status 1) ran `SP1ICS07Tendermint.verifyMembership` on the new client `0x4bB8A05D…`
      with the v6.1 ucAndMembership vkey `0x009fe47d…`, routed through the gateway to the real v6.1 verifier
      `0xb69f2584…`, and landed a `uatom` transfer with a success ack. Zero `/dev/shm`/simulation failures in
      the rolled pod's logs.
- [x] **8 — Registered ICS27GMP (2026-06-26 08:51:59 UTC).** `addIBCApp("gmpport",
      0xbebd14A66052d7dc6BDc05e7328E4fEC0a9e3B0e)` as a 2-of-5 Safe CALL from the customizer `0x4b46ea82…`
      (nonce 15; signers `0x5622612b…` + `0x7B5Cc5B7…`): `execTransaction` tx
      `0xd53791b683b284f6a0a7f394cdb6519c379b3e1e00f142f4af382f3dd8ea2245`. Post: `getIBCApp("gmpport") ==
      0xbebd14A6…`; customizer Safe nonce 15 → 16. Proposed with `scripts/safe-propose.sh --safe …` (new
      `--safe` override, commit `fbe7ea1`; the signer is a full owner so the proposal also cast the 1st of 2 sigs).
- [x] **Rate-limiter re-grant (folded into nonce 26).** Final set: `cosmoshub-0:0x4b46ea82…`,
      `ledger-mainnet-1:0x4b46ea82…` (`0x64259f72…` dropped, decision #9). Confirmed post-execute:
      `setRateLimit` → RATE_LIMITER(5) on both escrows; `0x4b46ea82…` holds role 5 (delay 0). **No caps set
      (UNLIMITED), matching v2:** all 105 (escrow,token) pairs that ever moved through the 3 escrows read
      `getRateLimit == 0` at the pre-upgrade block — v2 had the rate-limit feature (old impl `0xf24A818d` has
      the selectors) but never set a cap, so the upgrade changed nothing; `initializeV2` does not clear
      `_rateLimits`. Setting any cap now would be new policy.
- [x] **11 / 13 — Post-cutover validation green (2026-06-26).** `just verify-deployment` **passes all
      sections** (ICS26 / ICS20 / ICS27GMP / known escrows / all 3 SP1 clients); `just check-sp1-verifier`
      **passes** (all clients route v6.1.0 → `0xb69f2584…`); `scripts/validate-v3-roles.py mainnet 1`
      **35 passed / 0 failed**.

### Execute-round signer materials (2026-06-20)

On `operations/2026-06-18-upgrade-v2-to-v3`:
- **`SIGNER-CHECKLIST-EXECUTE.md`** — signers validate nonce 26 with
  `bash scripts/signer-verify.sh 26 --expect-subcalls 8` → PASS, then **sign only** (the coordinator
  executes after the delay).
- **`COORDINATOR-HASH-TABLE.md`** — gained the **nonce-26 row** + a **Phase-C section**.
