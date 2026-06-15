# solidity-ibc-eureka v2 → v3 upgrade + SP1 v6.1 migration — testnet execution record

> Temporary working note (to be removed before merge). Documents the full v2→v3 upgrade
> and SP1 light-client v6.1 migration as executed on **Sepolia testnet (chain `11155111`)**,
> on branch `operations/2026-06-15-upgrade-v2-to-v3`. Everything below is real, on-chain.

## Overview & goal

Two coupled changes, executed in a single timelock/operation window:

1. **v2 → v3 core upgrade.** Move contract authorization from per-contract OpenZeppelin
   `AccessControl` to a single shared OpenZeppelin `AccessManager`. Upgrade the four core
   contracts (`ICS20Transfer`, `ICS26Router`, `Escrow` beacon, `IBCERC20` beacon) and hand
   each to the shared manager.
2. **SP1 v6.1 light-client migration.** Migrate the two Tendermint light clients
   (`hub-testnet-0`, `ledger-testnet-1`) onto SP1 v6.1 programs: fresh trusted state, fresh
   v6.1 verification keys, and a verifier gateway that routes v6.1.0 proofs to the real
   (non-broken) SP1 verifier.

Both were cut over **atomically** so the chain never settled in a mixed v2/v3 state.

The full procedure lives in `runbooks/upgrade-v2-to-v3.md` (rewritten during this operation).

## Architecture change (v2 → v3)

### Authorization: per-contract AccessControl → shared AccessManager

- A v3 `AccessManager` (`0x56172716671657a4DF912d3665603C294DAaE10f`) becomes the single
  authority for `ICS26Router`, `ICS20Transfer`, and the new `ICS27GMP`.
- The AccessManager's `ADMIN_ROLE` is held by the existing `TimelockController`
  (`0x8948ca6bB5E2F50A235DB3eFf7c125188c6AD14b`) — i.e. all privileged config still flows
  through the timelock, proposed/executed by the Safe.
- Role holders (relayers, pausers/unpausers, delegate senders, id/erc20 customizers) are
  copied from `.accessManagerRoles.*` in the deployment JSON at AccessManager-deploy time.
  `.accessManagerRoles.*` is the source of truth from that point on.

### Mandatory upgrade order

`ICS20Transfer` → `ICS26Router` → `Escrow` beacon → `IBCERC20` beacon. Each
`ICS20Transfer`/`ICS26Router` `upgradeToAndCall` must carry `initializeV2(accessManager)`:
`ICS20Transfer.initializeV2` authenticates against v2 admin records still on `ICS26Router`,
and `ICS26Router.initializeV2` deletes them — so upgrading the router first makes the
transfer upgrade revert. This ordering is enforced on-chain by a timelock predecessor
(ICS20 before ICS26) inside the atomic batch.

### Escrows

After the `Escrow` beacon upgrade, every escrow proxy needs a one-time, permissionless
`Escrow.initializeV2()` to flip its authority to the AccessManager.

### SP1 v6.1

Light clients are standalone `SP1ICS07Tendermint` contracts — upgrading the core proxies
does not touch them. Each client needs a fresh deployment plus a timelocked
`ICS26Router.migrateClient(...)` (now AccessManager-controlled; the per-client migrator role
is gone). Done in the same timelock window as the core upgrade.

## Deployed addresses

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

Deployment record: `deployments/testnet/11155111.json`.

### Deploy transaction hashes (from `broadcast/*/11155111/run-latest.json` + history)

| Deploy | Tx hash |
| --- | --- |
| AccessManager (+ ICS27GMP) via `V3AccessManagerBootstrap` | `0x22f4f9cc08a567fafd6f5957f14b13ed3a228d1f781fc1df78e06f21c561bf23` |
| ICS20Transfer v3 impl | `0xb76fd7212948cc6de5e68c64559cbbf0b5da5f2e91afbfe142d28d7f2380cad0` |
| ICS26Router v3 impl | `0x78f4e9efeb81889c3e79f61c6815a0b4ae920c0a11cc2ace5037d0d3176e791a` |
| Escrow v3 beacon impl | `0xbd6518365af063a1384d40d5d4a08ba038476f7b26825cd53b6c44cd3ff4ac6d` |
| IBCERC20 v3 beacon impl | `0x1c94aff0671a08776e1824cde0a12d8847e596be64d1c262edd493226c14710f` |
| SP1 `hub-testnet-0` client deploy | `0x16c2646f928545988dfd2a143e09f4a521f83fbffe183fa062037f5043cdef3d` |
| SP1 `ledger-testnet-1` client deploy | `0x32893715d48aebc427064d8043f6871039b9ee77595dc468638b330d2fe94fd6` |

All deploys broadcast from the deployer EOA `0x15C1e4924e4f8cE261B5D5cfEB9B96c4bF035DF9`.

## Execution timeline

The Safe is a 1-of-2 (`0x85CF…5882`, owner `0x15C1…5DF9`). Schedules and the atomic cutover
were submitted via direct `cast` `execTransaction` calls with the owner key; the ICS27
registration and escrow inits were direct `cast send`.

