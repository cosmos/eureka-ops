# RUNBOOK - upgrading solidity-ibc-eureka from v2 to v3, including SP1 v6.1

## Context

The v3 upgrade changes contract authorization from per-contract `AccessControl` roles to a shared OpenZeppelin `AccessManager`.

The UUPS upgrades for `ICS20Transfer` and `ICS26Router` must call `initializeV2(address accessManager)` during `upgradeToAndCall`. The order matters: upgrade `ICS20Transfer` first, then `ICS26Router`, then the `Escrow` and `IBCERC20` beacon implementations.

Existing escrow proxies also need `Escrow.initializeV2()` after the escrow beacon has been upgraded. Initialize escrows only after the escrow beacon upgrade has executed. This call can be made by anyone, but it can only run once per escrow.

The upgrade also deploys `ICS27GMP` and `ICS27Account`. `deploy-v3-access-manager` configures ICS27 pauser/unpauser/admin target roles before AccessManager control is handed over. After the router is upgraded, an ID customizer registers the GMP app on `ICS27Lib.DEFAULT_PORT_ID` with `just register-ics27-gmp`.

In v3, `migrateClient` is controlled by the shared AccessManager instead of the v2 per-client migrator role. Customers that need self-owned client migration should use a proxy-style client design.

The SP1 v6.1 change is not picked up by upgrading the core proxies. Existing SP1 light clients are standalone contracts, so each upgraded client needs a new `SP1ICS07Tendermint` deployment and a timelocked `ICS26Router.migrateClient(...)` call. Run this as part of the same operations branch and timelock window as the v2-to-v3 upgrade.

`deploy-light-client` writes the future light-client implementation address into `deployments/<environment>/<chain_id>.json`. During the window between deploying the new SP1 client and executing `migrateClient`, `just verify-deployment` is expected to fail because the deployment JSON points at the new client while the router still maps the client ID to the old implementation. Only run final deployment verification after the migration executes.

## Shadow fork rehearsal

To rehearse the full sequence against uncommitted local changes, start an Anvil fork in one terminal:

```bash
export SEPOLIA_RPC=<SEPOLIA_RPC_URL>
just shadow-start-sepolia
```

Then run the rehearsal in another terminal:

```bash
just shadow-v2-to-v3-sepolia
```

For Ethereum mainnet, use:

```bash
export MAINNET_RPC=<MAINNET_RPC_URL>
just shadow-start-mainnet
```

Then, in another terminal:

```bash
just shadow-v2-to-v3-mainnet
```

The generic form is `just shadow-v2-to-v3 <chain_id> <source_env> <shadow_env> <port>`, which is useful for non-default environments. The rehearsal copies the real deployment JSON into an ignored `deployments/shadow-*` environment, deploys the v3 `AccessManager`, ICS27, and implementations, impersonates `.accessManagerRoles.admin` on the fork to run the upgrades, registers ICS27 through an ID customizer, initializes known escrows, and runs deployment verification. Restart the Anvil fork before each fresh rehearsal.

The plain `shadow-v2-to-v3-*` recipes are a core v2-to-v3 rehearsal. For a proper combined v2-to-v3 plus SP1 rehearsal, preserve a prepared shadow deployment JSON:

```bash
just shadow-copy-deployment <chain_id> <source_env> <shadow_env>
```

Update `deployments/<shadow_env>/<chain_id>.json` with the planned SP1 v6.1 trusted state and verification keys. Then run the full combined shadow test without overwriting the prepared shadow JSON. The shadow script deploys each named SP1 client into the fork, deploys the v3 core contracts, runs the v2-to-v3 upgrade, migrates those SP1 clients, and fails if the number of migrations does not match the provided client list.

```bash
just shadow-v2-to-v3-with-sp1 <chain_id> <source_env> <shadow_env> <port> <comma_separated_sp1_client_ids>
```

For example:

```bash
just shadow-v2-to-v3-sepolia-with-sp1 hub-testnet-0,ledger-testnet-1,ledger-testnet-2
```

The `with-sp1` recipe derives the expected migration count from the client-id list, so the rehearsal cannot silently pass as a core-only upgrade. Treat this recipe as the required shadow rehearsal for the combined operation.

## Runbook

1. Facilitator creates a new operations branch.

   ```bash
   just new-operation upgrade-v2-to-v3 <environment> <chain_id>
   ```

2. Facilitator deploys the v3 `AccessManager`.

   ```bash
   just deploy-v3-access-manager
   ```

   Before running this, make sure `.ics20Transfer.delegateSenders` contains every existing delegate sender integration that must keep working after the authority switch.

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

   For each light client that must move to SP1 v6.1, update its `light_clients` entry with the new trusted state and v6.1 verification keys. Verify that the SP1 programs and verification keys were generated with the SP1 v6.1 toolchain before deploying or migrating clients. For `mainnet`, `testnet`, and non-default shadow environments, `.verifier` must be an explicit nonzero SP1 v6.1 verifier address. Empty `.verifier` and `"mock"` verifier deployments are only allowed for `local`, `shadow-mainnet`, and `shadow-sepolia` rehearsals.

   ```bash
   just deploy-light-client
   ```

   Run this once per upgraded client and provide the client ID when prompted. The script writes the new `.implementation` and `.verifier` into the deployment JSON. Keep the generated addresses in the operation notes.

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

7. After the timelock delay, execute the core upgrades first.

   ```bash
   just execute-v3-ics20transfer-upgrade-params <execute_safe_nonce_1>
   just execute-v3-ics26router-upgrade-params <execute_safe_nonce_2>
   just execute-escrow-upgrade-params <execute_safe_nonce_3>
   just execute-ibcerc20-upgrade-params <execute_safe_nonce_4>
   ```

8. Execute each SP1 light-client migration immediately after the core upgrades succeed.

   ```bash
   just execute-v3-light-client-migration-params <client_id> <execute_safe_nonce_n>
   ```

   Run this once per upgraded client with the same client ID used during scheduling. The migration can be scheduled in parallel with the core upgrade, but execute it after the `ICS26Router` v3 upgrade so the final state is v3 core plus SP1 v6.1 light clients.

9. An ID customizer registers the deployed `ICS27GMP` app.

   ```bash
   just register-ics27-gmp
   ```

   This must run after the `ICS26Router` v3 upgrade because `addIBCApp` is now controlled by the AccessManager `ID_CUSTOMIZER_ROLE`.

10. Facilitator initializes every existing escrow proxy.

    Use the known client IDs from `deployments/<environment>/<chain_id>.json` and any client IDs that have escrow state on-chain.

    ```bash
    just initialize-escrow-v2-params <client_id>
    ```

    To print initialization params for every known deployment JSON client ID that currently has a nonzero escrow address, use:

    ```bash
    just initialize-known-escrows-v2-params
    ```

    Submit the printed `to` and `data` as a normal transaction. This does not need to go through the timelock unless the operation policy requires it.

11. Facilitator verifies the deployment.

    ```bash
    just verify-deployment
    ```

12. If any account needs roles that are not represented in the current deployment JSON, grant them through the `AccessManager` after the upgrade.

    ```bash
    just timelock-grant-role schedule
    just timelock-grant-role execute <safe_nonce>
    ```

    Known delegate sender integrations should be in `.ics20Transfer.delegateSenders` before step 2 so they do not lose access during the `ICS20Transfer` upgrade.

IBCERC20 metadata customization was removed in solidity-ibc-eureka v3. Prefer custom ERC20s through the custom ERC20 flow instead of post-deployment IBCERC20 metadata changes.
