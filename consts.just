## timelock contract signatures

GET_MIN_DELAY_SIG := "getMinDelay()(uint256)"

## IBC contract signatures

UPGRADE_TO_AND_CALL_SIG := "upgradeToAndCall(address, bytes memory)"
INITIALIZE_V2_SIG := "initializeV2(address)"
INITIALIZE_ESCROW_V2_SIG := "initializeV2()"
MIGRATE_CLIENT_V3_SIG := "migrateClient(string,(string,bytes[]),address)"
UPGRADE_IBC_ERC20_SIG := "upgradeIBCERC20To(address)"
UPGRADE_ESCROW_SIG := "upgradeEscrowTo(address)"

## foundry commands

forge_binary := "forge"
cast_binary := "cast"
chisel_binary := "chisel"
just := "just -f " + justfile()

separator := "------------------------------------------------------------------------------------"
