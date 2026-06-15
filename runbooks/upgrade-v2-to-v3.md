# RUNBOOK - upgrading solidity-ibc-eureka from v2 to v3, including SP1 v6.1

## Context

The v3 upgrade changes contract authorization from per-contract `AccessControl` roles to a shared OpenZeppelin `AccessManager`.

The UUPS upgrades for `ICS20Transfer` and `ICS26Router` must call `initializeV2(address accessManager)` during `upgradeToAndCall`. The order matters: upgrade `ICS20Transfer` first, then `ICS26Router`, then the `Escrow` and `IBCERC20` beacon implementations. The ordering is not arbitrary: `ICS20Transfer.initializeV2` authenticates its caller against the deprecated v2 admin records still stored on `ICS26Router`, and `ICS26Router.initializeV2` deletes exactly those records, so upgrading the router first would make the `ICS20Transfer` upgrade revert.

Existing escrow proxies also need `Escrow.initializeV2()` after the escrow beacon has been upgraded. Initialize escrows only after the escrow beacon upgrade has executed. This call can be made by anyone, but it can only run once per escrow.

The core upgrades execute as separate timelocked transactions, so the system passes through mixed v2/v3 states (for example `ICS20Transfer` on v3 while `ICS26Router` is still v2, or escrow beacons upgraded before the escrows are initialized). Halt packet relaying before executing the first core upgrade and resume it only after `just verify-deployment` passes.

The upgrade also deploys `ICS27GMP` and `ICS27Account`. `deploy-v3-access-manager` configures ICS27 pauser/unpauser/admin target roles before AccessManager control is handed over. After the router is upgraded, an ID customizer registers the GMP app on `ICS27Lib.DEFAULT_PORT_ID` with `just register-ics27-gmp`.

In v3, `migrateClient` is controlled by the shared AccessManager instead of the v2 per-client migrator role. Customers that need self-owned client migration should use a proxy-style client design.

The SP1 v6.1 change is not picked up by upgrading the core proxies. Existing SP1 light clients are standalone contracts, so each upgraded client needs a new `SP1ICS07Tendermint` deployment and a timelocked `ICS26Router.migrateClient(...)` call. Run this as part of the same operations branch and timelock window as the v2-to-v3 upgrade.

`deploy-light-client` writes the future light-client implementation address into `deployments/<environment>/<chain_id>.json`. During the window between deploying the new SP1 client and executing `migrateClient`, `just verify-deployment` is expected to fail because the deployment JSON points at the new client while the router still maps the client ID to the old implementation. Only run final deployment verification after the migration executes.

For the same reason, the `verify (mainnet, 1.json)` and `verify (testnet, 11155111.json)` CI jobs fail from the moment the v3 tooling lands on `main` until the verification step (step 11) completes on the corresponding chain: `VerifyDeployment` asserts v3 state (AccessManager authority, ICS27GMP registration) while the chain is still on v2. This is expected — do not "fix" the workflow or block the operation on red verify CI during this window.

In v3, `RATE_LIMITER_ROLE` is a single manager-wide role while the rate-limit restriction is configured per escrow target. Once multiple escrows have their target function role configured, every `RATE_LIMITER_ROLE` holder can set rate limits on all of them — do not assume the v2 per-escrow isolation.

## Shadow fork rehearsal

To rehearse the full sequence against uncommitted local changes, start an Anvil fork in one terminal:

```bash
export SEPOLIA_RPC=<SEPOLIA_RPC_URL>
just shadow-start-sepolia
```

Then run the rehearsal in another terminal:

```bash
just shadow-v2-to-v3-sepolia-with-sp1
```

For Ethereum mainnet, use:

```bash
export MAINNET_RPC=<MAINNET_RPC_URL>
just shadow-start-mainnet
```

Then, in another terminal:

```bash
just shadow-v2-to-v3-mainnet-with-sp1
```

The generic form is `just shadow-v2-to-v3-with-sp1 <chain_id> <source_env> <shadow_env> <port>`, which is useful for non-default environments. The rehearsal copies the real deployment JSON into an ignored `deployments/shadow-*` environment, deploys the v3 `AccessManager`, ICS27, and implementations, impersonates `.accessManagerRoles.admin` on the fork to run the upgrades, deploys and migrates the SP1 light clients, registers ICS27 through an ID customizer, initializes known escrows, and runs deployment verification. Restart the Anvil fork before each fresh rehearsal.