1. **Deploy v3 AccessManager + ICS27GMP** (`DeployV3AccessManager`). AccessManager admin =
   TimelockController; target function roles wired for the two existing proxies + the new
   ICS27GMP proxy; role holders copied from the JSON.
2. **Deploy the 4 v3 implementations** (`DeployImplementation`, once per contract).
3. **SP1 v6.1 prep + deploy**, per client: fresh trusted state from the proof-api; v6.1
   vkeys computed from the released `sp1-programs` ELFs; `.verifier` = the Groth16 gateway;
   `check-sp1-verifier` confirmed routing; new `SP1ICS07Tendermint` deployed for each client.
4. **Relayer lockstep gate** (`check-relayer-vkeys`): confirmed the running proof-api/relayer
   serves the exact v6.1 vkeys recorded in the JSON.
5. **Schedule 6 timelock ops** via Safe txs at **nonces 38–43** — ICS20/ICS26/Escrow/IBCERC20
   upgrades + the two client migrations — with the ICS26-after-ICS20 predecessor. All six
   schedule Safe txs executed, advancing the Safe nonce **38 → 44**.
6. **Atomic cutover (step 7)** — after the timelock delay, the whole upgrade executed as
   **one** Safe MultiSend: `MultiSendCallOnly.multiSend(bytes)` via `operation = 1`
   (DelegateCall) through the canonical MultiSendCallOnly `0x9641d764fc13c8B624c04430C7356C1C7C8102e2`,
   packing all six `TimelockController.execute(...)` sub-calls in predecessor order.
   - **execTransaction tx:** `0x9cb74b41ef64fdeadf6085325a946fa871e10a4009087ec8e74e70944b8d5849`
   - Result: all proxies report v3; both clients migrated to v6.1.
7. **Register ICS27GMP (step 8)** on port `gmpport` via `ICS26Router.addIBCApp` (now gated by
   the AccessManager `ID_CUSTOMIZER_ROLE`), sent by the ID customizer
   `0x64259f722A0868CCf58A935C61A292cEA9dF035a` via Ledger.
   - **tx:** `0xa2db63b2315af8d605c70cd453001002f65da5fbb997de2908142a4e2683add7`
     (to ICS26Router proxy `0x3fcBB…e6c0`).
8. **Initialize both v3 escrows (step 9)** — `Escrow.initializeV2()` (permissionless, once
   each) via direct `cast send`; escrow authority → AccessManager.

## SP1 v6.1 migration details

- **Clients migrated:** `hub-testnet-0` (counterparty `08-wasm-262`) and
  `ledger-testnet-1` (counterparty `08-wasm-3`), merkle prefix `["ibc", ""]`.
- **vkey source — released ELFs, NOT repo fixtures.** vkeys were computed from the published
  `sp1-programs` release ELFs (default tag `v2.0.0-rc.2`) — the exact bytes the prover `wget`s
  into `/usr/local/bin/sp1-programs/<version>/`. The repo's committed test fixtures build
  non-reproducibly and in fact differ from the release, so they were deliberately not used.
  The four vkeys are identical across both clients (a property of the loaded programs):

  | vkey | value |
  | --- | --- |
  | updateClient | `0x00d38536f65ab10e7eff0895b1b9f7cf12f89691631742bb487fe090027e0e6d` |
  | membership | `0x000bd8ec43ea65b85c87eb57ace44692c3292ff297e01f29542b9fb476ed3e4f` |
  | ucAndMembership | `0x009fe47dbd3934f92417fbe4f17e79fe89417d61a724f66fadbc361b475dc091` |
  | misbehaviour | `0x0010008da4267c2e85d02616e853379e3c937c03a271b5b005f479cff09ccfcb` |

- **Verifier routing.** `.verifier` on both clients is the Groth16 **gateway**
  `0x397A5f7f3dBd538f23DE225B51f532c34448dA9B`. `check-sp1-verifier` confirmed the gateway
  routes the v6.1.0 proof selector to the real verifier
  `0xb69f2584CBcFf99a58C4e7002E8b89Af54a6f4e2` (`VERSION() == v6.1.0`), and not to the known
  broken v6.1.0 verifier `0xf0f70E15e9259970481c4F33bD87C3e47f161dec`.
- **Relayer lockstep.** `check-relayer-vkeys` calls the running proof-api's `CreateClient`,
  decodes the four vkeys embedded in the constructor args, and confirms they byte-match the
  JSON — proving the deployed relayer actually loaded the same release the on-chain clients
  were migrated to. Passed before cutover.

## Tooling added (all committed on this branch)

- `scripts/safe-propose.sh` + `safe.just` `safe-propose` / `propose-schedule` — propose Safe
  txs to the Safe Transaction Service with auto-queued nonces (no on-chain broadcast).
- `safe.just` `execute-timelock-multisend` — general atomic packer: bundle any set of
  already-scheduled `TimelockController.execute(...)` ops into one MultiSendCallOnly
  DelegateCall, validating each sub-call's `execute` selector and preserving predecessor order.
- `safe.just` `execute-v3-upgrade-multisend` — the v3 upgrade as the default op set for the
  packer, with `EXTRA_TIMELOCK_OPS` (`;`-separated) folding so additional scheduled ops can
  ride the same atomic execute.
