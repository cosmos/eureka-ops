## RUNBOOK - Grant relayer role (new server environment)

### Runbook

1. The facilitator gathers parameters for the schedule and execute transaction proposals by calling `just timelock-grant-role schedule` and `just timelock-grant-role execute` once per relayer address (selecting `ICS26Router` → `Relayer role`).
2. The facilitator sends signers the operation branch name.
3. Signers should run `git pull && git checkout operation/1012-grant-relayer-role`, then `just _generate-script-helper`.
4. The signers independently verify each schedule transaction by:
    1. Running `just verify-schedule-grant-role 27` and selecting `ICS26Router` for the contract with the role, and next selecting `Relayer role` and finally, when prompted for the grantee address, writing in relayer #1 (Dev, `0xb658883895f832043AB47737506637CC458506F7`).
    2. Running `just verify-schedule-grant-role 28` with the same selections and relayer #2 (Prod, `0x0B7417A4491B46fb3C40134Fe6E3f7c75321f464`).
    3. Verifying that the transaction contents contain the expected call (`grantRole(uint64,address,uint32)` with args `[1, <RELAYER>, 0]` on the AccessManager)
    4. Verifying that the transaction hashes match what is expected
5. The signers repeat the above process for the execute transactions (after the 72h timelock delay), with the only difference being the initial command
    1. Commands: `just verify-execute-grant-role 29` (relayer #1) and `just verify-execute-grant-role 30` (relayer #2)
    2. Repeating the same steps as in 4.
6. The facilitator collects signatures from the signers on Gnosis Safe
    - ** (!!) The signers should verify the Tenderly simulation from the Gnosis Safe UI. They should make sure that the domainHash matches what they are seeing in the blind-signing window on their hardware wallet**
7. After execution, the facilitator verifies the grants with `cast call <access_manager> "hasRole(uint64,address)(bool,uint32)" 1 <RELAYER>` (expect `true 0`) for both addresses.
8. The facilitator submits and merges a pull request to `eureka-ops` adding both addresses to `.accessManagerRoles.relayers` in `deployments/mainnet/1.json`, then runs `python3 scripts/validate-v3-roles.py mainnet 1`.

## Relevant addresses

* Gnosis Safe - `0x7B96CD54aA750EF83ca90eA487e0bA321707559a`
* Timelock address (can be confirmed by running `just info-env`) - `0xb3999B2D30dD8c9faEcE5A8a503fAe42b8b1b614`
* AccessManager [`0x3fa3f45acE1645614c80679AeEcE0A82A93c77Ec`](https://etherscan.io/address/0x3fa3f45acE1645614c80679AeEcE0A82A93c77Ec)
* Relayer #1 (Dev) - [`0xb658883895f832043AB47737506637CC458506F7`](https://etherscan.io/address/0xb658883895f832043AB47737506637CC458506F7)
* Relayer #2 (Prod) - [`0x0B7417A4491B46fb3C40134Fe6E3f7c75321f464`](https://etherscan.io/address/0x0B7417A4491B46fb3C40134Fe6E3f7c75321f464)
* Nonces for this operation's `schedule` transactions - `27` (relayer #1), `28` (relayer #2)
* Nonces for this operation's `execute` transactions - `29` (relayer #1), `30` (relayer #2)