The SP1 clients to deploy and migrate default to every `clientId` in the deployment JSON, and the rehearsal derives the expected migration count from that list and fails if the on-fork migration count does not match — so it cannot silently pass as a core-only upgrade. To rehearse only a subset, pass an explicit comma-separated list as the final argument of the generic recipe.

To rehearse against staged SP1 v6.1 state that is not yet committed to the source deployment JSON, prepare a shadow copy and run the preserve recipe instead:

```bash
just shadow-copy-deployment <chain_id> <source_env> <shadow_env>
# edit deployments/<shadow_env>/<chain_id>.json with the planned SP1 v6.1 trusted state and verification keys
just shadow-v2-to-v3-preserve <chain_id> <source_env> <shadow_env> <port> <expected_migrations> <comma_separated_sp1_client_ids>
```

### Timelock rehearsal (real schedule/execute path)

The `shadow-v2-to-v3-*-with-sp1` recipes above impersonate the AccessManager admin and call the proxies directly, so they validate the v2→v3 contract mechanics but not the timelock layer. To additionally exercise the production path — the `schedule-v3-*` / `execute-v3-*` recipe calldata submitted through the real `TimelockController`, including the predecessor that enforces ICS20-before-ICS26 ordering — run the timelock rehearsal against a running fork:

```bash
just shadow-v2-to-v3-sepolia-timelock
```

