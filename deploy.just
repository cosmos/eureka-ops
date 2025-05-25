_private_key_not_set := "PRIVATE_KEY-NOT-SET"

environment := env_var_or_default("EUREKA_ENVIRONMENT", "")
chain := env_var_or_default("EUREKA_CHAIN", "")
sender := env_var_or_default("SENDER", "")
eth_rpc := env_var_or_default("ETH_RPC", "")
private_key := env_var_or_default("PRIVATE_KEY", _private_key_not_set)
wallet := if private_key !=  _private_key_not_set { "--private-key " + private_key } else { "--ledger --sender " + sender }
timelock_controller := shell('jq -r ".ics26Router.timelockAdmin" deployments/$1/$2.json', environment, chain)

broadcast_flags := "--broadcast --verify " + wallet
timelock_flags := "--sender " + timelock_controller

export FOUNDRY_ETH_RPC_URL := eth_rpc
export DEPLOYMENT_ENV := environment

env-info:
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
    echo "TimeLock Controller: {{timelock_controller}}"
    echo "Broadcast Flags: {{broadcast_flags}}" | sed -e "s/{{private_key}}/***REDACTED***/g"
    echo "Timelock Flags: {{timelock_flags}}"

admin-info: _generate-script-helper
    #!/bin/bash
    set -eou pipefail
    is_timelock=$(jq -r ".settings.admin_is_timelock_controller" out/scriptHelper.json)
    echo "Admin Information for {{environment}} on {{chain}}:"
    echo "Admin address (ics26Router.timelockAdmin): {{timelock_controller}}"
    echo "Admin is Timelock Controller script: $is_timelock"

_clean-and-build: && _generate-script-helper
    #!/bin/bash
    set -eou pipefail
    echo "Cleaning up..."
    bun install
    forge clean
    forge build

_confirm-settings:
    #!/bin/bash
    set -eou pipefail
    echo "You are about to run a script with the following settings:"
    just env-info
    read -p "Please confirm: (y/n) " -n 1 -r
    echo    # (optional) move to a new line
    if [[ ! $REPLY =~ ^[Yy]$ ]]
    then
        echo "User did not confirm. Aborting deployment!"
        exit 1
    fi

_pre-deploy: _clean-and-build _confirm-settings

_post-timelock:
    #!/bin/bash
    echo "Dry run of the transaction has been completed."
    echo "You can now post the transaction to the safe multisig to schedule, and later execute the timelock."

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
    export FZF_DEFAULT_OPTS="--height=40%"
    contract=$(ls out | fzf)
    contract_name=${contract%".sol"}
    abi=$(jq ".abi" out/$contract/$contract_name.json)
    echo "Printing ABI for $contract_name"
    echo ""
    echo $abi
    if command -v pbcopy > /dev/null 2>&1; then
        echo $abi | pbcopy
        echo "ABI also copied to clipboard"
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
deploy-implementation: _pre-deploy _generate-script-helper
    #!/bin/bash
    set -euo pipefail
    export LOGIC_CONTRACT=$(jq -r ".implementations[]" out/scriptHelper.json | fzf)
    forge script script/DeployImplementation.sol -vvvv {{broadcast_flags}}
    echo "Take note of the implementation address above, and replace it in the deployment json file if you are planning to upgrade"

[group('deploy')]
deploy-timelock-controller: _pre-deploy
    #!/bin/bash
    set -euo pipefail
    forge script script/DeployTimelockController.sol -vvvv {{broadcast_flags}}

[group('deploy')]
deploy-ics26-router: _pre-deploy
    #!/bin/bash
    set -euo pipefail
    forge script script/DeployProxiedICS26Router.sol -vvvv {{broadcast_flags}}

[group('deploy')]
deploy-ics20-transfer: _pre-deploy
    #!/bin/bash
    set -euo pipefail
    forge script script/DeployProxiedICS20Transfer.sol -vvvv {{broadcast_flags}}

