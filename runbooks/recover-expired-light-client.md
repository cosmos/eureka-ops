# Runbook — recover an expired SP1 light client

This runbook explains how to recover an **expired `SP1ICS07Tendermint` light client** (an IBC light client on Ethereum that tracks a Cosmos chain). It is written for someone with no prior context: it covers what the problem is, the systems involved, the exact commands, and every gotcha we hit doing it for real.

For the *normal* (non-expired) light-client migration ceremony, see [`upgrade-light-client.md`](./upgrade-light-client.md). This runbook is the **expired** variant — it adds a step to regenerate fresh trusted state, then reuses the same deploy + migrate flow.

---

## 1. The problem

An `SP1ICS07Tendermint` contract verifies a Cosmos chain's Tendermint consensus using SP1 zero-knowledge proofs. Like any Tendermint light client it has a **trusting period** (typically 2/3 of the Cosmos chain's unbonding period). If no `updateClient` lands within that window, the latest trusted consensus state ages out and the client becomes **expired** — it can no longer be updated by a normal proof, because there is no recent-enough trusted state to verify against.

You **cannot** revive an expired client with a normal `updateClient`. The fix is to **deploy a freshly-initialised client** with a recent trusted header and **repoint the existing client ID** at it:

1. **Generate fresh trusted state** (new `trustedClientState` + `trustedConsensusStateHash`) from a running proof-api and write it into the deployment JSON.
2. **Deploy a new `SP1ICS07Tendermint` contract** initialised with that fresh state (existing vkeys/verifier reused).
3. **Migrate** the client ID to point at the new contract (`ics26Router.migrateClient`), via the timelock + Gnosis Safe.

> [!NOTE]
> Why step 1 is special for an *expired* client: the pre-existing `just deploy-update-light-client-state` reads trusted state from the **on-chain contract** (`getClientState()`), which is stale/expired and therefore useless. The `deploy-fresh-light-client-state` recipe instead pulls **fresh** state from the proof-api.

---

## 2. Systems involved

- **`eureka-ops`** (this repo) — source of truth for deployments; operations run via `just`. The target lives in `deployments/<env>/<chainId>.json` under `light_clients["<idx>"]`.
- **`ibc-contracts`** — upstream Solidity contracts + the `operator` binary. The deployed contracts were compiled from a tagged version of this repo (pinned in `package.json` as `@cosmos/ibc-contracts`).
- **The proof-api (a.k.a. eureka-relayer)** — a gRPC service that builds unsigned IBC txs. Its `CreateClient` method queries the Cosmos RPC and returns the **creation calldata** for a fresh `SP1ICS07Tendermint` (no proof generated). We use it as the source of fresh trusted state. It runs in k8s (see step 1 for access).

> [!WARNING]
> The version the contracts were **deployed** from can differ from what the repo currently **compiles** and from the **running** proof-api image. Concretely, on the testnet recovery the live `ICS26Router` (deployed from `solidity-v2.0.0`) uses OZ `AccessControl`, while newer upstream source (`solidity-v3.0.0`+) uses `AccessManaged` — reading the wrong checkout gives you the wrong access-control model. **Always confirm access control / addresses against the live contract** (`cast call`), not the checked-out source.

---

## 3. Roles

| Role         | Who |
|--------------|-----|
| Facilitator  | runs the recipes, deploys the new contract, gathers Safe-tx params |
| Signer(s)    | Gnosis Safe owner(s) who sign the schedule + execute Safe txs |
| Notekeeper   | records addresses / hashes for the PR |

---

## 4. Prerequisites

