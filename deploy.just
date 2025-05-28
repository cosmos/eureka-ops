_private_key_not_set := "PRIVATE_KEY-NOT-SET"

environment := env_var_or_default("EUREKA_ENVIRONMENT", "")
chain := env_var_or_default("EUREKA_CHAIN", "")
sender := env_var_or_default("SENDER", "")
eth_rpc := env_var_or_default("ETH_RPC", "")
private_key := env_var_or_default("PRIVATE_KEY", _private_key_not_set)
wallet := if private_key !=  _private_key_not_set { "--private-key " + private_key } else { "--ledger --sender " + sender }
_timelock_controller := shell('jq -r ".ics26Router.timelockAdmin" deployments/$1/$2.json', environment, chain)

_verify_flags  := "--verify --retries 10 --delay 10"
_broadcast_flags := "--broadcast " + _verify_flags + " " + wallet
_timelock_flags := "--sender " + _timelock_controller

export FOUNDRY_ETH_RPC_URL := eth_rpc
export DEPLOYMENT_ENV := environment
export FZF_DEFAULT_OPTS := "--height=40%"

[group('info')]
info-env:
    #!/bin/bash
    set -eou pipefail
    solidity_ver=$(jq -r ".dependencies[\"@cosmos/solidity-ibc-eureka\"]" package.json)
    echo "Basic Environment Settings:"
    echo "Eureka Environment: {{environment}}"
    echo "Chain: {{chain}}"
    echo "Ethereum RPC: {{eth_rpc}}"
    echo
    echo "Deployment Settings:"
    echo "IBC Solidity Contracts Version: ${solidity_ver}"
    echo "TimeLock Controller: {{_timelock_controller}}"
    echo "Broadcast Flags: {{_broadcast_flags}}" | sed -e "s/{{private_key}}/***REDACTED***/g"
    echo "Timelock Flags: {{_timelock_flags}}"

[group('info')]
info-admin: _generate-script-helper
    #!/bin/bash
    set -eou pipefail
    is_timelock=$(jq -r ".settings.admin_is_timelock_controller" out/scriptHelper.json)
    echo "Admin Information for {{environment}} on {{chain}}:"
    echo "Admin address (ics26Router.timelockAdmin): {{_timelock_controller}}"
    echo "Admin is Timelock Controller script: $is_timelock"

[group('info')]
info-timelock:
    #!/bin/bash
    set -euo pipefail
    echo "Basic Timelock Information for schedule and execute:"
    echo "Address/To: {{_timelock_controller}}"
    echo "ETH value: 0"
    echo "Target: 'to' from timelock script output"
    echo "Value: 0"
    echo "Data: 'input' from timelock script output"
    echo "Predecessor: 0x"
    echo "Salt: 0x"
    echo "Delay: $(jq -r ".settings.timelock_delay" out/scriptHelper.json)"
    just copy-abi-to-clipboard "TimelockController"


_clean-and-build: && _generate-script-helper
    #!/bin/bash
    set -eou pipefail
    echo "Cleaning up..."
    bun install
    forge clean
    forge build

_confirm-settings script_flags:
    #!/bin/bash
    set -eou pipefail
    echo "You are about to run a script with the following settings:"
    just info-env
    echo
    echo "Script flags to be used: {{script_flags}}"
    echo
    read -p "Please confirm: (y/n) " -n 1 -r
    echo    # (optional) move to a new line
    if [[ ! $REPLY =~ ^[Yy]$ ]]
    then
        echo "User did not confirm. Aborting deployment!"
        exit 1
    fi

_pre-script script_flags: _clean-and-build (_confirm-settings script_flags)
    #!/bin/bash
    set -eou pipefail
    echo "Pre-script checks completed. Proceeding with script execution..."
    echo "Script flags: {{script_flags}}"

# Generate user input JSON file that can be used for fzf selection
_generate-script-helper:
    #!/bin/bash
    set -eou pipefail
    forge script script/GenerateScriptHelperJSON.sol:GenerateScriptHelperJSON

test-generate-script-helper: _clean-and-build _generate-script-helper
    #!/bin/bash
    set -euo pipefail
    jq "." out/scriptHelper.json

