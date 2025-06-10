_private_key_not_set := "PRIVATE_KEY-NOT-SET"

environment := env_var_or_default("EUREKA_ENVIRONMENT", "")
chain := env_var_or_default("EUREKA_CHAIN", "")
sender := env_var_or_default("SENDER", "")
mnemonic_index := env_var_or_default("MNEMONIC_INDEX", "")
eth_rpc := env_var_or_default("ETH_RPC", "")
private_key := env_var_or_default("PRIVATE_KEY", _private_key_not_set)
_wallet_base := if private_key !=  _private_key_not_set { "--private-key " + private_key } else { "--ledger --sender " + sender }
wallet := if mnemonic_index != "" { _wallet_base + " --mnemonic-indexes " + mnemonic_index } else { _wallet_base }
_timelock_controller := shell('jq -r ".ics26Router.timelockAdmin" deployments/$1/$2.json', environment, chain)

_verify_flags  := "--verify"
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

[group('utils')]
clean: && _build
    #!/bin/bash
    set -eou pipefail
    echo "Doing a full clean..."
    forge clean
    rm -rf node_modules

_build: && _generate-script-helper
    #!/bin/bash
    set -eou pipefail
    echo "Building contracts..."
    bun install
    forge build

_confirm-settings script_flags:
    #!/bin/bash
    set -eou pipefail
    echo "You are about to run a script with the following settings:"
    just info-env
    echo
    safe_script_flags=$(echo "{{script_flags}}" | sed -e "s/{{private_key}}/***REDACTED***/g")
    echo "Script flags to be used: $safe_script_flags"
    echo
    read -p "Please confirm: (y/n) " -n 1 -r
    echo    # (optional) move to a new line
    if [[ ! $REPLY =~ ^[Yy]$ ]]
    then
        echo "User did not confirm. Aborting deployment!"
        exit 1
    fi

_pre-script script_flags: _build (_confirm-settings script_flags)
    #!/bin/bash
    set -eou pipefail
    echo
    echo "Pre-script checks completed. Proceeding with script execution..."
    echo {{separator}}

# Generate user input JSON file that can be used for fzf selection
_generate-script-helper:
    #!/bin/bash
    set -eou pipefail
    forge script script/GenerateScriptHelperJSON.sol:GenerateScriptHelperJSON

test-generate-script-helper: _build _generate-script-helper
    #!/bin/bash
    set -euo pipefail
    jq "." out/scriptHelper.json

[group('deploy')]
print-abi: _build
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
    forge script script/VerifyDeployment.sol -vvv

[group('verify')]
[doc('Verifies a contract deployed in <environment> on <chain>')]
verify-contract:
    #!/bin/bash
    set -eou pipefail
    solidity_ver=$(jq -r ".dependencies[\"@cosmos/solidity-ibc-eureka\"]" package.json)
    echo "You are about to verify a contract from the IBC Solidity Contracts with the tag/ref: $solidity_ver"
    read -p "Enter contract address to verify: " -r
    echo    # (optional) move to a new line
    contract_address=$REPLY
    contract_path=$(cd node_modules/@cosmos/solidity-ibc-eureka/contracts && find . -type f | sed 's|^\./||' | fzf --header="Select contract you expect to be deployed at the address above")
    contract_file_name=$(basename "$contract_path")
    contract_name=${contract_file_name%".sol"}
    forge verify-contract $contract_address node_modules/@cosmos/solidity-ibc-eureka/contracts/$contract_path:$contract_name

