## RUNBOOK - Grant relayer role (new server environment)

> Expected hashes: [`COORDINATOR-HASH-TABLE.md`](./COORDINATOR-HASH-TABLE.md)

Grants v3 `AccessManager` `RELAYER_ROLE` (`1`) to two new relayer EOAs via Safe → TimelockController (72h).
Requested by the Cosmos Labs Korea App team to add relayers for its new infrastructure. This is additive: **the four existing relayers keep their role** and are not touched.

### Relayer keys

| # | Env | Address | Owner (team / service) | Request | Ownership proof |
|---|-----|---------|------------------------|---------|-----------------|
| 1 | Dev | `0xb658883895f832043AB47737506637CC458506F7` | Cosmos Labs Korea App team / relayer for the new infrastructure (dev) | [Slack thread](https://cosmoslabskr.slack.com/archives/C0BS6MSQVA5/p1786093064411839?thread_ts=1785815284.268649&cid=C0BS6MSQVA5) | Signed message, verified (below) |
| 2 | Prod | `0x0B7417A4491B46fb3C40134Fe6E3f7c75321f464` | Cosmos Labs Korea App team / relayer for the new infrastructure (prod) | [Slack thread](https://cosmoslabskr.slack.com/archives/C0BS6MSQVA5/p1786093064411839?thread_ts=1785815284.268649&cid=C0BS6MSQVA5) | Signed message, verified (below) |

- Each key owner signed `eureka-ops grant-relayer-role 2026-10-12` (EIP-191) out-of-band; the facilitator verified both on 2026-10-14 (`Validation succeeded`). Anyone can re-check:
  ```bash
  cast wallet verify --address 0xb658883895f832043AB47737506637CC458506F7 "eureka-ops grant-relayer-role 2026-10-12" \
    0x3926cc5974139d04f4cf94ed62c9a0e3827f8ca3176ab73790fe205800fcd8707a776d1a5037c561a12ee4fb86d182453bb48b21b64aafdca7082ed80048bb341c
  cast wallet verify --address 0x0B7417A4491B46fb3C40134Fe6E3f7c75321f464 "eureka-ops grant-relayer-role 2026-10-12" \
    0xa0bdccd0ee7146d35765e5d21e8bceae571fae3bfbd9c3e1396170c413bb98ff0d2de5bb441e2b64ad4e4eee9be81f5ec992d9b8b096e185455034a4b46d7ef71b
  ```
- The Prod key has never transacted (nonce 0) and holds no ETH as of 2026-10-12. The App team funds it before the relayer is brought up.

### Signer setup

Signers need `.eureka-env` pointing at mainnet (`EUREKA_ENVIRONMENT=mainnet`, `EUREKA_CHAIN=1`, `ETH_RPC`). The verify recipes fail without it. See [`runbooks/env-setup.md`](../../env-setup.md).

### Preconditions

Before proposing the schedules (nonces 27, 28):
- Safe `nonce()` is `27` and the Safe transaction queue is empty.
  ```bash
  cast call 0x7B96CD54aA750EF83ca90eA487e0bA321707559a "nonce()(uint256)" --rpc-url $ETH_RPC   # 27
  ```
- Neither relayer holds role 1 yet (`hasRole` → `false 0`).
- The operation branch is pushed to `cosmos/eureka-ops` (signers pull it from there).

Before signing the executes (nonces 29, 30), re-check both ops; the Safe holds CANCELLER, so do not assume they are still pending:
```bash
TL=0xb3999B2D30dD8c9faEcE5A8a503fAe42b8b1b614
cast call $TL "isOperationReady(bytes32)(bool)" 0x38e2d20dc64fd8246e64bbf86e884340b35b7555884b057863392f20f9479c86 --rpc-url $ETH_RPC   # Dev: true
cast call $TL "isOperationReady(bytes32)(bool)" 0x651d39c3bfa5e3e3b785f5e6ff4c848f903f4306c621a76f727afcb21a3e8407 --rpc-url $ETH_RPC   # Prod: true
```

### Runbook

1. The facilitator gathers parameters for the schedule and execute transaction proposals by calling `just timelock-grant-role schedule` and `just timelock-grant-role execute` once per relayer address (selecting `ICS26Router` → `Relayer role`).
2. The facilitator sends signers the operation branch name.
3. Signers should run `git pull && git checkout operation/1012-grant-relayer-role`, then `just _generate-script-helper`.
4. The signers independently verify each schedule transaction by:
    1. Running `just verify-schedule-grant-role 27` and selecting `ICS26Router` for the contract with the role, and next selecting `Relayer role` and finally, when prompted for the grantee address, writing in relayer #1 (Dev, `0xb658883895f832043AB47737506637CC458506F7`).
    2. Running `just verify-schedule-grant-role 28` with the same selections and relayer #2 (Prod, `0x0B7417A4491B46fb3C40134Fe6E3f7c75321f464`).
    3. Verifying that the transaction contents contain the expected call (`grantRole(uint64,address,uint32)` with args `[1, <RELAYER>, 0]` on the AccessManager)
    4. Verifying that the transaction hashes match [`COORDINATOR-HASH-TABLE.md`](./COORDINATOR-HASH-TABLE.md), and checking offline:
       ```bash
       bash scripts/signer-verify.sh <nonce> --table runbooks/operations/2026-10-12-grant-relayer-role/COORDINATOR-HASH-TABLE.md
       ```
5. The schedules are executed once they reach threshold. The 72h delay starts at the schedule execution block.
6. **After the 72h delay**, and after the `isOperationReady` precondition above passes, the signers repeat the above process for the execute transactions, with the only difference being the initial command
    1. Commands: `just verify-execute-grant-role 29` (relayer #1) and `just verify-execute-grant-role 30` (relayer #2)
    2. Repeating the same steps as in 4.
7. The facilitator collects signatures from the signers on Gnosis Safe
    - ** (!!) The signers should verify the Tenderly simulation from the Gnosis Safe UI. They should make sure that the domainHash (`0xcd4a05648a591f364a67b3bfbe2d94da94158225e8137df3cd869dc877fcaa67`) matches what they are seeing in the blind-signing window on their hardware wallet**
8. After execution, the facilitator verifies the grants with `cast call <access_manager> "hasRole(uint64,address)(bool,uint32)" 1 <RELAYER>` (expect `true 0`) for both addresses.
9. The facilitator submits and merges a pull request to `eureka-ops` that:
    - adds both addresses to **both** relayer lists in `deployments/mainnet/1.json`: `.accessManagerRoles.relayers` and `.ics26Router.relayers` (the Solidity helpers read the latter as a fallback);
    - adds a `RECORD.md` in this folder with the schedule/execute tx hashes.

   Then runs the role validation (requires an RPC):
   ```bash
   ETH_RPC=$ETH_RPC python3 scripts/validate-v3-roles.py mainnet 1
   ```

### Rollback

- Wrong address found after schedule, before execute: the Safe cancels the op with timelock `cancel(bytes32 id)` (Safe holds CANCELLER).
- Revoke after execution (e.g. key compromise): `just timelock-revoke-role schedule|execute`, the same Safe → timelock flow, also 72h. For an emergency during that window, see [`runbooks/pause.md`](../../pause.md).

## Relevant addresses

* Gnosis Safe - `0x7B96CD54aA750EF83ca90eA487e0bA321707559a` (threshold 4 of 7)
* Timelock address (can be confirmed by running `just info-env`) - `0xb3999B2D30dD8c9faEcE5A8a503fAe42b8b1b614`
* AccessManager [`0x3fa3f45acE1645614c80679AeEcE0A82A93c77Ec`](https://etherscan.io/address/0x3fa3f45acE1645614c80679AeEcE0A82A93c77Ec)
* Relayer #1 (Dev) - [`0xb658883895f832043AB47737506637CC458506F7`](https://etherscan.io/address/0xb658883895f832043AB47737506637CC458506F7)
* Relayer #2 (Prod) - [`0x0B7417A4491B46fb3C40134Fe6E3f7c75321f464`](https://etherscan.io/address/0x0B7417A4491B46fb3C40134Fe6E3f7c75321f464)
* Nonces for this operation's `schedule` transactions - `27` (relayer #1), `28` (relayer #2)
* Nonces for this operation's `execute` transactions - `29` (relayer #1), `30` (relayer #2)
* Timelock operation ids (predecessor 0, salt 0) - Dev `0x38e2d20dc64fd8246e64bbf86e884340b35b7555884b057863392f20f9479c86`, Prod `0x651d39c3bfa5e3e3b785f5e6ff4c848f903f4306c621a76f727afcb21a3e8407`
