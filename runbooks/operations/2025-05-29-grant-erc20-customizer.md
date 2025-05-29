## RUNBOOK - upgrading ICS26Router contract

### Runbook
1. The facilitator sends signers the operation branch name.
2. Signers should run `git pull && git checkout operation/0529-erc20-customizer`.
3. The signers independently verify that the transaction contents contain the expected call by running `cast calldata "grantERC20CustomizerRole(address)" <ops_council_address>`. 
4. The signers should generate the timelock calldata using `cast calldata "schedule(address,uint256,bytes,bytes32,bytes32,uint256)" <ics20transfer_proxy> 0 <calldata_from_step_3> 0x 0x 259200`
5. The signers independently verify that the transaction hashes match what is expected on their hardware wallets by running `just get_safe_hashes <safe_address> <nonce> <timelock_calldata_step4> <timelock_address>`
6. The facilitator collects signatures from the signers on Gnosis Safe
    - ** (!!) The signers should verify the Tenderly simulation from the Gnosis Safe UI. They should make sure that the domainHash matches what they are seeing in the blind-signing window on their hardware wallet**
7. The facilitator submits and merges a pull request to `eureka-ops` to update the new canonical ICS26Transfer deployment address. 

## Relevant addresses

* Gnosis Safe - `0x7B96CD54aA750EF83ca90eA487e0bA321707559a`
* Timelock address (can be confirmed by running `just info-env`) - `0xb3999B2D30dD8c9faEcE5A8a503fAe42b8b1b614`
* ICS20TransferProxy [`0xa348CfE719B63151F228e3C30EB424BA5a983012`](https://etherscan.io/address/0xa348CfE719B63151F228e3C30EB424BA5a983012)
* Operational Council Gnosis Safe [`0x4b46ea82D80825CA5640301f47C035942e6D9A46`](https://etherscan.io/address/0x4b46ea82D80825CA5640301f47C035942e6D9A46)
* Nonce for this specific operation - `4`