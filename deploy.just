environment := env_var_or_default("EUREKA_ENVIRONMENT", "")
chain := env_var_or_default("EUREKA_CHAIN", "")
export FOUNDRY_ETH_RPC_URL := if environment == "" { "" } else if chain == "" { "" } else { `jq -re '.rpc_url' deployments/$EUREKA_ENVIRONMENT/$EUREKA_CHAIN.json` }

[group('upgrade')]
[doc('Deploys a new implementation of Escrow')]
deploy-escrow: env-info (_new-deployment "Escrow" "ics20Transfer.escrowImplementation")

[group('upgrade')]
[doc('Deploys a new implementation of IBCERC20')]
deploy-ibcerc20: env-info (_new-deployment "IBCERC20" "ics20Transfer.ibcERC20Implementation")

[group('upgrade')]
[doc('Deploys a new implementation of ICS20Transfer')]
deploy-transfer: env-info (_new-deployment "ICS20Transfer" "ics20Transfer.implementation")

[group('upgrade')]
[doc('Deploys a new implementation of ICS26Router')]
deploy-router: (_new-deployment "ICS26Router" "ics26Router.implementation")

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
    set -euo pipefail
    output=$({{forge_command}} create --broadcast --chain-id {{chain}} {{forge_flags}} --json {{contract}})
    deploymentAddress=$(echo $output | jq -re .deployedTo) 
    echo "{{contract}} deployed to $deploymentAddress";
    just -f {{justfile()}} _update-deployment {{key}} $deploymentAddress {{environment}} {{chain}}

env-info:
  @echo "Environment: {{environment}}"
  @echo "Chain ID: {{chain}}"