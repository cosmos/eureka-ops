# Eureka ops

This repository is the source of truth for Eureka-related deployments.

It is used by operators to deploy and perform maintenance operations.
In addition, it can be used by anyone to find the most up-to-date contract addresses for different deployments and even verify that they match what is on-chain.

## Pre-requisites

### Software

To use most of the functionality in this repo, you will need to install the following software:
- [Foundry toolchain](https://book.getfoundry.sh/getting-started/installation)
- [Bun](https://bun.sh/docs/installation)
- [just](https://just.systems/man/en/packages.html)
- [fzf](https://junegunn.github.io/fzf/installation/)
- [jq](https://jqlang.org/)

### .eureka-env

Most recipes in this repo depend on values defined in `.eureka-env`. 
To set yours up, copy the `.eureka-env.example` file and fill in the values, according to the environment you are going to run against.

## Just recipes

The functionality of this repo is implemented through Just recipes (which are somewhat similar to Make targets).
To see available recipes, run:
```shell
just --list
```

## Runbooks

Operator procedures live in [`runbooks/`](./runbooks). Key ones:

- [`upgrade-v2-to-v3.md`](./runbooks/upgrade-v2-to-v3.md) — the canonical v2→v3 core upgrade + SP1 v6.1 migration (steps 1–13). **Single source of truth for that operation.**
- [`post-upgrade-role-testing.md`](./runbooks/post-upgrade-role-testing.md) — validate & test the v3 `AccessManager` roles after a v2→v3 upgrade (read its *Mainnet adaptation* section before running anything on mainnet).
- [`upgrade-light-client.md`](./runbooks/upgrade-light-client.md), [`upgrade-ics-20.md`](./runbooks/upgrade-ics-20.md), [`upgrade-ics-26.md`](./runbooks/upgrade-ics-26.md), [`upgrade-escrow.md`](./runbooks/upgrade-escrow.md), [`upgrade-ibcerc20.md`](./runbooks/upgrade-ibcerc20.md) — routine single-contract upgrades.
- [`pause.md`](./runbooks/pause.md), [`recover-expired-light-client.md`](./runbooks/recover-expired-light-client.md), [`env-setup.md`](./runbooks/env-setup.md).
- **Operations log:** [`runbooks/operations/`](./runbooks/operations) — one folder per executed operation; each has a `RECORD.md` (addresses, tx hashes, findings). See [`2026-06-18-upgrade-v2-to-v3/RECORD.md`](./runbooks/operations/2026-06-18-upgrade-v2-to-v3/RECORD.md) for the v2→v3 record.

### Role discovery & validation scripts

- [`scripts/discover-v2-roles.py`](./scripts/discover-v2-roles.py) — **pre-cutover**: enumerate the live v2 role grants (via Etherscan logs) and reconcile against the deployment JSON, so you build the exact grant set (incl. the `RATE_LIMITER` re-grant set) the upgrade must carry. Needs `ETH_RPC` + `ETHERSCAN_API_KEY`.
- [`scripts/validate-v3-roles.py`](./scripts/validate-v3-roles.py) — **post-cutover**: independently validate every v3 `AccessManager` (target,selector)→role, exact role membership, and `authority()` wiring on-chain. Needs `ETH_RPC`.

## Manual verification instructions

Any on-chain verification that is not implemented as recipes yet should be documented below:

### Verify Ethereum Light Client code on Cosmos Hub

To verify that the Ethereum Light on the hub is running a specific version of the CosmWasm smart contract from the [solidity-ibc-eureka](https://github.com/cosmos/solidity-ibc-eureka) repo, follow the steps below:

1. Acquire the binary you want to verify against by for instance downloading the binary from [the release page](https://github.com/cosmos/solidity-ibc-eureka/releases)
2. Get the binary checksum by running `gunzip -c path/to/cw_ics08_wasm_eth.wasm.gz | sha256sum`
3. Fetch the checksum of the Ethereum light client (example below for Cosmos Hub mainnet, where the Ethereum light client ID is `08-wasm-1369`) and convert it from base64 to hex:
    ```shell
    gaiad q ibc client state 08-wasm-1369 --output json | jq -r ".client_state.checksum" | base64 --decode | xxd -p -c 32
    ```
4. Verify that the output from step 2 matches the output from step 3

## Recipes

### Shadow fork v2-to-v3 rehearsal

To rehearse the v2-to-v3 upgrade (including the SP1 light-client migrations) against uncommitted local changes, start an Anvil fork in one terminal:

```bash
export SEPOLIA_RPC=<SEPOLIA_RPC_URL>
just shadow-start-sepolia
```

Then run the rehearsal in another terminal:

```bash
just shadow-v2-to-v3-sepolia-with-sp1
```

The SP1 clients to migrate are read from the deployment JSON (`.light_clients[].clientId`), so there is nothing to type, and the rehearsal writes only to ignored `deployments/shadow-*` copies. Use `MAINNET_RPC` with `just shadow-start-mainnet` and `just shadow-v2-to-v3-mainnet-with-sp1` for Ethereum mainnet. To additionally exercise the real `TimelockController` + atomic Safe MultiSend path, use `just shadow-v2-to-v3-sepolia-timelock`. See [`runbooks/upgrade-v2-to-v3.md`](./runbooks/upgrade-v2-to-v3.md) for the full flow.

### Fresh v3 core deployment

For a new v3 deployment where `accessManager`, `ics26Router`, and `ics20Transfer` addresses are still zero in the deployment JSON, deploy the core contracts with:

```bash
just deploy-v3-core
```

This deploys the `AccessManager`, `ICS26Router`, `ICS20Transfer`, `ICS27GMP`, `ICS27Account`, `Escrow`, and `IBCERC20` implementations, registers the transfer and GMP apps on the router, configures the v3 target function roles, grants the configured relayer/pauser/unpauser/delegate-sender/customizer roles, and writes the deployed addresses back to `deployments/<environment>/<chain_id>.json`.

The script temporarily uses the broadcast account as the `AccessManager` admin during deployment, then hands admin control to the configured `.accessManagerRoles.admin`. The configured admin can be an EOA, Safe, or timelock.

### Deploy light client implementation for migration/upgrade

Migrating/upgrading a light client is done in two steps:
1. Deploying the new light client contract
2. Migrating the existing light client to use the new contract

#### 1: Deploying a new light client contract
To deploy a new light client contract that is intended to be migrated, you want to essentially make a "copy" (with any modifications you might want, such as new vkeys) of the existing light client with a new contract.

> Deploying the new light client contract can be done by anyone, but it is important for whoever is running the migration to verify both the contract and constructor parameters of the new light client.

1. Update any fields you want changed in the relevant light client entry in the deployment JSON file.
2. Update the deployment JSON entry with the latest client and consensus state from the existing light client with:
    ```bash
    just deploy-update-light-client-state # You will be prompted for the client ID of the light client you want updated
    ```
3. Deploy the light client with:
    ```bash
    just deploy-light-client # You will be prompted for the client ID of the light client to deploy
    ```

The last step will deploy the light client, but not add it to the IBC Client router. It is just a deployed contract with permissions set up for it. 
The implementation address will be updated in the deployment JSON entry for the light client, making it ready for step 2: migrating the existing light client.

#### 2: Migrate the existing light client
> ⚠️ Only a wallet with the Light Client Migrator role for the given light client can migrate. Here, we're assuming a timelock admin has those permissions.

1. Generate the timelock schedule transaction for the light client with:
    ```bash
    just timelock-migrate-light-client schedule
    ```
2. Follow the instructions to create the timelock transactions

After the timelock delay has passed, do the above steps again but replace `schedule` with `execute`

### IBCERC20 Metadata

IBCERC20 metadata customization was removed in solidity-ibc-eureka v3. Prefer custom ERC20s through the custom ERC20 flow instead of post-deployment IBCERC20 metadata changes.

### Upgrade a contract that is behind a proxy

> [!IMPORTANT]
> This is for **routine** UUPS upgrades **after** the v2-to-v3 migration. It performs an `upgradeToAndCall` with **empty** calldata, so it does **not** call `initializeV2`. Do **not** use it to perform the v2-to-v3 core upgrades — use `schedule-v3-*`/`execute-v3-*-upgrade-params` (see [`runbooks/upgrade-v2-to-v3.md`](./runbooks/upgrade-v2-to-v3.md)), which call `initializeV2(accessManager)`. As a guard, `timelock-upgrade-proxy` refuses to upgrade `ICS26Router`/`ICS20Transfer` when the deployment records an `accessManager` but the proxy is not yet AccessManaged by it.

Modify one (and only one at the time) of the `implementation` values in the deployment json for one of the ERC1967Proxy contracts (`ICS26Router`, `ICS20Transfer`, or `ICS27GMP`).

Run the script to generate the information needed to submit a proposal to the Safe Wallet:
```bash
just timelock-upgrade-proxy
```

The beacon implementations have their own param recipes: `schedule-escrow-upgrade-params`, `schedule-ibcerc20-upgrade-params`, and `schedule-ics27account-upgrade-params` (plus the matching `execute-*`).
