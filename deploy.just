environment := env_var_or_default("EUREKA_ENVIRONMENT", "")
chain := env_var_or_default("EUREKA_CHAIN", "")
sender := env_var_or_default("SENDER", "")
eth_rpc := env_var_or_default("ETH_RPC", "")

export FOUNDRY_ETH_RPC_URL := eth_rpc
export DEPLOYMENT_ENV := environment

_verify-solidity-version:
    #!/bin/bash
    set -eou pipefail
    echo "Making sure node_modules are up to date"
    forge clean
    bun install
    solidity_ver=$(jq -r ".dependencies[\"@cosmos/solidity-ibc-eureka\"]" package.json)
    read -p "Please confirm that you want to deploy with solidity version: ${solidity_ver}? (y/n) " -n 1 -r
    echo    # (optional) move to a new line
    if [[ ! $REPLY =~ ^[Yy]$ ]]
    then
        echo "User did not confirm. Aborting deployment!"
        exit 1
    fi

_generate-user-input:
    #!/bin/bash
    set -eou pipefail
    export FZF_DEFAULT_OPTS="--height=40%"
    forge script script/GenerateUserInputJSON.sol:GenerateUserInputJSON

[group('verify')]
[doc('Verifies contract deployments for <chain> in <environment>')]
verify-deployment:
    #!/bin/bash
    set -eou pipefail
    export VERIFY_ONLY=true
    forge script script/DeployProxiedICS26Router.sol
    forge script script/DeployProxiedICS20Transfer.sol
    forge script script/DeploySP1ICS07Tendermint.sol

env-info:
  @echo "Environment: {{environment}}"
  @echo "Chain ID: {{chain}}"

[group('deploy')]
deploy-implementation: _verify-solidity-version _generate-user-input
    #!/bin/bash
    set -euo pipefail
    export LOGIC_CONTRACT=$(jq -r ".implementations[]" out/userinput.json | fzf)
    forge script script/DeployImplementation.sol -vvvv --broadcast --ledger --sender {{sender}} --verify

[group('deploy')]
deploy-ics26-router: _verify-solidity-version
    #!/bin/bash
    set -euo pipefail
    forge script script/DeployProxiedICS26Router.sol -vvvv --broadcast --ledger --sender {{sender}} --verify

[group('deploy')]
deploy-ics20-transfer: _verify-solidity-version
    #!/bin/bash
    set -euo pipefail
    forge script script/DeployProxiedICS20Transfer.sol -vvvv --broadcast --ledger --sender {{sender}} --verify

[group('deploy')]
deploy-light-client: _verify-solidity-version
    #!/bin/bash
    set -euo pipefail
    forge script script/DeploySP1ICS07Tendermint.sol -vvvv --broadcast --ledger --sender {{sender}} --verify

[group('deploy')]
deploy-relayer-helper: _verify-solidity-version
    #!/bin/bash
    set -euo pipefail
    forge script script/DeployRelayerHelper.sol -vvvv --broadcast --ledger --sender {{sender}} --verify

[group('deploy')]
deploy-migrate-light-client: _verify-solidity-version
    #!/bin/bash
    set -euo pipefail
    forge script script/MigrateLightClient.sol -vvvv --broadcast --ledger --sender {{sender}} --verify

[group('deploy')]
deploy-grant-metadata-role: _verify-solidity-version
    #!/bin/bash
    set -euo pipefail
    forge script script/GrantMetadataRole.sol -vvvv --broadcast --ledger --sender {{sender}} --verify

[group('deploy')]
deploy-set-metadata: _verify-solidity-version
    #!/bin/bash
    set -euo pipefail
    forge script script/SetTokenMetadata.sol -vvvv --broadcast --ledger --sender {{sender}} --verify

[group('deploy')]
deploy-grant-rate-limiter-role: _verify-solidity-version
    #!/bin/bash
    set -euo pipefail
    forge script script/GrantRateLimiterRole.sol -vvvv --broadcast --ledger --sender {{sender}} --verify

test-user-input-generation:
    #!/bin/bash
    set -euo pipefail
    forge script script/GenerateUserInputJSON.sol
    jq "." out/userinput.json

[group('deploy')]
deploy-grant-role: _verify-solidity-version _generate-user-input
    #!/bin/bash
    set -euo pipefail
    contract=$(jq -r ". | keys[]" out/userinput.json | fzf)
    export GRANT_CONTRACT_ADDRESS=$(jq -r ".[\"$contract\"].contract_address" out/userinput.json)
    role_key=$(jq -r ".[\"$contract\"].roles | keys[]" out/userinput.json | fzf)
    export GRANT_ROLE=$(jq -r ".[\"$contract\"].roles[\"$role_key\"]" out/userinput.json)
    echo "Granting role $role_key ($GRANT_ROLE) on $contract ($GRANT_CONTRACT_ADDRESS)"
    forge script script/GrantRole.sol -vvvv --broadcast --ledger --sender {{sender}} --verify

[group('deploy')]
deploy-revoke-role: _verify-solidity-version _generate-user-input
    #!/bin/bash
    set -euo pipefail
    contract=$(jq -r ". | keys[]" out/userinput.json | fzf)
    export REVOKE_CONTRACT_ADDRESS=$(jq -r ".[\"$contract\"].contract_address" out/userinput.json)
    role_key=$(jq -r ".[\"$contract\"].roles | keys[]" out/userinput.json | fzf)
    export REVOKE_ROLE=$(jq -r ".[\"$contract\"].roles[\"$role_key\"]" out/userinput.json)
    echo "Revoking role $role_key ($REVOKE_ROLE) on $contract ($REVOKE_CONTRACT_ADDRESS)"
    forge script script/RevokeRole.sol -vvvv --broadcast --ledger --sender {{sender}} --verify

