environment := env_var_or_default("EUREKA_ENVIRONMENT", "")
chain := env_var_or_default("EUREKA_CHAIN", "")
sender := env_var_or_default("SENDER", "")
eth_rpc := env_var_or_default("ETH_RPC", "")

export FOUNDRY_ETH_RPC_URL := eth_rpc
export DEPLOYMENT_ENV := environment


[group('verify')]
[doc('Verifies contract deployments for <chain> in <environment>')]
verify-deployment:
    #!/bin/bash
    set -eou pipefail
    export VERIFY_ONLY=true
    forge script script/DeployProxiedICS26Router.sol
    forge script script/DeployProxiedICS20Transfer.sol
    forge script script/DeploySP1ICS07Tendermint.sol


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
    forge script script/DeployProxiedICS26Router.sol -vvvv --broadcast --ledger --sender {{sender}} --verify

[group('deploy')]
deploy-ics20-transfer:
    #!/bin/bash
    set -euo pipefail
    forge script script/DeployProxiedICS20Transfer.sol -vvvv --broadcast --ledger --sender {{sender}} --verify

[group('deploy')]
deploy-light-client:
    #!/bin/bash
    set -euo pipefail
    forge script script/DeploySP1ICS07Tendermint.sol -vvvv --broadcast --ledger --sender {{sender}} --verify

[group('deploy')]
deploy-relayer-helper:
    #!/bin/bash
    set -euo pipefail
    forge script script/DeployRelayerHelper.sol -vvvv --broadcast --ledger --sender {{sender}} --verify

[group('deploy')]
deploy-grant-relayer-role:
    #!/bin/bash
    set -euo pipefail
    forge script script/GrantRelayerRole.sol -vvvv --broadcast --ledger --sender {{sender}} --verify

[group('deploy')]
deploy-migrate-light-client:
    #!/bin/bash
    set -euo pipefail
    forge script script/MigrateLightClient.sol -vvvv --broadcast --ledger --sender {{sender}} --verify

[group('deploy')]
deploy-grant-metadata-role:
    #!/bin/bash
    set -euo pipefail
    forge script script/GrantMetadataRole.sol -vvvv --broadcast --ledger --sender {{sender}} --verify

[group('deploy')]
deploy-set-metadata:
    #!/bin/bash
    set -euo pipefail
    forge script script/SetTokenMetadata.sol -vvvv --broadcast --ledger --sender {{sender}} --verify

[group('deploy')]
deploy-grant-delegate-sender-role:
    #!/bin/bash
    set -euo pipefail
    forge script script/GrantDelegateSenderRole.sol -vvvv --broadcast --ledger --sender {{sender}} --verify

[group('deploy')]
deploy-grant-rate-limiter-role:
    #!/bin/bash
    set -euo pipefail
    forge script script/GrantRateLimiterRole.sol -vvvv --broadcast --ledger --sender {{sender}} --verify

[group('deploy')]
deploy-grant-pauser-role:
    #!/bin/bash
    set -euo pipefail
    forge script script/GrantPauserRole.sol -vvvv --broadcast --ledger --sender {{sender}} --verify

[group('deploy')]
deploy-grant-unpauser-role:
    #!/bin/bash
    set -euo pipefail
    forge script script/GrantUnPauserRole.sol -vvvv --broadcast --ledger --sender {{sender}} --verify

[group('deploy')]
deploy-grant-token-operator-role:
    #!/bin/bash
    set -euo pipefail
    forge script script/GrantTokenOperatorRole.sol -vvvv --broadcast --ledger --sender {{sender}} --verify

[group('deploy')]
deploy-grant-port-customizer-role:
    #!/bin/bash
    set -euo pipefail
    forge script script/GrantPortCustomizerRole.sol -vvvv --broadcast --ledger --sender {{sender}} --verify

[group('deploy')]
deploy-grant-client-id-customizer-role:
    #!/bin/bash
    set -euo pipefail
    forge script script/GrantClientIDCustomizerRole.sol -vvvv --broadcast --ledger --sender {{sender}} --verify

[group('deploy')]
deploy-revoke-relayer-role:
    #!/bin/bash
    set -euo pipefail
    forge script script/RevokeRelayerRole.sol -vvvv --broadcast --ledger --sender {{sender}} --verify

[group('deploy')]
deploy-my-test:
    #!/bin/bash
    set -euo pipefail
    forge script script/GenerateRolesJSON.sol

[group('deploy')]
deploy-grant-role:
    #!/bin/bash
    set -euo pipefail
    export FZF_DEFAULT_OPTS="--height=40%"
    forge script script/GenerateRolesJSON.sol
    contract=$(jq -r ". | keys[]" out/roles.json | fzf)
    export GRANT_CONTRACT_ADDRESS=$(jq -r ".[\"$contract\"].contract_address" out/roles.json)
    role_key=$(jq -r ".[\"$contract\"].roles | keys[]" out/roles.json | fzf)
    export GRANT_ROLE=$(jq -r ".[\"$contract\"].roles[\"$role_key\"]" out/roles.json)
    echo "Granting role $role_key ($GRANT_ROLE) on $contract ($GRANT_CONTRACT_ADDRESS)"
    forge script script/GrantRole.sol -vvvv --broadcast --ledger --sender {{sender}} --verify

[group('deploy')]
deploy-revoke-role:
    #!/bin/bash
    set -euo pipefail
    export FZF_DEFAULT_OPTS="--height=40%"
    forge script script/GenerateRolesJSON.sol
    contract=$(jq -r ". | keys[]" out/roles.json | fzf)
    export REVOKE_CONTRACT_ADDRESS=$(jq -r ".[\"$contract\"].contract_address" out/roles.json)
    role_key=$(jq -r ".[\"$contract\"].roles | keys[]" out/roles.json | fzf)
    export REVOKE_ROLE=$(jq -r ".[\"$contract\"].roles[\"$role_key\"]" out/roles.json)
    echo "Revoking role $role_key ($REVOKE_ROLE) on $contract ($REVOKE_CONTRACT_ADDRESS)"
    forge script script/RevokeRole.sol -vvvv --broadcast --ledger --sender {{sender}} --verify
