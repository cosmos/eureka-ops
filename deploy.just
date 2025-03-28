environment := env_var_or_default("EUREKA_ENVIRONMENT", "")
chain := env_var_or_default("EUREKA_CHAIN", "")
sender := env_var_or_default("SENDER", "")
export FOUNDRY_ETH_RPC_URL := if environment == "" { "" } else if chain == "" { "" } else { `jq -re '.rpc_url' deployments/$EUREKA_ENVIRONMENT/$EUREKA_CHAIN.json` }

[group('deploy-implementation')]
[doc('Deploys a new implementation of Escrow')]
deploy-escrow-impl: env-info (_new-deployment "Escrow" "ics20Transfer.escrowImplementation")

[group('deploy-implementation')]
[doc('Deploys a new implementation of IBCERC20')]
deploy-ibcerc20-impl: env-info (_new-deployment "IBCERC20" "ics20Transfer.ibcERC20Implementation")

[group('deploy-implementation')]
[doc('Deploys a new implementation of ICS20Transfer')]
deploy-transfer-impl: env-info (_new-deployment "ICS20Transfer" "ics20Transfer.implementation")

[group('deploy-implementation')]
[doc('Deploys a new implementation of ICS26Router')]
deploy-router-impl: (_new-deployment "ICS26Router" "ics26Router.implementation")

[group('deploy')]
new-light-client:
    #!/bin/bash
    set -euo pipefail
    deployment=$(cat deployments/{{environment}}/{{chain}}.json)
    nextLightClient=$(echo $deployment | jq -re ".light_clients | keys | sort | reverse | tonumber | . - 1")
    updatedDeployment=$(jq '.light_clients["$nextLightClient"] |= input' deployments/{{environment}}/{{chain}}.json fixtures/empty_light_client.json)

#[group('deploy')]
#deploy-light-client:
#    #!/bin/bash
#    set -euo pipefail
#    {{forge_command}} script script/DeploySP1ICS07Tendermint.sol --broadcast --chain-id {{chain}} {{forge_flags}}
#    git commit -am "operation: deployed new light client on {{chain}}" || true

pause-deployment $DEPLOYMENT_ENV chain:
    {{forge_command}} script script/PauseTransfers.sol --broadcast --chain-id {{chain}} {{forge_flags}}

_update-deployment key value:
    #!/bin/bash
    set -euo pipefail
    updatedDeployment=$(cat deployments/{{environment}}/{{chain}}.json | jq ".{{key}} |= \"{{value}}\"")
    echo "$updatedDeployment" > deployments/{{environment}}/{{chain}}.json
    git commit -am "operation: deployed $updatedDeployment"
    # git push

_new-deployment contract key:
    #!/bin/bash
    set -euxo pipefail
    output=$({{forge_command}} create --broadcast --chain-id {{chain}} {{forge_flags}} --json {{contract}})
    deploymentAddress=$(echo $output | jq -re .deployedTo) 
    echo "{{contract}} deployed to $deploymentAddress";
    just -f {{justfile()}} _update-deployment {{key}} $deploymentAddress

env-info:
  @echo "Environment: {{environment}}"
  @echo "Chain ID: {{chain}}"

[group('deploy')]
deploy-ics26-router:
    #!/bin/bash
    set -euo pipefail
    export DEPLOYMENT_ENV={{environment}}
    forge script script/DeployProxiedICS26Router.sol -vvvv --broadcast --ledger --sender {{sender}} --verify

[group('deploy')]
deploy-ics20-transfer:
    #!/bin/bash
    set -euo pipefail
    export DEPLOYMENT_ENV={{environment}}
    forge script script/DeployProxiedICS20Transfer.sol -vvvv --broadcast --ledger --sender {{sender}} --verify

[group('deploy')]
deploy-light-client:
    #!/bin/bash
    set -euo pipefail
    export DEPLOYMENT_ENV={{environment}}
    forge script script/DeploySP1ICS07Tendermint.sol -vvvv --broadcast --ledger --sender {{sender}} --verify

[group('deploy')]
deploy-relayer-helper:
    #!/bin/bash
    set -euo pipefail
    export DEPLOYMENT_ENV={{environment}}
    forge script script/DeployRelayerHelper.sol -vvvv --broadcast --ledger --sender {{sender}} --verify

[group('deploy')]
deploy-set-whitelisted-relayers:
    #!/bin/bash
    set -euo pipefail
    export DEPLOYMENT_ENV={{environment}}
    forge script script/SetWhitelistedRelayers.sol -vvvv --broadcast --ledger --sender {{sender}} --verify

[group('deploy')]
deploy-migrate-light-client:
    #!/bin/bash
    set -euo pipefail
    export DEPLOYMENT_ENV={{environment}}
    forge script script/MigrateLightClient.sol -vvvv --broadcast --ledger --sender {{sender}} --verify

[group('deploy')]
deploy-grant-metadata-role:
    #!/bin/bash
    set -euo pipefail
    export DEPLOYMENT_ENV={{environment}}
    forge script script/GrantMetadataRole.sol -vvvv --broadcast --ledger --sender {{sender}} --verify

[group('deploy')]
deploy-set-metadata:
    #!/bin/bash
    set -euo pipefail
    export DEPLOYMENT_ENV={{environment}}
    forge script script/SetTokenMetadata.sol -vvvv --broadcast --ledger --sender {{sender}} --verify

