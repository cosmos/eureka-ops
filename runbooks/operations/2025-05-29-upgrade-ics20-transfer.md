## RUNBOOK - upgrading ICS20Transfer contract

### Runbook
1. The facilitator sends signers the operation branch name.
2. Facilitator updates implementation address in the `deployments/<environment>/<chain>.json` and runs `just verify-deployment <environment> <chain_id>`
   1. If the address changed, the verification should fail
3. Signers should run `git pull && git checkout operation/0529-ics20transfer`.
4. The signers independently verify that the transaction contents contain the expected call by running `just schedule-ics20transfer-upgrade-params`. 
5. The signers independently verify that the transaction hashes match what is expected on their hardware wallets by running `just get_safe_hashes <safe_address> <nonce> <timelock_calldata_step3> <timelock_address>`
6. The facilitator collects signatures from the signers on Gnosis Safe
    - ** (!!) The signers should verify the Tenderly simulation from the Gnosis Safe UI. They should make sure that the domainHash matches what they are seeing in the blind-signing window on their hardware wallet**
7. After the timelock passes, the facilitator gathers parameters for the execute transaction proposal by calling `just timelock-upgrade-proxy`
8. The signers independently verify that the transaction contents contain the expected call by running `just schedule-ics20transfer-upgrade-params`. 
9. The signers independently verify that the transaction hashes match what is expected on their hardware wallets by running `just get_safe_hashes <safe_address> <nonce> <timelock_calldata_step3> <timelock_address>`
10. The facilitator collects signatures from the signers on Gnosis Safe
    - ** (!!) The signers should verify the Tenderly simulation from the Gnosis Safe UI. They should make sure that the domainHash matches what they are seeing in the blind-signing window on their hardware wallet**
11. The facilitator submits and merges a pull request to `eureka-ops` to update the new canonical ICS20Transfer deployment address. 


## Relevant addresses

* Gnosis Safe - `0x7B96CD54aA750EF83ca90eA487e0bA321707559a`
* Timelock address (can be confirmed by running `just info-env`) - `0xb3999B2D30dD8c9faEcE5A8a503fAe42b8b1b614`
* New ICS20Transfer implementation [`0x4658c167824c000ea93d62f15b5c9bb53ee329fe`](https://etherscan.io/0x4658c167824c000ea93d62f15b5c9bb53ee329fe)
* Nonce for this specific operation - `2`