[group('deploy')]
deploy-light-client: _pre-deploy
    #!/bin/bash
    set -euo pipefail
    forge script script/DeploySP1ICS07Tendermint.sol -vvvv {{broadcast_flags}}

[group('deploy')]
deploy-relayer-helper: _pre-deploy
    #!/bin/bash
    set -euo pipefail
    forge script script/DeployRelayerHelper.sol -vvvv {{broadcast_flags}}

[group('timelock')]
deploy-replace-timelock-admin: _pre-deploy
    #!/bin/bash
    set -euo pipefail
    forge script script/ReplaceTimelockAdmin.sol -vvvv {{broadcast_flags}}

# Operation scripts signed and broadcasted locally

[group('ops')]
ops-grant-metadata-role: _pre-deploy
    #!/bin/bash
    set -euo pipefail
    forge script script/GrantMetadataRole.sol -vvvv {{broadcast_flags}}

[group('ops')]
ops-revoke-metadata-role: _pre-deploy
    #!/bin/bash
    set -euo pipefail
    forge script script/RevokeMetadataRole.sol -vvvv {{broadcast_flags}}

[group('ops')]
ops-set-metadata: _pre-deploy
    #!/bin/bash
    set -euo pipefail
    forge script script/SetTokenMetadata.sol -vvvv {{broadcast_flags}}

[group('ops')]
ops-grant-role: _pre-deploy _generate-script-helper
    #!/bin/bash
    set -euo pipefail
    export FZF_DEFAULT_OPTS="--height=40%"
    contract=$(jq -r ". | keys[]" out/scriptHelper.json | fzf)
    export GRANT_CONTRACT_ADDRESS=$(jq -r ".[\"$contract\"].contract_address" out/scriptHelper.json)
    role_key=$(jq -r ".[\"$contract\"].roles | keys[]" out/scriptHelper.json | fzf)
    export GRANT_ROLE=$(jq -r ".[\"$contract\"].roles[\"$role_key\"]" out/scriptHelper.json)
    echo "Granting role $role_key ($GRANT_ROLE) on $contract ($GRANT_CONTRACT_ADDRESS)"
    forge script script/GrantRole.sol -vvvv {{broadcast_flags}}

[group('ops')]
ops-revoke-role: _pre-deploy _generate-script-helper
    #!/bin/bash
    set -euo pipefail
    export FZF_DEFAULT_OPTS="--height=40%"
    contract=$(jq -r ". | keys[]" out/scriptHelper.json | fzf)
    export REVOKE_CONTRACT_ADDRESS=$(jq -r ".[\"$contract\"].contract_address" out/scriptHelper.json)
    role_key=$(jq -r ".[\"$contract\"].roles | keys[]" out/scriptHelper.json | fzf)
    export REVOKE_ROLE=$(jq -r ".[\"$contract\"].roles[\"$role_key\"]" out/scriptHelper.json)
    echo "Revoking role $role_key ($REVOKE_ROLE) on $contract ($REVOKE_CONTRACT_ADDRESS)"
    forge script script/RevokeRole.sol -vvvv {{broadcast_flags}}

[group('ops')]
timelock-grant-rate-limiter-role: _pre-deploy
    #!/bin/bash
    set -euo pipefail
    forge script script/GrantRateLimiterRole.sol -vvvv {{broadcast_flags}}

[group('timelock')]
timelock-upgrade-proxy: _pre-deploy
    #!/bin/bash
    set -euo pipefail
    forge script script/UpgradeProxy.sol -vvvv {{timelock_flags}}

[group('timelock')]
timelock-migrate-light-client: _pre-deploy
    #!/bin/bash
    set -euo pipefail
    forge script script/MigrateLightClient.sol -vvvv {{timelock_flags}}

[group('timelock')]
timelock-replace-timelock-admin: _pre-deploy
    #!/bin/bash
    set -euo pipefail
    forge script script/ReplaceTimelockAdmin.sol -vvvv {{timelock_flags}}
