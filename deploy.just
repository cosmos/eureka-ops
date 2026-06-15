_private_key_not_set := "PRIVATE_KEY-NOT-SET"

environment := env_var_or_default("EUREKA_ENVIRONMENT", "")
chain := env_var_or_default("EUREKA_CHAIN", "")
sender := env_var_or_default("SENDER", "")
mnemonic_index := env_var_or_default("MNEMONIC_INDEX", "")
eth_rpc := env_var_or_default("ETH_RPC", "")
# zk algorithm for the generated client state; MUST match the existing client (groth16 or plonk)
proof_type := env_var_or_default("PROOF_TYPE", "groth16")

## proof-api source (default for fresh light client state)
# host:port of a running proof-api / eureka-relayer gRPC server (uses server reflection, so no proto file is needed)
proof_api_addr := env_var_or_default("PROOF_API_ADDR", "localhost:3000")
# fully-qualified gRPC service; leave empty to auto-discover via reflection (relayer.RelayerService on v0.7.x, proofapi.ProofApiService on v0.8.x)
proofapi_service := env_var_or_default("PROOFAPI_SERVICE", "")
# proof-api source/destination chain identifiers (Cosmos chain = src, Ethereum chain = dst), exactly as configured in the proof-api module (decimal Eth chain id, e.g. dst "11155111" for Sepolia)
src_chain := env_var_or_default("SRC_CHAIN", "")
dst_chain := env_var_or_default("DST_CHAIN", "")
# extra grpcurl flags (e.g. "-plaintext" for non-TLS, or "" plus -H auth headers)
grpcurl_flags := env_var_or_default("GRPCURL_FLAGS", "-plaintext")

private_key := env_var_or_default("PRIVATE_KEY", _private_key_not_set)
_wallet_base := if private_key !=  _private_key_not_set { "--private-key " + private_key } else { "--ledger --sender " + sender }
wallet := if mnemonic_index != "" { _wallet_base + " --mnemonic-indexes " + mnemonic_index } else { _wallet_base }
# Resolves the AccessManager admin (timelock) from the deployment JSON. Returns empty when the environment/chain
# are unset (so `just --list` and env-agnostic recipes still work), but fails loudly when they are set yet the
# deployment file or admin key is missing — rather than silently returning the zero address, which would make
# recipes compute Safe hashes / use `--sender` against address(0).
_timelock_controller := shell('if [ -z "$1" ] || [ -z "$2" ]; then echo ""; exit 0; fi; f="deployments/$1/$2.json"; test -f "$f" || { echo "timelock admin lookup failed: $f not found" >&2; exit 1; }; jq -re "(.accessManagerRoles.admin // .ics26Router.timelockAdmin)" "$f" || { echo "timelock admin not set in $f (.accessManagerRoles.admin / .ics26Router.timelockAdmin)" >&2; exit 1; }', environment, chain)

_verify_flags  := "--verify"
_broadcast_flags := "--broadcast " + _verify_flags + " " + wallet
_timelock_flags := "--sender " + _timelock_controller
_multisig_flags := "--sender " + sender

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
    echo "AccessManager admin: {{_timelock_controller}}"
    echo "Broadcast Flags: {{_broadcast_flags}}" | sed -e "s/{{private_key}}/***REDACTED***/g"
    echo "Timelock Flags: {{_timelock_flags}}"

[group('info')]
info-admin: _generate-script-helper
    #!/bin/bash
    set -eou pipefail
    is_timelock=$(jq -r ".settings.admin_is_timelock_controller" out/scriptHelper.json)
    echo "Admin Information for {{environment}} on {{chain}}:"
    echo "AccessManager admin address: {{_timelock_controller}}"
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
    echo "Predecessor: {{zero_bytes32}}"
    echo "Salt: {{zero_bytes32}}"
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
deploy-v3-access-manager: (_pre-script _broadcast_flags)
    #!/bin/bash
    set -euo pipefail
    forge script script/DeployV3AccessManager.sol:DeployV3AccessManager -vvvv {{_broadcast_flags}}

