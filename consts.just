## timelock contract signatures

GET_MIN_DELAY_SIG := "getMinDelay()(uint256)"

## IBC contract signatures

UPGRADE_TO_AND_CALL_SIG := "upgradeToAndCall(address, bytes memory)"
MIGRATE_CLIENT_SIG := "migrateClient(string calldata,string calldata)"
UPGRADE_IBC_ERC20_SIG := "upgradeIBCERC20To(address)"
UPGRADE_ESCROW_SIG := "upgradeEscrowTo(address)"

## foundry commands

forge_binary := "forge"
cast_binary := "cast"
chisel_binary := "chisel"
just := "just -f " + justfile()

separator := "------------------------------------------------------------------------------------"