- `scripts/sp1-vkeys.sh` + `sp1.just` `sp1-vkeys` — compute the four SP1 vkeys from the
  published release ELFs (never local rebuilds or test fixtures).
- `scripts/check-sp1-verifier.sh` + `sp1.just` `check-sp1-verifier` — verify each client's
  `.verifier` is the correct gateway and (with an RPC) that it routes v6.1.0 to the real verifier.
- `scripts/check-relayer-vkeys.sh` + `sp1.just` `check-relayer-vkeys` — verify the running
  proof-api/relayer serves the deployment's exact vkeys.
- `script/helpers/decode_create_client.py` — extended to emit the four vkeys from CreateClient
  calldata (used by the relayer check).
- `scripts/shadow-v2-to-v3-timelock-rehearsal.sh` — added `REHEARSE_RATE_LIMITER_GRANT=1` to
  rehearse the `EXTRA_TIMELOCK_OPS` folding path on an Anvil fork (validated green).
- `runbooks/upgrade-v2-to-v3.md` — rewritten for clarity/safety.

### Branch commits

| Commit | Subject |
| --- | --- |
| `cf5b369` | Safe-propose + relayer-vkey tooling and a general atomic timelock MultiSend |
| `94e4041` | Record testnet v3 deploys: AccessManager + ICS27, implementations, SP1 clients |
| `816fa3f` | Rehearse the `EXTRA_TIMELOCK_OPS` folding path in the timelock shadow rehearsal |
| `e3fa245` | Record ICS27GMP registration on `gmpport` (testnet v2→v3 upgrade complete) |

## Verification status

- `just verify-deployment` — **passes** all sections: ICS26 / ICS20 / ICS27, both escrows,
  and both SP1 clients. (Expected to fail between `deploy-light-client` and the migration
  execute, since the JSON points at the new client while the router still maps the old one;
  only run after cutover — which is when it passed.)
- `just check-sp1-verifier` — **passes**: both clients' gateways route v6.1.0 proofs to the
  real verifier.
- `just check-relayer-vkeys` — **passes**: running proof-api serves the deployment's vkeys.
- Proxies report v3; both light clients report the migrated v6.1 implementations.

## Notable findings

### Rate-limiter re-grant (step 10) was a NO-OP on testnet — and that was proven, not assumed

In v3, the escrow `setRateLimit` selector defaults to `ADMIN_ROLE` after the beacon upgrade,
so every v2 `RATE_LIMITER_ROLE` holder loses access unless re-granted. The escrows are plain
(non-enumerable) `AccessControl`, so there is no member list to read. We therefore:

1. Collected every `RoleGranted` event for `keccak256("RATE_LIMITER_ROLE")` on each v2 escrow
   via a full-range explorer `getLogs` (the public RPC caps `eth_getLogs` at ~50k blocks).
2. Swept the candidates with `hasRole(role, account)`.

Result: **no `RATE_LIMITER_ROLE` holders existed** on the v2 testnet escrows — their entire
event history was just `BeaconUpgraded` + `Initialized`. So step 10 had nothing to re-grant.
**Mainnet will likely differ** (non-empty snapshot) — see below.

### Folding mechanism for mainnet (single round)

A second schedule→delay→execute window is usually impractical on mainnet. The
`EXTRA_TIMELOCK_OPS` path lets the rate-limiter re-grant (step 10) and any role grants
(step 12) be **scheduled in the step-6 window** and then folded into the **same atomic
step-7 MultiSend**. Each folded `execute(...)` blob must byte-match its scheduled op
(identical prompt inputs) and that schedule must already have executed, or the whole atomic
bundle reverts. This path is rehearsed on-fork via `REHEARSE_RATE_LIMITER_GRANT=1` (green).

## What remains for mainnet

- **Use the folding path.** Schedule the rate-limiter re-grant (and any role grants) in the
  step-6 window and pack their executes into the step-7 atomic MultiSend via
  `EXTRA_TIMELOCK_OPS`, avoiding a second timelock round. Rehearse the fold first
  (`REHEARSE_RATE_LIMITER_GRANT=1 just shadow-v2-to-v3-mainnet-timelock`).
- **Rate-limiter snapshot will likely be non-empty.** Take the v2 `RATE_LIMITER_ROLE` holder
  snapshot on each live mainnet escrow before the cutover (it flips escrows to AccessManager
  authority), and re-grant `(client_id, rate_limiter)` pairs. `verify-deployment` does not
  assert these grants — confirm them manually.
- **Relayer lockstep on mainnet.** Cut the prod proof-api/relayer over to the same
  `sp1-programs` release build in lockstep with the on-chain migration; re-run
  `check-relayer-vkeys` against the prod proof-api before scheduling/executing.
- **PR #19** (the v3 tooling/upgrade PR) stays gated on the mainnet upgrade: the
  `verify (… .json)` CI jobs remain red on any chain still on v2 until its step 11 completes.
- Halt packet relaying around the mainnet cutover (defense-in-depth) and resume only after
  `verify-deployment` and `check-sp1-verifier` both pass.