[group('deploy')]
deploy-v3-core: (_pre-script _broadcast_flags)
    #!/bin/bash
    set -euo pipefail
    forge script script/DeployV3Core.sol:DeployV3Core -vvvv {{_broadcast_flags}}

[group('deploy')]
deploy-light-client: (_pre-script _broadcast_flags)
    #!/bin/bash
    set -euo pipefail
    forge script script/DeploySP1ICS07Tendermint.sol -vvvv {{_broadcast_flags}}

[group('deploy')]
register-ics27-gmp: (_pre-script _broadcast_flags)
    #!/bin/bash
    set -euo pipefail
    forge script script/RegisterICS27GMP.sol:RegisterICS27GMP -vvvv {{_broadcast_flags}}

[group('deploy')]
deploy-update-light-client-state:
    #!/bin/bash
    set -euo pipefail
    forge script script/helpers/UpdateLightClientState.sol

[group('deploy')]
[doc('Fetch FRESH trusted state for a (possibly expired) light client from a running proof-api and write it into the deployment JSON, so the client can be redeployed + migrated. Requires PROOF_API_ADDR, SRC_CHAIN, DST_CHAIN, grpcurl, python3. See runbooks/recover-expired-light-client.md.')]
deploy-fresh-light-client-state:
    #!/bin/bash
    set -euo pipefail

    deployment_file="deployments/{{environment}}/{{chain}}.json"
    test -f "$deployment_file" || { echo "Deployment file $deployment_file not found"; exit 1; }
    test -n "{{proof_api_addr}}" || { echo "PROOF_API_ADDR is not set (host:port of a running proof-api gRPC server)"; exit 1; }
    test -n "{{src_chain}}" || { echo "SRC_CHAIN is not set (proof-api source chain id, the Cosmos chain)"; exit 1; }
    test -n "{{dst_chain}}" || { echo "DST_CHAIN is not set (proof-api destination chain id, the Ethereum chain as a decimal chain id, e.g. 11155111 for Sepolia)"; exit 1; }
    command -v grpcurl >/dev/null || { echo "grpcurl not found (needed to call the proof-api)"; exit 1; }
    command -v python3 >/dev/null || { echo "python3 not found (needed to decode the response)"; exit 1; }

    read -rp "Client ID to generate fresh state for: " client_id
    entry=$(jq -c --arg cid "$client_id" '.light_clients | to_entries[] | select(.value.clientId==$cid)' "$deployment_file")
    test -n "$entry" || { echo "Client ID '$client_id' not found in $deployment_file"; exit 1; }
    idx=$(jq -r '.key' <<<"$entry")
    echo "Found '$client_id' at light_clients[\"$idx\"]"

    # Discover the gRPC service via reflection unless one was provided (relayer.RelayerService on v0.7.x, proofapi.ProofApiService on v0.8.x)
    service="{{proofapi_service}}"
    if [ -z "$service" ]; then
      service=$(grpcurl {{grpcurl_flags}} "{{proof_api_addr}}" list | grep -E '(^|\.)(RelayerService|ProofApiService)$' | head -1 || true)
    fi
    test -n "$service" || { echo "Could not find a CreateClient service via reflection on {{proof_api_addr}}. Set PROOFAPI_SERVICE. Services seen:"; grpcurl {{grpcurl_flags}} "{{proof_api_addr}}" list || true; exit 1; }

    # sp1_verifier is required by CreateClient but does NOT affect the trusted state we extract;
    # reuse the existing client verifier if present, otherwise the zero address.
    sp1_verifier=$(jq -r '.value.verifier // empty' <<<"$entry")
    sp1_verifier=${sp1_verifier:-0x0000000000000000000000000000000000000000}

    echo
    echo "Requesting fresh client state from proof-api:"
    echo "  endpoint:    {{proof_api_addr}}  service=$service  (src={{src_chain}} dst={{dst_chain}})"
    echo "  zk algo:     {{proof_type}} (MUST match the existing client zk algorithm)"
    echo "  sp1_verifier:$sp1_verifier (discarded; only client+consensus state are used)"
    read -p "Confirm: (y/n) " -n 1 -r; echo
    [[ $REPLY =~ ^[Yy]$ ]] || { echo "Aborted."; exit 1; }

    req=$(jq -nc --arg s "{{src_chain}}" --arg d "{{dst_chain}}" --arg v "$sp1_verifier" --arg z "{{proof_type}}" \
      '{src_chain:$s, dst_chain:$d, parameters:{sp1_verifier:$v, zk_algorithm:$z} }')

    resp=$(grpcurl {{grpcurl_flags}} -d "$req" "{{proof_api_addr}}" "$service/CreateClient")

    txb64=$(jq -r '.tx // empty' <<<"$resp")
    test -n "$txb64" || { echo "proof-api returned no tx. Response: $resp"; exit 1; }
    # proto bytes come back base64; turn into 0x-prefixed creation calldata
    calldata="0x$(printf '%s' "$txb64" | base64 -d | od -An -v -tx1 | tr -d ' \n')"
    echo "Received creation calldata (${#calldata} hex chars). Decoding constructor args..."

    # Structurally decode trustedClientState + trustedConsensusStateHash (no dependency on local bytecode/version)
    decoded=$(CALLDATA="$calldata" python3 script/helpers/decode_create_client.py)
    client_state=$(jq -er '.trustedClientState' <<<"$decoded")
    consensus_hash=$(jq -er '.trustedConsensusStateHash' <<<"$decoded")

    echo
    echo "New trustedClientState:        $client_state"
    echo "New trustedConsensusStateHash: $consensus_hash"

    tmp=$(mktemp)
    jq --arg cs "$client_state" --arg h "$consensus_hash" \
      ".light_clients[\"$idx\"].trustedClientState = \$cs | .light_clients[\"$idx\"].trustedConsensusStateHash = \$h" \
      "$deployment_file" > "$tmp" && mv "$tmp" "$deployment_file"

    echo
    echo "Updated $deployment_file (light_clients[\"$idx\"])."
    echo "Review the diff (git diff), then run 'just deploy-light-client' for $client_id."

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

