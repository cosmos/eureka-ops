## RUNBOOK - upgrading light client

### Runbook

1. The facilitator gathers parameters for the schedule transaction proposal by calling `just timelock-migrate-light-client schedule`
2. The facilitator sends signers the operation branch name.
3. Signers should run `git pull && git checkout operation/0610-upgrade-cosmoshub-lc`.
4. The signers independently verify the schedule transaction by:
    1. Running `just verify-schedule-migrate-light-client 8` and providing the client ID (`cosmoshub-0`) to be upgraded when prompted.
    2. Verifying that the transaction contents contain the expected call
    3. Verifying that the transaction hashes match what is expected
5. The facilitator collects signatures from the signers on Gnosis Safe
    - ** (!!) The signers should verify the Tenderly simulation from the Gnosis Safe UI. They should make sure that the domainHash matches what they are seeing in the blind-signing window on their hardware wallet**
6. After the timelock passes, the facilitator gathers parameters for the execute transaction proposal by calling `just timelock-migrate-light-client execute`
7. The signers independently verify the schedule transaction by:
    1. Running `just verify-execute-migrate-light-client 10` and providing the client ID (`cosmoshub-0`) to be upgraded when prompted.
    2. Verifying that the transaction contents contain the expected call
    3. Verifying that the transaction hashes match what is expected
8. The facilitator collects signatures from the signers on Gnosis Safe
    - ** (!!) The signers should verify the Tenderly simulation from the Gnosis Safe UI. They should make sure that the domainHash matches what they are seeing in the blind-signing window on their hardware wallet**
11. The facilitator submits and merges a pull request to `eureka-ops` to update the new canonical light client address. 
