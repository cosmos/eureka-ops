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
[doc('Deploys an SP1 light client against an already-running shadow fork')]
shadow-deploy-light-client chain shadow_env port client_id="":
    #!/bin/bash
    set -euo pipefail
    deployer="${SHADOW_FORK_DEPLOYER:-0xf39fd6e51aad88f6f4ce6ab8827279cfffb92266}"
    fork_rpc="http://127.0.0.1:{{port}}"
    if [ -n "{{client_id}}" ]; then
        export SP1_CLIENT_ID="{{client_id}}"
    fi
    export SP1_DEPLOY_COPY=true
    export DEPLOYMENT_ENV="{{shadow_env}}"
    export EUREKA_ENVIRONMENT="{{shadow_env}}"
    export EUREKA_CHAIN="{{chain}}"
    export ETH_RPC="$fork_rpc"
    export FOUNDRY_ETH_RPC_URL="$fork_rpc"
    forge script script/DeploySP1ICS07Tendermint.sol:DeploySP1ICS07TendermintScript \
        --rpc-url "$fork_rpc" \
        --broadcast \
        --unlocked \
        --sender "$deployer" \
        -vvvv

[group('shadow')]
[doc('Runs the v2-to-v3 upgrade sequence against an already-running Anvil shadow fork')]
shadow-v2-to-v3 chain source_env shadow_env port:
    #!/bin/bash
    set -euo pipefail
    bash scripts/shadow-v2-to-v3-upgrade.sh "{{chain}}" "{{source_env}}" "{{shadow_env}}" "http://127.0.0.1:{{port}}"

[group('shadow')]
[doc('Runs the v2-to-v3 upgrade sequence using an already-prepared shadow deployment JSON')]
shadow-v2-to-v3-preserve chain source_env shadow_env port expected_sp1_migrations="0" sp1_client_ids="":
    #!/bin/bash
    set -euo pipefail
    SP1_CLIENT_IDS="{{sp1_client_ids}}" EXPECTED_SP1_MIGRATIONS="{{expected_sp1_migrations}}" SHADOW_FORK_PRESERVE_DEPLOYMENT=1 bash scripts/shadow-v2-to-v3-upgrade.sh "{{chain}}" "{{source_env}}" "{{shadow_env}}" "http://127.0.0.1:{{port}}"

[group('shadow')]
[doc('Runs the full v2-to-v3 plus SP1 deployment and migration rehearsal')]
shadow-v2-to-v3-with-sp1 chain source_env shadow_env port sp1_client_ids:
    #!/bin/bash
    set -euo pipefail
    IFS=',' read -ra client_ids <<< "{{sp1_client_ids}}"
    expected_sp1_migrations=0
    for client_id in "${client_ids[@]}"; do
        if [ -z "$client_id" ]; then
            continue
        fi
        expected_sp1_migrations=$((expected_sp1_migrations + 1))
    done
    if [ "$expected_sp1_migrations" -eq 0 ]; then
        echo "At least one SP1 client id is required."
        exit 1
    fi
    just shadow-v2-to-v3-preserve {{chain}} {{source_env}} {{shadow_env}} {{port}} "$expected_sp1_migrations" "{{sp1_client_ids}}"

[group('shadow')]
[doc('Runs the v2-to-v3 upgrade sequence against an already-running Sepolia shadow fork')]
shadow-v2-to-v3-sepolia port="8545":
    just shadow-v2-to-v3 11155111 testnet shadow-sepolia {{port}}

[group('shadow')]
[doc('Runs the v2-to-v3 upgrade sequence against an already-prepared Sepolia shadow deployment')]
shadow-v2-to-v3-sepolia-preserve port="8545" expected_sp1_migrations="0":
    just shadow-v2-to-v3-preserve 11155111 testnet shadow-sepolia {{port}} {{expected_sp1_migrations}}

[group('shadow')]
[doc('Runs the full Sepolia v2-to-v3 plus SP1 migration rehearsal')]
shadow-v2-to-v3-sepolia-with-sp1 sp1_client_ids port="8545":
    just shadow-v2-to-v3-with-sp1 11155111 testnet shadow-sepolia {{port}} "{{sp1_client_ids}}"

[group('shadow')]
[doc('Runs the v2-to-v3 upgrade sequence against an already-running Ethereum mainnet shadow fork')]
shadow-v2-to-v3-mainnet port="8546":
    just shadow-v2-to-v3 1 mainnet shadow-mainnet {{port}}

[group('shadow')]
[doc('Runs the v2-to-v3 upgrade sequence against an already-prepared mainnet shadow deployment')]
shadow-v2-to-v3-mainnet-preserve port="8546" expected_sp1_migrations="0":
    just shadow-v2-to-v3-preserve 1 mainnet shadow-mainnet {{port}} {{expected_sp1_migrations}}

[group('shadow')]
[doc('Runs the full mainnet v2-to-v3 plus SP1 migration rehearsal')]
shadow-v2-to-v3-mainnet-with-sp1 sp1_client_ids port="8546":
    just shadow-v2-to-v3-with-sp1 1 mainnet shadow-mainnet {{port}} "{{sp1_client_ids}}"

[group('shadow')]
[doc('Runs the v2-to-v3 upgrade sequence on both default shadow forks')]
shadow-v2-to-v3-all sepolia_port="8545" mainnet_port="8546":
    #!/bin/bash
    set -euo pipefail
    just shadow-v2-to-v3-sepolia {{sepolia_port}}
    just shadow-v2-to-v3-mainnet {{mainnet_port}}