[group('ops')]
ops-grant-rate-limiter-role: (ops-script "GrantRateLimiterRole" _broadcast_flags)

[group('ops')]
ops-grant-role: _generate-script-helper (_pre-script _broadcast_flags) (_grant-role _broadcast_flags)

[group('ops')]
ops-set-custom-erc20: (ops-script "SetCustomERC20" _broadcast_flags)

[group('ops')]
ops-set-custom-erc20-multisig: (ops-script-multisig "SetCustomERC20")

[group('ops')]
ops-add-light-client: (ops-script "AddLightClient" _broadcast_flags)

[group('ops')]
ops-migrate-light-client: (ops-script "MigrateLightClient" _broadcast_flags)

[group('ops')]
ops-revoke-role: _generate-script-helper (_pre-script _broadcast_flags)
    #!/bin/bash
    set -euo pipefail
    contract=$(jq -r ".deployments | keys[]" out/scriptHelper.json | fzf --header="Select a contract to list its roles (AccessManager roles are manager-wide, not scoped to this contract)")
    role_key=$(jq -r ".deployments[\"$contract\"].roles | keys[]" out/scriptHelper.json | fzf --header="Select role to revoke")
    export REVOKE_ROLE=$(jq -r ".deployments[\"$contract\"].roles[\"$role_key\"]" out/scriptHelper.json)
    echo "Revoking role $role_key ($REVOKE_ROLE) on the AccessManager (manager-wide; applies to every target wired to this role)"
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
timelock-grant-role timelock_function nonce="": (_pre-script _timelock_flags) && (_timelock-params "GrantRole" timelock_function nonce)
    #!/bin/bash
    set -euo pipefail
    contract=$(jq -r ".deployments | keys[]" out/scriptHelper.json | fzf --header="Select a contract to list its roles (AccessManager roles are manager-wide, not scoped to this contract)")
    role_key=$(jq -r ".deployments[\"$contract\"].roles | keys[]" out/scriptHelper.json | fzf --header="Select role to grant")
    export GRANT_ROLE=$(jq -r ".deployments[\"$contract\"].roles[\"$role_key\"]" out/scriptHelper.json)
    echo "Granting role $role_key ($GRANT_ROLE) on the AccessManager (manager-wide; applies to every target wired to this role)"
    just timelock-script "GrantRole" {{ timelock_function }} {{ nonce }}


