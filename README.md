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

## Deployment scripts

TODO: Document deploy group scripts

## Ops scripts

TODO: Document ops group script

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

## Timelock scripts

TODO: Document timelock scripts

### Upgrade proxy

Modify one (and only one at the time) of the `implementation` values in the deployment json for one of the ERC1967Proxy contracts (ICS26Router for instance).

Run the script to generate the information needed to submit a proposal to the Safe Wallet:
```bash
just timelock-upgrade-proxy
```

