## RUNBOOK - upgrading light client

### Roles

| Role         | Person |
|--------------|--------|
| Facilitator  |        |
| Communicator |        |
| Notekeeper   |        |
| Signers      |        |

### Runbook

1. Facilitator creates a new operations report and branch by calling `just new-operation upgrade-light-client <environment> <chain_id>`
   1. This is going to be our canonical branch for the length of this operation
   2. The facilitator makes sure that a `.eureka-env` file got created as part of this command.
2. The facilitator sends signers the operation branch name.
3. Signers run `cd eureka-ops && just join-operation <operation_branch>`
4. Facilitator creates a new light client entry by calling `just new-light-client`
5. Facilitator fetches the parameters for the new light client using the `operator` CLI
6. Facilitator puts the values into the `deployments/<environment>/<chain_id>.json` file.
7. Facilitator deploys the light clients by calling `just deploy-light-client`
8. Signers should pull the new updates by calling `just update-operation`
9. ? Signers independently verify that the deployed bytecode matches the patched light client contract
10. The facilitator gathers parameters for the transaction proposal by running `just schedule-light-client-upgrade-params`
11. The facilitator submits a timelocked transaction proposal to the Gnosis Safe
12. The signers independently verify that the transaction contents contain the expected call by running `just decode-light-client-upgrade <safe_address> <nonce> schedule`
13. The facilitator collects signatures from the signers on Gnosis Safe
    - ** (!!) The signers should verify the Tenderly simulation from the Gnosis Safe UI. They should make sure that the domainHash matches what they are seeing in the blind-signing window on their hardware wallet**
    - The signers should also verify that the message, domain and safeTx hashes match with what they saw in the output of the `just decode-light-client-upgrade <safe_address> <nonce> schedule` cmomand
14. After the timelock passes, the facilitator gathers parameters for the execute transaction proposal by calling `just execute-light-client-upgrade-params`
15. The signers independently verify that the transaction contents contain the expected call by running `just decode-light-client-upgrade <safe_address> <nonce> execute`
16. The facilitator collects signatures from the signers on Gnosis Safe
    - ** (!!) The signers should verify the Tenderly simulation from the Gnosis Safe UI. They should make sure that the domainHash matches what they are seeing in the blind-signing window on their hardware wallet**
    - The signers should also verify that the message, domain and safeTx hashes match with what they saw in the output of the `just decode-light-client-upgrade <safe_address> <nonce> execute` cmomand
17. The facilitator submits and merges a pull request to `eureka-ops` to update the new canonical Escrow deployment address. 