[group('shadow')]
[doc('Starts an Anvil Sepolia shadow fork using $SEPOLIA_RPC')]
shadow-start-sepolia port="8545":
    #!/bin/bash
    set -euo pipefail
    if [ -z "${SEPOLIA_RPC:-}" ]; then
        echo "SEPOLIA_RPC must be set to the upstream Sepolia RPC URL."
        exit 1
    fi
    anvil --fork-url "$SEPOLIA_RPC" --chain-id 11155111 --auto-impersonate --port {{port}}

[group('shadow')]
[doc('Starts an Anvil Ethereum mainnet shadow fork using $MAINNET_RPC')]
shadow-start-mainnet port="8546":
    #!/bin/bash
    set -euo pipefail
    if [ -z "${MAINNET_RPC:-}" ]; then
        echo "MAINNET_RPC must be set to the upstream Ethereum RPC URL."
        exit 1
    fi
    anvil --fork-url "$MAINNET_RPC" --chain-id 1 --auto-impersonate --port {{port}}

[group('shadow')]
[doc('Copies a deployment JSON into an ignored shadow environment')]
shadow-copy-deployment chain source_env shadow_env:
    #!/bin/bash
    set -euo pipefail
    if [[ "{{shadow_env}}" != shadow-* ]]; then
        echo "shadow_env must start with shadow- (got {{shadow_env}})"
        exit 1
    fi
    mkdir -p deployments/{{shadow_env}}
    cp deployments/{{source_env}}/{{chain}}.json deployments/{{shadow_env}}/{{chain}}.json
    echo "Shadow deployment written to deployments/{{shadow_env}}/{{chain}}.json"

[group('shadow')]
[doc('Runs the v2-to-v3 upgrade through the real TimelockController (schedule + predecessor ordering, then ONE atomic Safe MultiSend execute) against a running shadow fork. Reads the proposer Safe and the SP1 client ids from the shadow deployment JSON; set SP1_CLIENT_IDS to override the client set.')]
shadow-v2-to-v3-timelock chain source_env shadow_env port:
    #!/bin/bash
    set -euo pipefail
    bash scripts/shadow-v2-to-v3-timelock-rehearsal.sh "{{chain}}" "{{source_env}}" "{{shadow_env}}" "http://127.0.0.1:{{port}}"

[group('shadow')]
[doc('Runs the v2-to-v3 upgrade sequence using an already-prepared shadow deployment JSON')]
shadow-v2-to-v3-preserve chain source_env shadow_env port expected_sp1_migrations="0" sp1_client_ids="":
    #!/bin/bash
    set -euo pipefail
    SP1_CLIENT_IDS="{{sp1_client_ids}}" EXPECTED_SP1_MIGRATIONS="{{expected_sp1_migrations}}" SHADOW_FORK_PRESERVE_DEPLOYMENT=1 bash scripts/shadow-v2-to-v3-upgrade.sh "{{chain}}" "{{source_env}}" "{{shadow_env}}" "http://127.0.0.1:{{port}}"

[group('shadow')]
[doc('Runs the full v2-to-v3 plus SP1 migration rehearsal: copies the source deployment into the ignored shadow env, deploys the v3 stack, and deploys + migrates the SP1 clients. Client ids default to every clientId in the source deployment JSON; pass a comma-separated list to override. For staged (uncommitted) SP1 state, use shadow-copy-deployment + shadow-v2-to-v3-preserve instead.')]
shadow-v2-to-v3-with-sp1 chain source_env shadow_env port sp1_client_ids="":
    #!/bin/bash
    set -euo pipefail
    source_file="deployments/{{source_env}}/{{chain}}.json"
    client_ids="{{sp1_client_ids}}"
    if [ -z "$client_ids" ]; then
        test -f "$source_file" || { echo "deployment file not found: $source_file"; exit 1; }
        client_ids="$(jq -r '[.light_clients[].clientId // empty] | join(",")' "$source_file")"
    fi
    IFS=',' read -ra client_id_arr <<< "$client_ids"
    expected_sp1_migrations=0
    # ${arr[@]+...} guards against the empty-array `set -u` error on bash 3.2 (macOS /bin/bash).
    for client_id in ${client_id_arr[@]+"${client_id_arr[@]}"}; do
        if [ -n "$client_id" ]; then
            expected_sp1_migrations=$((expected_sp1_migrations + 1))
        fi
    done
    if [ "$expected_sp1_migrations" -eq 0 ]; then
        echo "No SP1 client ids (none passed and none found in $source_file)."
        exit 1
    fi
    SP1_CLIENT_IDS="$client_ids" EXPECTED_SP1_MIGRATIONS="$expected_sp1_migrations" bash scripts/shadow-v2-to-v3-upgrade.sh "{{chain}}" "{{source_env}}" "{{shadow_env}}" "http://127.0.0.1:{{port}}"

[group('shadow')]
[doc('Sepolia v2-to-v3 timelock rehearsal (real schedule + ordering + atomic Safe MultiSend execute). Reads the proposer Safe and SP1 client ids from the deployment JSON.')]
shadow-v2-to-v3-sepolia-timelock port="8545":
    just shadow-v2-to-v3-timelock 11155111 testnet shadow-sepolia {{port}}

[group('shadow')]
[doc('Runs the full Sepolia v2-to-v3 plus SP1 migration rehearsal (client ids read from the shadow deployment JSON)')]
shadow-v2-to-v3-sepolia-with-sp1 port="8545":
    just shadow-v2-to-v3-with-sp1 11155111 testnet shadow-sepolia {{port}}

[group('shadow')]
[doc('Mainnet v2-to-v3 timelock rehearsal (real schedule + ordering + atomic Safe MultiSend execute). Reads the proposer Safe and SP1 client ids from the deployment JSON.')]
shadow-v2-to-v3-mainnet-timelock port="8546":
    just shadow-v2-to-v3-timelock 1 mainnet shadow-mainnet {{port}}

[group('shadow')]
[doc('Runs the full mainnet v2-to-v3 plus SP1 migration rehearsal (client ids read from the shadow deployment JSON)')]
shadow-v2-to-v3-mainnet-with-sp1 port="8546":
    just shadow-v2-to-v3-with-sp1 1 mainnet shadow-mainnet {{port}}
