## RUNBOOK - upgrading ICS26Router contract

### Roles

| Role         | Person |
|--------------|--------|
| Facilitator  |        |
| Communicator |        |
| Notekeeper   |        |

### Runbook
1. Facilitator creates a new operations report and branch by calling `just new-operation upgrade-ics-26 <environment> <chain_id>`
   1. This is going to be our canonical branch for the length of this operation
   2. The facilitator makes sure that a `.eureka-env` file got created as part of this command.
2. The facilitator sends signers the operation branch name.
3. Signers run `cd eureka-ops && just join-operation <operation_branch>`
4. Facilitator deploys a new ICS26Router contract by calling `just deploy-ics26-router`
5. Facilitator checks that the implementation address changed by running `just verify-deployment <environment> <chain_id>`
   1. If the address changed, the verification should fail
6. Signers should pull the new updates by calling `just update-operation`
7. ? Signers independently verify that the deployed bytecode matches the patched ics26 contract
8. The facilitator gathers parameters for the transaction proposal by running `just schedule-ics26-upgrade-params`
9. The facilitator submits a timelocked transaction proposal to the Gnosis Safe
9. The signers independently verify that the transaction contents contain the expected call by running `just decode-ics26-upgrade <safe_address> <nonce> schedule`
10. The facilitator collects signatures from the signers on Gnosis Safe
    - ** (!!) The signers should verify the Tenderly simulation from the Gnosis Safe UI. They should make sure that the domainHash matches what they are seeing in the blind-signing window on their hardware wallet**
    - The signers should also verify that the message, domain and safeTx hashes match with what they saw in the output of the `just decode-ics26-upgrade <safe_address> <nonce> schedule` cmomand
11. After the timelock passes, the facilitator gathers parameters for the execute transaction proposal by calling `just execute-ics26-upgrade-params`
12. The signers independently verify that the transaction contents contain the expected call by running `just decode-ics26-upgrade <safe_address> <nonce> execute`
13. The facilitator collects signatures from the signers on Gnosis Safe
    - ** (!!) The signers should verify the Tenderly simulation from the Gnosis Safe UI. They should make sure that the domainHash matches what they are seeing in the blind-signing window on their hardware wallet**
    - The signers should also verify that the message, domain and safeTx hashes match with what they saw in the output of the `just decode-ics26-upgrade <safe_address> <nonce> execute` cmomand
14. The facilitator submits and merges a pull request to `eureka-ops` to update the new canonical ICS26Router deployment address. 