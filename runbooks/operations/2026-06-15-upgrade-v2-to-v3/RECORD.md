# Operation record — solidity-ibc-eureka v2 → v3 upgrade + SP1 v6.1 migration

Durable record of the v2→v3 core upgrade (per-contract `AccessControl` → shared OZ
`AccessManager`) and the SP1 light-client v6.1 migration.

- **Procedure (authoritative):** [`../../upgrade-v2-to-v3.md`](../../upgrade-v2-to-v3.md) — do **not**
  follow a copy; that file is the single source of truth and is kept current.
- **Role validation / testing:** [`../../post-upgrade-role-testing.md`](../../post-upgrade-role-testing.md).
- **Mainnet cutover runsheet:** [`CUTOVER-RUNSHEET.md`](CUTOVER-RUNSHEET.md) — pre-filled, ordered
  execution sheet for the 72 h window (mainnet values + decisions inlined).
- **Status:** executed end-to-end on **Sepolia testnet (chain `11155111`)**; **mainnet (chain `1`) not yet executed.**
- **Branch:** `operations/2026-06-15-upgrade-v2-to-v3`.

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
   `isOperationPending=true` (passes, even pre-delay); an unscheduled op → `false` (refused). Still
   wants a full mainnet-fork `shadow-v2-to-v3-mainnet-timelock` rehearsal as part of cutover prep
   (the testnet rehearsal can't run now — its JSON is post-upgrade).

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

#### Trust-root verification (on-chain, 2026-06-17 — reproduce with `scripts/verify-roots.sh mainnet 1`)

These three roots are trusted by the whole upgrade and were never asserted by tooling until now;
`verify-roots.sh` checked them (read-only) and returned **11/11**:

| Root | Check | Result |
| --- | --- | --- |
| Timelock `0xb3999B2D…` | `getMinDelay()` | `259200` ✓ |
| | `hasRole(EXECUTOR_ROLE, address(0))` (open-executor DoS) | `false` ✓ |
| | PROPOSER / EXECUTOR / CANCELLER = the Safe | `true` ✓ |
| | `DEFAULT_ADMIN`: timelock self-admin `true`, Safe `false` | ✓ (stray-admin event scan pending `FROM_BLOCK` = timelock deploy block) |
| Governance Safe `0x7B96CD54…` | `getThreshold()` = 4, `getOwners()` count = 7 | ✓ |
| SP1 gateway `0x397A5f7f…` | route for the v6.1 selector `0x4388a21c` → `0xb69f2584…`, `frozen == false` | ✓ |
| Escrows | on-chain `getEscrow()` = `cosmoshub-0 0x0fA75C2c…`, `ledger-mainnet-1 0xC76944B0…`, `client-4 0x3f36Fd49…` | match this record |

Re-run immediately before scheduling (roles can change). Open: confirm `FROM_BLOCK` (the timelock's
deploy block) for the stray-`DEFAULT_ADMIN` event reconstruction.

### Light clients & escrows (mainnet)

| Client | Counterparty | Escrow | Current verifier (pre-v6.1) |
| --- | --- | --- | --- |
| `cosmoshub-0` | `08-wasm-1369` | `0x0fA75C2c49d7dB7ed62c5Fb70bF78ba614aE6A89` | `0x2bB76Cb5EaB856ffb548320509266c5BfeD46f82` (direct v5.0.0) |
| `ledger-mainnet-1` | `08-wasm-0` | `0xC76944B0159D7Dd5c4cF6936b0f45E8de9b34092` | `0xbB3FeAbf2eAE13fcC97451877a2678895D8ffaA5` (direct v5.0.0) |
| `client-4` *(DROPPED)* | `08-wasm-301` | `0x3f36Fd49251475aC17bB680D56F412Bf81Aa5778` | `0x397A5f7f3dBd538f23DE225B51f532c34448dA9B` (gateway, already set) |

> **The committed `deployments/mainnet/1.json` is still in PRE-v6.1 state** — all three clients
> carry the *current* on-chain vkeys (`updateClient=0x009443d9…`, etc.), not the v6.1 vkeys
> (`0x00d38536…`) that testnet migrated to. Step 5 of the procedure (regenerate trusted state,
> write v6.1 vkeys, repoint `.verifier` to the gateway for the two clients still on direct v5
> verifiers) **must still be done for mainnet** — but only for the two migrated clients. **`client-4`
> is DROPPED** (decided 2026-06-16; see "Mainnet decisions locked"): its chainId is the generic
> `"provider"`, its `latestHeight` is frozen, and the prod relayer config has no module for it, so
> it is not a live relayed channel. **The migrate set is `cosmoshub-0` + `ledger-mainnet-1` only.**

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
| **RATE_LIMITER** | `0x4b46ea82…` and `0x64259f72…` on **both** the `cosmoshub-0` (escrow `0x0fA75C2c…`) and `ledger-mainnet-1` (escrow `0xC76944B0…`) escrows; **none** on `client-4` (escrow `0x3f36Fd49…`) | **not in the JSON → re-grant** (procedure step 10 / fold into the step-7 atomic execute). **Not a no-op on mainnet** (it was on testnet). Confirmed on-chain via `hasRole` (`RATE_LIMITER_ROLE = keccak256("RATE_LIMITER_ROLE")`). |
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
schedule must already have executed, or the whole atomic bundle reverts. Rehearsed on-fork via
`REHEARSE_RATE_LIMITER_GRANT=1` (green).

---

## Mainnet execution record (chain `1`) — to fill at cutover

_Pending. Populate during/after the mainnet run, mirroring the testnet record above:_

- [ ] v3 AccessManager + ICS27GMP deploy addresses & tx hashes
- [ ] 4 v3 implementation addresses & tx hashes
- [ ] SP1 v6.1 client deploy addresses & tx hashes (per migrated client); final v6.1 vkeys & the
      `sp1-programs` tag actually used (decided 2026-06-16: final `v2.0.0` cut at the **same commit
      as `v2.0.0-rc.2`** → vkeys byte-identical; record which tag string was passed)
- [x] `client-4` scope decision — **DROPPED** (not relayed in prod; decided 2026-06-16)
- [ ] Safe schedule nonces and the atomic `execTransaction` hash
- [ ] ICS27GMP registration tx; escrow `initializeV2()` txs
- [ ] Rate-limiter re-grant (folded) — final `(client_id, holder)` set granted
- [ ] Post-cutover: `verify-deployment`, `check-sp1-verifier`, `validate-v3-roles.py mainnet 1`
      (expect **0 failed**; ~33 passed with 3 escrows) results
- [ ] Relaying halt/resume owners and times