[group('deploy')]
print-abi: _clean-and-build
    #!/bin/bash
    set -eou pipefail
    contract_file_name=$(ls out | fzf)
    contract_name=${contract_file_name%".sol"}
    abi=$(jq ".abi" out/$contract_file_name/$contract_name.json)
    echo "Printing ABI for ${contract_name}..."
    echo ""
    echo $abi
    just copy-abi-to-clipboard $contract_name

copy-abi-to-clipboard contract_name:
    #!/bin/bash
    set -eou pipefail
    abi=$(jq ".abi" out/{{contract_name}}.sol/{{contract_name}}.json)
    if command -v pbcopy > /dev/null 2>&1; then
        echo $abi | pbcopy
        echo "ABI copied to clipboard (to print, you can also run 'just print-abi')."
    else
        echo "pbcopy command not found. Cannot copy ABI to clipboard."
    fi



[group('verify')]
[doc('Verifies contract deployments in <environment>')]
verify-deployment:
    #!/bin/bash
    set -eou pipefail
    export VERIFY_ONLY=true
    forge script script/DeployProxiedICS26Router.sol
    forge script script/DeployProxiedICS20Transfer.sol
    forge script script/DeploySP1ICS07Tendermint.sol

# TODO: Consider splitting up the scripts between deploy, timelock stuff and operations
# Maybe split by role (e.g. who runs the script, or rather what "hat" they are wearing when running the script)

# Deploy scripts signed and broadcasted locally

[group('deploy')]
deploy-implementation: _generate-script-helper (_pre-script _broadcast_flags)
    #!/bin/bash
    set -euo pipefail
    export LOGIC_CONTRACT=$(jq -r ".implementations[]" out/scriptHelper.json | fzf)
    forge script script/DeployImplementation.sol -vvvv {{_broadcast_flags}}
    echo "Take note of the implementation address above, and replace it in the deployment json file if you are planning to upgrade"

[group('deploy')]
deploy-timelock-controller: (_pre-script _broadcast_flags)
    #!/bin/bash
    set -euo pipefail
    forge script script/DeployTimelockController.sol -vvvv {{_broadcast_flags}}

[group('deploy')]
deploy-ics26-router: (_pre-script _broadcast_flags)
    #!/bin/bash
    set -euo pipefail
    forge script script/DeployProxiedICS26Router.sol -vvvv {{_broadcast_flags}}

[group('deploy')]
deploy-ics20-transfer: (_pre-script _broadcast_flags)
    #!/bin/bash
    set -euo pipefail
    forge script script/DeployProxiedICS20Transfer.sol -vvvv {{_broadcast_flags}}

[group('deploy')]
deploy-light-client: (_pre-script _broadcast_flags)
    #!/bin/bash
    set -euo pipefail
    forge script script/DeploySP1ICS07Tendermint.sol -vvvv {{_broadcast_flags}}

[group('deploy')]
deploy-relayer-helper: (_pre-script _broadcast_flags)
    #!/bin/bash
    set -euo pipefail
    forge script script/DeployRelayerHelper.sol -vvvv {{_broadcast_flags}}

[group('timelock')]
deploy-replace-timelock-admin: (_pre-script _broadcast_flags)
    #!/bin/bash
    set -euo pipefail
    forge script script/ReplaceTimelockAdmin.sol -vvvv {{_broadcast_flags}}

[group('deploy')]
deploy-ibcerc20: (_pre-script _broadcast_flags)
    #!/bin/bash
    set -euo pipefail
    forge script script/DeployIBCERC20.sol -vvvv {{_broadcast_flags}}

# Operation scripts signed and broadcasted locally

# TODO: Extract all of these into private recipes, and create both ops and timelock versions
[group('ops')]
ops-grant-rate-limiter-role: (_pre-script _broadcast_flags)
    #!/bin/bash
    set -euo pipefail
    forge script script/GrantRateLimiterRole.sol -vvvv {{_broadcast_flags}}