[group('verify')]
verify-safe-tx safe_address nonce target data:
    #!/bin/bash
    set -eou pipefail
    domain_hash=$(chisel eval --json "keccak256(abi.encode({{eip712_separator_typehash}}, {{chain}}, {{safe_address}}))" | awk '/Data:/ {gsub(/\x1b\[[0-9;]*m/, "", $3); print $3}')
    schedule_data=$(cast calldata "schedule(address,uint256,bytes,bytes32,bytes32,uint256)" {{target}} 0 {{data}} {{zero_bytes32}} {{zero_bytes32}} 60)
    data_hashed=$(cast keccak "$schedule_data")
    value="0"
    operation="0"
    safe_tx_gas="0"
    base_gas="0"
    gas_price="0"
    gas_token="{{zero_address}}"
    refund_receiver="{{zero_address}}"
    message=$({{cast_binary}} abi-encode "SafeTxStruct(bytes32,address,uint256,bytes32,uint8,uint256,uint256,uint256,address,address,uint256)" \
          "{{safe_tx_typehash}}" \
          "{{_timelock_controller}}" \
          "$value" \
          "$data_hashed" \
          "$operation" \
          "$safe_tx_gas" \
          "$base_gas" \
          "$gas_price" \
          "$gas_token" \
          "$refund_receiver" \
          "{{nonce}}")
    message_hash=$(cast keccak "$message")
    safe_tx_hash=$(chisel eval "keccak256(abi.encodePacked(bytes1(0x19), bytes1(0x01), bytes32($domain_hash), bytes32($message_hash)))" |
        awk '/Data:/ {gsub(/\x1b\[[0-9;]*m/, "", $3); print $3}')

    echo "Domain Hash: $domain_hash"
    echo "Message Hash: $message_hash"
    echo "Safe Transaction Hash: $safe_tx_hash"


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
deploy-update-light-client-state:
    #!/bin/bash
    set -euo pipefail
    forge script script/helpers/UpdateLightClientState.sol

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

[group('ops')]
ops-set-custom-erc20: (_pre-script _broadcast_flags) (_set-custom-erc20 _broadcast_flags)

[group('ops')]
ops-add-light-client: (_pre-script _broadcast_flags)
    #!/bin/bash
    set -euo pipefail
    forge script script/AddLightClient.sol -vvvv {{_broadcast_flags}}

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

[group('timelock')]
timelock-grant-rate-limiter-role timelock_function nonce="": (timelock-script "GrantRateLimiterRole" timelock_function nonce)

[group('timelock')]
timelock-upgrade-proxy timelock_function nonce="": (timelock-script "UpgradeProxy" timelock_function nonce)

[group('timelock')]
timelock-migrate-light-client timelock_function nonce="": (timelock-script "MigrateLightClient" timelock_function nonce)

[group('timelock')]
timelock-replace-timelock-admin timelock_function nonce="": (timelock-script "ReplaceTimelockAdmin" timelock_function nonce)

[group('timelock')]
timelock-grant-role timelock_function nonce="": 
    #!/bin/bash
    set -euo pipefail
    contract=$(jq -r ".deployments | keys[]" out/scriptHelper.json | fzf --header="Select contract with the role you want to grant")
    export GRANT_CONTRACT_ADDRESS=$(jq -r ".deployments.[\"$contract\"].contract_address" out/scriptHelper.json)
    role_key=$(jq -r ".deployments.[\"$contract\"].roles | keys[]" out/scriptHelper.json | fzf --header="Select role you wish to grant")
    export GRANT_ROLE=$(jq -r ".deployments.[\"$contract\"].roles[\"$role_key\"]" out/scriptHelper.json)
    echo "Granting role $role_key ($GRANT_ROLE) on $contract ($GRANT_CONTRACT_ADDRESS)"
    just timelock-script "GrantRole" {{ timelock_function }} {{ nonce }}


[group('timelock')]
timelock-add-light-client timelock_function nonce="": (timelock-script "AddLightClient" timelock_function nonce)

[group('verify')]
verify-schedule-add-light-client nonce: (timelock-add-light-client "schedule" nonce)

[group('verify')]
verify-execute-add-light-client nonce: (timelock-add-light-client "execute" nonce)

[group('verify')]
verify-schedule-grant-role nonce: (timelock-grant-role "schedule" nonce)

[group('verify')]
verify-execute-grant-role nonce: (timelock-grant-role "execute" nonce)

[group('verify')]
verify-schedule-grant-rate-limiter-role nonce: (timelock-grant-rate-limiter-role "schedule" nonce)

[group('verify')]
verify-execute-grant-rate-limiter-role nonce: (timelock-grant-rate-limiter-role "execute" nonce)

[group('verify')]
verify-schedule-upgrade-proxy nonce: (timelock-upgrade-proxy "schedule" nonce)

[group('verify')]
verify-execute-upgrade-proxy nonce: (timelock-upgrade-proxy "execute" nonce)

