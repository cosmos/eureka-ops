## RUNBOOK - upgrading IBCERC20 contract

### Roles

| Role         | Person |
|--------------|--------|
| Facilitator  |        |
| Communicator |        |
| Notekeeper   |        |

### Runbook
1. Facilitator creates a new operations report and branch by calling `just new-operation upgrade-ibcerc20 <environment> <chain_id>`
   1. This is going to be our canonical branch for the length of this operation
   2. The facilitator makes sure that a `.eureka-env` file got created as part of this command.
2. The facilitator sends signers the operation branch name.
3. Signers run `cd eureka-ops && just join-operation <operation_branch>`
4. Facilitator deploys a new IBCERC20 contract by calling `just deploy-implementation` and selecting IBCERC20
5. Facilitator updates implementation address in the `deployments/<environment>/<chain>.json` and runs `just verify-deployment <environment> <chain_id>`
   1. If the address changed, the verification should fail
6. Signers should pull the new updates by calling `just update-operation`
7. ? Signers independently verify that the deployed bytecode matches the patched IBCERC20 contract
8. The facilitator gathers parameters for the transaction proposal by running `just schedule-ibcerc20-upgrade-params <nonce>`
9. The facilitator submits a timelocked transaction proposal to the Gnosis Safe
10. The signers independently verify that the transaction contents contain the expected call by re-running `just schedule-ibcerc20-upgrade-params <nonce>`, and that the transaction hashes match what they see on their hardware wallet by running `just get_safe_hashes <nonce> <timelock_calldata> <timelock_address>` (the Safe comes from `.safe` in the deployment JSON; `<timelock_address>` is `.accessManagerRoles.admin`)
11. The facilitator collects signatures from the signers on Gnosis Safe
    - ** (!!) The signers should verify the Tenderly simulation from the Gnosis Safe UI. They should make sure that the domainHash matches what they are seeing in the blind-signing window on their hardware wallet**
    - The signers should also verify that the message, domain and safeTx hashes match with what they saw in the `just get_safe_hashes …` output
12. After the timelock passes, the facilitator gathers parameters for the execute transaction proposal by calling `just execute-ibcerc20-upgrade-params <nonce>`
13. The signers independently verify the execute call the same way: re-run `just execute-ibcerc20-upgrade-params <nonce>` and `just get_safe_hashes <nonce> <timelock_calldata> <timelock_address>`
14. The facilitator collects signatures from the signers on Gnosis Safe
    - ** (!!) The signers should verify the Tenderly simulation from the Gnosis Safe UI. They should make sure that the domainHash matches what they are seeing in the blind-signing window on their hardware wallet**
    - The signers should also verify that the message, domain and safeTx hashes match with what they saw in the `just get_safe_hashes …` output
15. The facilitator submits and merges a pull request to `eureka-ops` to update the new canonical ibcerc20 deployment address. 