- Tooling: `foundry` (forge/cast/chisel), `bun`, `just`, `jq`, `fzf`, **`grpcurl`**, **`python3`**, `kubectl`.
- **Proof-api reachable** for [step 1](#6-step-1--generate-fresh-trusted-state) (k8s port-forward).
- A **deploy signer with gas** for [step 2](#7-step-2--deploy-the-new-contract) (any funded EOA; need not be a Safe owner — deploying is permissionless).
- A **Safe owner** + the Safe for [step 3](#8-step-3--migrate-the-client-id-timelock--gnosis-safe).

> [!NOTE]
> **Signing note:** the `just` deploy/timelock recipes sign via `forge`, which supports **Ledger, raw private key, mnemonic, or an encrypted keystore** — but **not MetaMask** (no CLI bridge). For step 3 the Safe transactions are signed in the **Safe UI** (MetaMask works there) or verified via the repo's EIP-712 hash recipes.

---

## 5. Step 0 — point the repo at the right deployment (`.eureka-env`)

`just` auto-loads `.eureka-env` (gitignored). See [`.eureka-env.example`](../.eureka-env.example) for a full template; minimal example for Sepolia:

```
EUREKA_ENVIRONMENT=testnet
EUREKA_CHAIN=11155111
ETH_RPC=<a Sepolia RPC URL>

# Deploy signer (step 2). Pick ONE:
#  - Ledger:      set SENDER=0x... and leave PRIVATE_KEY unset
#  - Private key: set PRIVATE_KEY=0x... (any value here OVERRIDES the Ledger path)
SENDER=0x...
# PRIVATE_KEY=0x...
# ETHERSCAN_API_KEY=...   # only needed for --verify to succeed; deploy + JSON write happen regardless

# Step 1 proof-api module identifiers (see step 1 for how to find them):
SRC_CHAIN=<cosmos-chain-id>
DST_CHAIN=<eth-chain-id>       # decimal chain id, e.g. 11155111 for Sepolia
PROOF_TYPE=groth16            # MUST match the existing client's zk algorithm
```

The Safe that holds `PROPOSER` on the timelock (step 3) is read from the deployment JSON's `.safe` key, so it needs no `.eureka-env` entry.

> [!WARNING]
> ⚠️ **`PRIVATE_KEY` footgun:** setting it to *any* value (even zeros) makes the recipes use `--private-key` instead of the Ledger. Leave it commented to use a Ledger.

`just info-env` prints the resolved settings (private key redacted) — sanity-check the chain, RPC, and that the broadcast flags show the signer you expect.

---

## 6. Step 1 — generate fresh trusted state

### 6a. Reach the proof-api
The proof-api runs in k8s. Port-forward it to `localhost:3000`:

```
kubectl --context <eks-cluster-context> \
  -n <namespace> port-forward pod/<proof-api-pod> 3000:3000
```
> [!NOTE]
> 🔒 The concrete cluster context (ARN), namespace, and pod naming convention are internal infra and live in the internal docs, not this public repo.

Find the pod with `kubectl --context <eks-cluster-context> -n <namespace> get pods | grep relayer-api`. Confirm it's up: `grpcurl -plaintext localhost:3000 list` should list `relayer.RelayerService` (v0.7.x) or `proofapi.ProofApiService` (v0.8.x).

### 6b. Find `SRC_CHAIN` / `DST_CHAIN`
These must **exactly match** the proof-api's configured module identifiers — **not** necessarily the on-chain chain-id. Source of truth is the relayer config (internal repo + config path — see internal docs): find the `cosmos_to_eth` module whose `ics26_address` matches your `ics26Router.proxy`. `src_chain` is the Cosmos id (e.g. `provider`), `dst_chain` is the **decimal** Eth chain id (e.g. `11155111`).

You can also probe a candidate pair (metadata only, no proof):
```
grpcurl -plaintext -d '{"src_chain":"<src>","dst_chain":"<dst>"}' localhost:3000 relayer.RelayerService/Info
```
A configured pair does *not* return `Module not found`.

### 6c. Run the recipe
```
just deploy-fresh-light-client-state      # enter the client ID when prompted, confirm y
```
> [!NOTE]
> ⏱️ **`CreateClient` is slow (~3–4 min)** — the relayer fetches headers/validator sets from the Cosmos RPC. The recipe sets **no grpcurl timeout**, so just wait. **Do not abort and retry**: a `CreateClient` keeps running server-side for the full duration even after you disconnect, and blocks subsequent calls. The k8s port-forward survives the long request.

### 6d. Verify
```
git diff deployments/<env>/<chainId>.json
```
Only `light_clients["<idx>"].trustedClientState` and `.trustedConsensusStateHash` should change. Confirm the client state's latest height is recent.

---

## 7. Step 2 — deploy the new contract

```
just deploy-light-client      # enter the client ID, confirm "deploy a copy" with y
```
This deploys a new `SP1ICS07Tendermint` with the fresh state from step 1, **reusing** the existing vkeys + verifier, and writes the new `implementation` (and `verifier`) into the deployment JSON.

### ⚠️ Gotcha: compile against the version the client was deployed from
> [!IMPORTANT]
> `package.json` on `main` now pins `@cosmos/ibc-contracts` to a **v3** tag (`solidity-v3.0.1`) and `@openzeppelin/contracts*` to `5.6.1`, and `script/helpers/SP1ICS07TendermintDeployer.sol` imports the **SP1 v6.1** verifiers. Deploying a recovery client from this checkout produces a **v3 / SP1 v6.1** `SP1ICS07Tendermint`. That is correct only if the chain you are recovering is already on v3 / SP1 v6.1.
>
> If you are recovering a client on a **still-v2** chain, a v3 / SP1 v6.1 client will not verify proofs produced by a v2-era proof-api (vkey/verifier mismatch) and the client stays unrecoverable. Before running `just deploy-light-client`, check out the `@cosmos/ibc-contracts` (and matching `@openzeppelin/contracts*`) versions the **deployed** client was built from — confirm against the live contract per §2 — and `bun install` so `node_modules` matches that version. Older `solidity-v2.x` checkouts pinned `@openzeppelin/contracts*` to `5.4.0` because they import `ReentrancyGuardTransientUpgradeable.sol`, which OpenZeppelin removed after 5.4.0; if a v2 build fails with *"ReentrancyGuardTransientUpgradeable.sol not found"*, your `node_modules` floated past that pin — re-run `bun install` on the v2 checkout.

### Verify
```
git diff deployments/<env>/<chainId>.json    # light_clients["<idx>"].implementation -> new address
cast call <newImpl> 'getClientState()(bytes)' --rpc-url <eth-rpc>   # optional sanity check
```

---

## 8. Step 3 — migrate the client ID (timelock + Gnosis Safe)

### 8a. Confirm who holds the migrator role
`migrateClient` on the router is access-controlled. Confirm the controller chain on-chain (don't trust local source — see §2). For the testnet deployment it was: a **`TimelockController`** (`ics26Router.timelockAdmin`) fronted by a **Gnosis Safe** that holds `PROPOSER`/`EXECUTOR`/`CANCELLER`. Useful checks:
```
cast call <timelockAdmin> 'getMinDelay()(uint256)' --rpc-url <eth-rpc>            # it's a TimelockController
cast call <safe> 'getThreshold()(uint256)' --rpc-url <eth-rpc>                    # it's a Safe
# is the timelock allowed to migrate? simulate from it (should NOT revert):
cast call <router> 'migrateClient(string,(string,bytes[]),address)' <clientId> "(<cpClientId>,[<merklePrefix...>])" <newImpl> --from <timelockAdmin> --rpc-url <eth-rpc>
```
If instead an EOA holds the role, use the direct `just ops-migrate-light-client` and skip the Safe ceremony.

### 8b. The Safe address comes from the deployment JSON
`safe.just`'s `safe_address` is read from `deployments/<env>/<chain>.json` under the `.safe` key (the Safe that holds `PROPOSER` on your timelock). Make sure that key is set for the environment you are operating on, or the hash-verification recipes will fail loudly rather than computing against the wrong Safe.

### 8c. Generate, verify, submit
Run in a **real terminal** (the recipe's `forge` step uses `vm.prompt`, which needs a TTY — it can't be piped):
```
just timelock-migrate-light-client schedule <safe-nonce>     # enter client ID; prints calldata + Safe hashes
```
Read from the **"Timelock info"** block:
- `address:` — the **TimelockController** = the Safe tx **`to`**
- `timelock calldata:` — the **`schedule(...)`** calldata = the Safe tx **`data`**

and the **`safeTxHash`** from the "Safe hashes" block (for `<safe-nonce>`).

Submit the Safe tx in the **Safe UI** (custom/raw data: `to` = timelock, `value` 0, `data` = the `timelock calldata`), or via the Transaction Builder using the **TimelockController** ABI (`just copy-abi-to-clipboard TimelockController` copies it). Verify the Safe UI's safeTxHash matches, then sign + execute. Signers should independently verify via `just verify-schedule-migrate-light-client <nonce>`.

After the timelock **delay** elapses, repeat for execute:
```
just timelock-migrate-light-client execute <safe-nonce+1>
```
Submit the second Safe tx (same `to`, `data` = the `execute(...)` calldata), sign + execute. This calls `timelock.execute → router.migrateClient`, repointing the client ID.

> [!TIP]
> You can confirm the scheduled op is ready before executing:
> ```
> ID=$(cast call <timelock> 'hashOperation(address,uint256,bytes,bytes32,bytes32)(bytes32)' <router> 0 <migrateCalldata> 0x00..00 0x00..00 --rpc-url <eth-rpc>)
> cast call <timelock> 'isOperationReady(bytes32)(bool)' $ID --rpc-url <eth-rpc>   # true once delay passed
> ```
> If the recipe's `safeTxHash` line ever comes back blank (intermittent `chisel` hiccup), compute it directly: `cast keccak 0x1901<domainHash><messageHash>`.

---

## 9. Step 4 — verify & record

```
cast call <router> 'getClient(string)(address)' <clientId> --rpc-url <eth-rpc>
```
Must return the **new** implementation address. Then:
- Open a PR to `eureka-ops` updating the canonical light-client address (the `deployments/<env>/<chainId>.json` change).
- Ensure the relayer/operator that updates this client is running so it does not re-expire.

---

## 10. Key files

- `deploy.just` — `deploy-fresh-light-client-state` (proof-api), `deploy-light-client`, `timelock-migrate-light-client`.
- `safe.just` — reads the Safe from the deployment JSON (`.safe`), `get_safe_hashes`.
- `script/helpers/decode_create_client.py` — version-independent decoder for the proof-api `CreateClient` calldata.
- `script/DeploySP1ICS07Tendermint.sol`, `script/MigrateLightClient.sol`.
- `deployments/<env>/<chainId>.json` — the deployment state.