[group('ops')]
ops-grant-metadata-role: (_pre-script _broadcast_flags)
    #!/bin/bash
    set -euo pipefail
    forge script script/GrantMetadataRole.sol -vvvv {{_broadcast_flags}}

[group('ops')]
ops-revoke-metadata-role: (_pre-script _broadcast_flags)
    #!/bin/bash
    set -euo pipefail
    forge script script/RevokeMetadataRole.sol -vvvv {{_broadcast_flags}}

[group('ops')]
ops-set-metadata: (_pre-script _broadcast_flags)
    #!/bin/bash
    set -euo pipefail
    forge script script/SetTokenMetadata.sol -vvvv {{_broadcast_flags}}

[group('ops')]
ops-grant-role: _generate-script-helper (_pre-script _broadcast_flags) (_grant-role _broadcast_flags)

_grant-role script_flags:
    #!/bin/bash
    set -euo pipefail
    contract=$(jq -r ".deployments | keys[]" out/scriptHelper.json | fzf --header="Select contract with the role you want to grant")
    export GRANT_CONTRACT_ADDRESS=$(jq -r ".deployments.[\"$contract\"].contract_address" out/scriptHelper.json)
    role_key=$(jq -r ".deployments.[\"$contract\"].roles | keys[]" out/scriptHelper.json | fzf --header="Select role you wish to grant")
    export GRANT_ROLE=$(jq -r ".deployments.[\"$contract\"].roles[\"$role_key\"]" out/scriptHelper.json)
    echo "Granting role $role_key ($GRANT_ROLE) on $contract ($GRANT_CONTRACT_ADDRESS)"
    forge script script/GrantRole.sol -vvvv {{script_flags}}


[group('ops')]
ops-revoke-role: _generate-script-helper (_pre-script _broadcast_flags)
    #!/bin/bash
    set -euo pipefail
    contract=$(jq -r ".deployments | keys[]" out/scriptHelper.json | fzf)
    export REVOKE_CONTRACT_ADDRESS=$(jq -r ".deployments.[\"$contract\"].contract_address" out/scriptHelper.json)
    role_key=$(jq -r ".deployments[\"$contract\"].roles | keys[]" out/scriptHelper.json | fzf)
    export REVOKE_ROLE=$(jq -r "deployments.[\"$contract\"].roles[\"$role_key\"]" out/scriptHelper.json)
    echo "Revoking role $role_key ($REVOKE_ROLE) on $contract ($REVOKE_CONTRACT_ADDRESS)"
    forge script script/RevokeRole.sol -vvvv {{_broadcast_flags}}


# Timelock scripts signed and broadcasted by the timelock controller

_post-timelock: info-timelock
    #!/bin/bash
    set -euo pipefail
    echo
    echo "Dry run of the transaction has been completed."
    echo "You can now post the transaction to the safe multisig with schedule, and later execute the timelock."
    echo
    echo "You can find the basic timelock input above."
    echo "For the transaction information, use the dry-run output above that to find the necessary information:"
    echo "to = target"
    echo "input = data"

[group('timelock')]
timelock-grant-rate-limiter-role: (_pre-script _timelock_flags) && _post-timelock
    #!/bin/bash
    set -euo pipefail
    forge script script/GrantRateLimiterRole.sol -vvvv {{_timelock_flags}}


[group('timelock')]
timelock-upgrade-proxy: (_pre-script _timelock_flags) && _post-timelock
    #!/bin/bash
    set -euo pipefail
    forge script script/UpgradeProxy.sol -vvvv {{_timelock_flags}}

[group('timelock')]
timelock-migrate-light-client: (_pre-script _timelock_flags) && _post-timelock
    #!/bin/bash
    set -euo pipefail
    forge script script/MigrateLightClient.sol -vvvv {{_timelock_flags}}

[group('timelock')]
timelock-replace-timelock-admin: (_pre-script _timelock_flags) && _post-timelock
    #!/bin/bash
    set -euo pipefail
    forge script script/ReplaceTimelockAdmin.sol -vvvv {{_timelock_flags}}

[group('timelock')]
timelock-grant-role: _generate-script-helper (_pre-script _timelock_flags) (_grant-role _timelock_flags) && _post-timelock