The proposer/executor Safe and the SP1 client ids are both read from the deployment JSON (no `SAFE_ADDRESS` or `SP1_CLIENT_IDS` env var needed; set `SP1_CLIENT_IDS` to migrate only a subset). It deploys the v3 stack (leaving the fork's proxies on v2), then for each operation generates the recipe calldata, submits it to the timelock by impersonating the Safe, advances the fork past `getMinDelay()`, asserts that executing the ICS26Router upgrade before the ICS20Transfer upgrade reverts, executes the upgrades and SP1 migrations in order, registers ICS27, initializes escrows, and runs `verify-deployment`. The mainnet form is `just shadow-v2-to-v3-mainnet-timelock`.

## Runbook

1. Facilitator creates a new operations branch.

   ```bash
   just new-operation upgrade-v2-to-v3 <environment> <chain_id>
   ```

2. Facilitator deploys the v3 `AccessManager`.

   ```bash
   just deploy-v3-access-manager
   ```

   Before running this, make sure `.accessManagerRoles.delegateSenders` contains every existing delegate sender integration that must keep working after the authority switch. `deploy-v3-access-manager` reads the role holders from `.accessManagerRoles.*` (falling back to the legacy `.ics20Transfer.*` / `.ics26Router.*` keys only when the `.accessManagerRoles.*` key is absent), so once that section exists it is the source of truth — editing the legacy keys has no effect. The same applies to `.accessManagerRoles.relayers`, `.pausers`, `.unpausers`, `.idCustomizers`, and `.erc20Customizers`.

   The script writes `.accessManager`, `.accessManagerRoles`, and `.ics27Gmp` into `deployments/<environment>/<chain_id>.json`. It grants `.accessManagerRoles.admin` the `ADMIN_ROLE`, configures target function roles for the existing `ICS26Router` and `ICS20Transfer` proxies plus the new `ICS27GMP` proxy, and copies the current relayer, pauser, unpauser, delegate sender, ID customizer, and ERC20 customizer accounts from the deployment JSON.

3. Facilitator deploys the four v3 implementations with `just deploy-implementation`, selecting each contract:

   ```text
   ICS20Transfer
   ICS26Router
   Escrow
   IBCERC20
   ```

4. Facilitator updates `deployments/<environment>/<chain_id>.json` with the new implementation addresses:

   - `.ics20Transfer.implementation`
   - `.ics26Router.implementation`
   - `.ics20Transfer.escrowImplementation`
   - `.ics20Transfer.ibcERC20Implementation`

5. Facilitator prepares the SP1 v6.1 light-client migrations in the same branch.

   For each light client that must move to SP1 v6.1, update its `light_clients` entry with the new trusted state, the v6.1 verification keys, and the v6.1 verifier:

   - **Trusted state** (`.trustedClientState` / `.trustedConsensusStateHash`): regenerate it from the proof-api with `just deploy-fresh-light-client-state` (the trusted state is independent of the SP1 program version, so the existing proof-api is fine for this).
   - **Verification keys** (`.updateClientVkey`, `.membershipVkey`, `.ucAndMembershipVkey`, `.misbehaviourVkey`): set them from the **published `sp1-programs` release** the prover actually loads — do **not** hand-copy the repo's test fixtures, which can be built non-reproducibly and differ from the release:

     ```bash
     just sp1-vkeys --write <environment> <chain_id> <client_id>...
     ```

     This downloads the released program ELFs (the exact bytes the deployed prover `wget`s into `/usr/local/bin/sp1-programs/<version>/`) and computes the vkeys from them, so they are guaranteed to match the prover. Override the release with `--version <tag>` (default `v2.0.0-rc.2`). The four vkeys are identical across clients of the same program version.
   - **Verifier** (`.verifier`): the SP1 v6.1 verifier gateway for the chain (Groth16 or Plonk, matching the client's `zkAlgorithm`). For `mainnet`, `testnet`, and non-default shadow environments it must be an explicit nonzero address; empty `.verifier` and `"mock"` are only allowed for `local`, `shadow-mainnet`, and `shadow-sepolia`. Validate it before deploying — including, with `ETH_RPC` set, the on-chain check that the gateway routes v6.1.0 proofs to the real (non-broken) verifier:

     ```bash
     just check-sp1-verifier
     ```

   Make sure proof generation for the migrated clients runs a proof-api built against this same SP1 v6.1 `sp1-programs` release; the prod relayer-api must be cut over to the matching version **in lockstep** with the on-chain migration (step 7) or the migrated clients' proofs will not verify.

   ```bash
   just deploy-light-client
   ```

   Run this once per upgraded client and provide the client ID when prompted. The script writes the new `.implementation` and (re)confirms `.verifier` in the deployment JSON. Keep the generated addresses in the operation notes.

6. Signers verify and schedule all timelocked operations before waiting for the timelock delay.

   Schedule the core upgrades:

   ```bash
   just schedule-v3-ics20transfer-upgrade-params <schedule_safe_nonce_1>
   just schedule-v3-ics26router-upgrade-params <schedule_safe_nonce_2>
   just schedule-escrow-upgrade-params <schedule_safe_nonce_3>
   just schedule-ibcerc20-upgrade-params <schedule_safe_nonce_4>
   ```

   The `ICS20Transfer` and `ICS26Router` calls must show `upgradeToAndCall(newImplementation, initializeV2(accessManager))`.

   Get the starting Safe nonce from `just get_safe_nonce` or the Safe UI. Use a different Safe nonce for each Safe transaction. For example, if the current nonce is `N`, use `N`, `N+1`, `N+2`, and `N+3` for the four schedule transactions.

   Schedule each SP1 migration while the same timelock window is open:

   ```bash
   just schedule-v3-light-client-migration-params <client_id> <schedule_safe_nonce_n>
   ```

   Run this once per upgraded client. This is a calldata-only generator, so it can schedule the v3 `migrateClient(clientId, counterpartyInfo, newImplementation)` call before the `ICS26Router` proxy has been upgraded. Use a unique Safe nonce for every schedule transaction.

7. After the timelock delay, execute the whole upgrade as a single atomic Safe MultiSend transaction.

   Before executing, halt packet relaying for this chain and keep it halted until verification passes in step 11.

   ```bash
   just execute-v3-upgrade-multisend <execute_safe_nonce> <client_id_1> <client_id_2> ...
   ```

   This packs each `TimelockController.execute(...)` call — `ICS20Transfer`, `ICS26Router`, `Escrow`, `IBCERC20`, then one per SP1 client ID (the migrations) — into a `MultiSendCallOnly.multiSend(bytes)` payload and submits it as one Safe transaction with `to` = the canonical MultiSendCallOnly (`0x9641d764fc13c8B624c04430C7356C1C7C8102e2` on mainnet and Sepolia, overridable via `MULTISEND_CALL_ONLY`), `value` = `0`, `operation` = `1` (delegatecall), and `data` = `multiSend(...)`. The Safe delegatecalls MultiSend so each timelock `execute` runs with the Safe as `msg.sender` and passes the `EXECUTOR_ROLE` check. The recipe prints the `to`, `value`, `operation`, `data`, and the `safeTxHash` (computed with `operation = 1`) for signer verification; pass a non-empty nonce to additionally print the per-signer signing hashes.

   Scheduling is unchanged: each operation is still scheduled individually through the timelock in step 6, and the timelock min-delay still applies before the execute can run — only the execute is atomic (schedule and execute can never share a transaction). The in-batch predecessor still orders the executes (`ICS20Transfer` before `ICS26Router`), and atomicity guarantees all-or-nothing: if any sub-execute reverts, the whole Safe transaction reverts and no upgrade lands. Because the execute is atomic, the contracts never settle into a mixed v2/v3 window — so halting relaying is a brief guard around this single transaction rather than a long window — but still keep relaying halted until `just verify-deployment` passes (step 11) as defense-in-depth, and note that the relayer-role cutover requires the relayer set to be present in `.accessManagerRoles.relayers` before step 2. This path is rehearsed by the shadow-fork timelock rehearsal (the `shadow-v2-to-v3-*-timelock` recipes above) and unit-tested in `test/SafeMultiSendV3Upgrade.t.sol`.

8. An ID customizer registers the deployed `ICS27GMP` app.

   ```bash
   just register-ics27-gmp
   ```

   This must run after the `ICS26Router` v3 upgrade because `addIBCApp` is now controlled by the AccessManager `ID_CUSTOMIZER_ROLE`.

9. Facilitator initializes every existing escrow proxy.

    Use the known client IDs from `deployments/<environment>/<chain_id>.json` and any client IDs that have escrow state on-chain.

    ```bash
    just initialize-escrow-v2-params <client_id>
    ```

    To print initialization params for every known deployment JSON client ID that currently has a nonzero escrow address, use:

    ```bash
    just initialize-known-escrows-v2-params
    ```

    Submit the printed `to` and `data` as a normal transaction. This does not need to go through the timelock unless the operation policy requires it.

10. Facilitator re-grants `RATE_LIMITER_ROLE` to current rate limiters.

    `deploy-v3-access-manager` does **not** wire any escrow `setRateLimit` target role or grant `RATE_LIMITER_ROLE` (escrows are configured per-escrow, lazily). After the escrow beacon upgrade (step 7) flips escrows to the AccessManager authority, `setRateLimit` defaults to `ADMIN_ROLE`, so every account that held the v2 per-escrow `RATE_LIMITER_ROLE` loses access until it is re-granted. For each `(client_id, rate_limiter)` that must keep rate-limit access, grant it (this wires the escrow's `setRateLimit` selector to `RATE_LIMITER_ROLE` and grants the role):

    ```bash
    just timelock-grant-rate-limiter-role schedule
    just timelock-grant-rate-limiter-role execute <safe_nonce>
    ```

    Identify the current holders from the live escrows before the upgrade (the v2 `RATE_LIMITER_ROLE` on each `Escrow`). `RATE_LIMITER_ROLE` is manager-wide once any escrow's target role is configured (see the note above). `verify-deployment` does not assert escrow rate-limit roles, so confirm these grants manually.

11. Facilitator verifies the deployment.

    ```bash
    just verify-deployment
    ```

    For migrated SP1 clients, also re-run the verifier check on-chain (with `ETH_RPC` set) to confirm each `.verifier` gateway still routes v6.1.0 proofs to the real verifier:

    ```bash
    just check-sp1-verifier
    ```

    Resume packet relaying only after verification passes.

12. If any account needs roles that are not represented in the current deployment JSON, grant them through the `AccessManager` after the upgrade.

    ```bash
    just timelock-grant-role schedule
    just timelock-grant-role execute <safe_nonce>
    ```

    Known delegate sender integrations should be in `.accessManagerRoles.delegateSenders` before step 2 so they do not lose access during the `ICS20Transfer` upgrade.

IBCERC20 metadata customization was removed in solidity-ibc-eureka v3. Prefer custom ERC20s through the custom ERC20 flow instead of post-deployment IBCERC20 metadata changes.
