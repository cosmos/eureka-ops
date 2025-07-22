## RUNBOOK - Grant delegate sender role

### Runbook

1. The facilitator gathers parameters for the schedule and execute transaction proposal by calling `just timelock-grant-role schedule` and `just timelock-grant-role execute`
2. The facilitator sends signers the operation branch name.
3. Signers should run `git pull && git checkout operation/0710-grant-delegate-sender-role`.
4. The signers independently verify the schedule transaction by:
    1. Running `just verify-schedule-grant-role 16` and selecting `ICS20Transfer` for the contract with the role, and next selecting `Delegate Sender role` and finally, when prompted for the grantee address, writing in the Skip Go contract (`0x47a4b9F949E98a49Be500753c19a8f9c9d6b7689`).
    2. Verifying that the transaction contents contain the expected call
    3. Verifying that the transaction hashes match what is expected
5. The signers repeat the above process for the execute transaction, with the only different being the initial command
    1. Command: `just verify-execute-grant-role 17`
    2. Repeating the same steps as in 4.
6. The facilitator collects signatures from the signers on Gnosis Safe
    - ** (!!) The signers should verify the Tenderly simulation from the Gnosis Safe UI. They should make sure that the domainHash matches what they are seeing in the blind-signing window on their hardware wallet**
7. The facilitator submits and merges a pull request to `eureka-ops` to update the new canonical light client address. 