# Revoke an AccessManager role under a TimelockController admin (mirror of timelock-grant-role). ops-revoke-role
# broadcasts from an EOA and reverts once the AccessManager admin is the timelock, so this is the supported path
# for incident-response revocation (e.g. yanking a compromised relayer/pauser) in the v3 timelock-admin model.
[group('timelock')]
timelock-revoke-role timelock_function nonce="": (_pre-script _timelock_flags) && (_timelock-params "RevokeRole" timelock_function nonce)
    #!/bin/bash
    set -euo pipefail
    contract=$(jq -r ".deployments | keys[]" out/scriptHelper.json | fzf --header="Select a contract to list its roles (AccessManager roles are manager-wide, not scoped to this contract)")
    role_key=$(jq -r ".deployments[\"$contract\"].roles | keys[]" out/scriptHelper.json | fzf --header="Select role to revoke")
    export REVOKE_ROLE=$(jq -r ".deployments[\"$contract\"].roles[\"$role_key\"]" out/scriptHelper.json)
    echo "Revoking role $role_key ($REVOKE_ROLE) on the AccessManager (manager-wide; applies to every target wired to this role)"
    just timelock-script "RevokeRole" {{ timelock_function }} {{ nonce }}


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
verify-schedule-revoke-role nonce: (timelock-revoke-role "schedule" nonce)

[group('verify')]
verify-execute-revoke-role nonce: (timelock-revoke-role "execute" nonce)

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

[group('ops')]
ops-script script_contract_name script_flags: (_pre-script script_flags)
    #!/bin/bash
    set -euo pipefail
    forge script script/{{script_contract_name}}.sol -vvvv {{script_flags}}

[group('ops')]
ops-script-multisig script_contract_name: (ops-script script_contract_name _multisig_flags) && (_multisig-params script_contract_name)

_multisig-params contract_name:
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
    echo "Tx info:"
    echo "{{separator}}"
    echo "function: $function"
    echo "args: $args"
    echo "to: $to"
    echo "calldata: $calldata"

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
    echo "address: {{ _timelock_controller }}"
    echo "function: {{timelock_function}}"
    echo "target: $to"
    echo "value: 0"
    echo "data: $calldata"
    echo "predecessor: {{zero_bytes32}}"
    echo "salt: {{zero_bytes32}}"
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

    echo
    echo "Hint: copy the TimelockController ABI to your clipboard with: just copy-abi-to-clipboard TimelockController"

_grant-role script_flags:
    #!/bin/bash
    set -euo pipefail
    contract=$(jq -r ".deployments | keys[]" out/scriptHelper.json | fzf --header="Select a contract to list its roles (AccessManager roles are manager-wide, not scoped to this contract)")
    role_key=$(jq -r ".deployments[\"$contract\"].roles | keys[]" out/scriptHelper.json | fzf --header="Select role to grant")
    export GRANT_ROLE=$(jq -r ".deployments[\"$contract\"].roles[\"$role_key\"]" out/scriptHelper.json)
    echo "Granting role $role_key ($GRANT_ROLE) on the AccessManager (manager-wide; applies to every target wired to this role)"
    forge script script/GrantRole.sol -vvvv {{script_flags}}

_set-custom-erc20 script_flags:
    #!/bin/bash
    set -euo pipefail
    forge script script/SetCustomERC20.sol -vvvv {{script_flags}}
