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

### Verify contract code on Ethereum

There are two ways you can verify the source code of a given contract.

#### 1: With the `verify-contract` recipe
We provide a convenience script that verifies that the contract locked in the `package.json` (listed in the dependencies as `@cosmos/solidity-ibc-eureka`) are the same as deployed on-chain.

This method requires 

1. Run `just verify-contract` and respond to the prompts outlined in the next steps
    a. The version (tag/ref) should match the expected version of the contracts you want to verify against
2. Enter the contract address you want to verify
3. Select the contract that you want to verify against

If successful, you will see something like:
```
Contract [node_modules/@cosmos/solidity-ibc-eureka/contracts/light-clients/SP1ICS07Tendermint.sol:SP1ICS07Tendermint] "0x216Da2c06A8c029F3d77741C3d015b22e35F62DF" is already verified. Skipping verification.
```

## Recipes

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

### Updating IBCERC20 Metadata

> ⚠️ Only a wallet with the Token Operator role is able to update the IBCERC20 Metadata

To update the Metadata for an IBCERC20 contract, you need to do the following:
1. Grant the metadata role for the IBCERC20 contract with:
    ```bash
    just ops-grant-metadata-role # You will be prompted for the IBCERC20 Address and the address of the grantee
    ```
2. Set the metadata:
    ```bash
    just ops-set-metadata # You will be prompted for the IBCERC20 Address to update and the values to set
    ```

### Upgrade a contract that is behind a proxy

Modify one (and only one at the time) of the `implementation` values in the deployment json for one of the ERC1967Proxy contracts (ICS26Router for instance).

Run the script to generate the information needed to submit a proposal to the Safe Wallet:
```bash
just timelock-upgrade-proxy
```