[group('verify')]
verify-schedule-migrate-light-client nonce: (timelock-migrate-light-client "schedule" nonce)

[group('verify')]
verify-execute-migrate-light-client nonce: (timelock-migrate-light-client "execute" nonce)

timelock-script script_contract_name timelock_function nonce="": (_pre-script _timelock_flags) && (_timelock-params script_contract_name timelock_function nonce)
    #!/bin/bash
    set -euo pipefail
    forge script script/{{script_contract_name}}.sol -vvvv {{_timelock_flags}}

_timelock-params contract_name timelock_function nonce: 
    #!/bin/bash
    set -euo pipefail
    num_txs=$(jq ".transactions | length" broadcast/{{ contract_name }}.sol/{{ chain }}/dry-run/run-latest.json)
    # Should be one and only one transaction in the dry-run output
    if [ "$num_txs" -ne 1 ]; then
        echo "Expected exactly one transaction in the dry-run output, found $num_txs."
        exit 1
    fi
    tx=$(jq ".transactions[0]" broadcast/{{ contract_name }}.sol/{{ chain }}/dry-run/run-latest.json)
    function=$(jq -r ".function" <<< "$tx")
    args=$(jq -r ".arguments" <<< "$tx")

    to=$(jq -r ".transaction.to" <<< "$tx")
    calldata=$(jq -r ".transaction.input" <<< "$tx")
    timelock_delay=$(jq -r ".settings.timelock_delay" out/scriptHelper.json)

    schedule_sig="schedule(address,uint256,bytes,bytes32,bytes32,uint256)"
    execute_sig="execute(address,uint256,bytes,bytes32,bytes32)"

    if [ "{{ timelock_function }}" == "schedule" ]; then
        timelock_sig=$schedule_sig
        timelock_calldata=$({{cast_binary}} calldata "$schedule_sig" $to 0 $calldata {{zero_bytes32}} {{zero_bytes32}} $timelock_delay)
    elif [ "{{ timelock_function }}" == "execute" ]; then
        timelock_sig=$execute_sig
        timelock_calldata=$({{cast_binary}} calldata "$execute_sig" $to 0 $calldata {{zero_bytes32}} {{zero_bytes32}})
    else
        echo "Unknown timelock function: {{ timelock_function }}"
        exit 1
    fi
    echo "Tx info:"
    echo "{{separator}}"
    echo "function: $function"
    echo "args: $args"
    echo "to: $to"
    echo "calldata: $calldata"
    echo 
    echo "Timelock info:"
    echo "{{separator}}"
    echo "function: {{timelock_function}}"
    echo "to: $to"
    echo "value: 0"
    echo "data: $calldata"
    echo "predecessor: 0x"
    echo "salt: 0x"
    echo "delay: $timelock_delay"
    echo "timelock calldata: $timelock_calldata"

    echo
    if [ -z "{{ nonce }}" ]; then
        echo "Nonce not priovided, skipping safe tx hashes"
    else
        echo "Safe hashes:"
        echo "{{separator}}"
        just get_safe_hashes {{ nonce }} $timelock_calldata {{ _timelock_controller }}
    fi

_grant-role script_flags:
    #!/bin/bash
    set -euo pipefail
    contract=$(jq -r ".deployments | keys[]" out/scriptHelper.json | fzf --header="Select contract with the role you want to grant")
    export GRANT_CONTRACT_ADDRESS=$(jq -r ".deployments.[\"$contract\"].contract_address" out/scriptHelper.json)
    role_key=$(jq -r ".deployments.[\"$contract\"].roles | keys[]" out/scriptHelper.json | fzf --header="Select role you wish to grant")
    export GRANT_ROLE=$(jq -r ".deployments.[\"$contract\"].roles[\"$role_key\"]" out/scriptHelper.json)
    echo "Granting role $role_key ($GRANT_ROLE) on $contract ($GRANT_CONTRACT_ADDRESS)"
    forge script script/GrantRole.sol -vvvv {{script_flags}}

_set-custom-erc20 script_flags:
    #!/bin/bash
    set -euo pipefail
    forge script script/SetCustomERC20.sol -vvvv {{script_flags}}
