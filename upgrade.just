_schedule-erc1967-upgrade-params type: info-env
  #!/bin/bash
  set -euo pipefail
  deployment=$(cat deployments/{{environment}}/{{chain}}.json)
  timelockAdmin=$(echo $deployment | jq -re ".ics26Router.timelockAdmin")
  newImplementation=$(echo $deployment | jq -re ".{{type}}.implementation")
  proxy=$(echo $deployment | jq -re ".{{type}}.proxy")
  calldata=$(cast calldata "{{UPGRADE_TO_AND_CALL_SIG}}" $newImplementation 0x)
  minDelay=$(cast call $timelockAdmin "{{GET_MIN_DELAY_SIG}}")

  echo "function: schedule"
  echo "to: $proxy"
  echo "value: 0"
  echo "data: $calldata"
  echo "predecessor: 0x"
  echo "salt: 0x"
  echo "delay: $minDelay"
  data=$({{cast_binary}} calldata "schedule(address,uint256,bytes calldata,bytes32,bytes32,uint256)" $proxy 0 $calldata {{zero_bytes32}} {{zero_bytes32}} $minDelay)
  echo "timelock calldata: $data"

_execute-erc1967-upgrade-params nonce type: info-env
  #!/bin/bash
  set -euo pipefail
  deployment=$(cat deployments/{{environment}}/{{chain}}.json)
  timelockAdmin=$(echo $deployment | jq -re ".ics26Router.timelockAdmin")
  newImplementation=$(echo $deployment | jq -re ".{{type}}.implementation")
  proxy=$(echo $deployment | jq -re ".{{type}}.proxy")
  calldata=$({{cast_binary}} calldata "{{UPGRADE_TO_AND_CALL_SIG}}" $newImplementation 0x)

  echo "function: execute"
  echo "to: $proxy"
  echo "value: 0"
  echo "data: $calldata"
  echo "predecessor: 0x"
  echo "salt: 0x"
  data=$({{cast_binary}} calldata "execute(address,uint256,bytes calldata,bytes32,bytes32)" $proxy 0 $calldata {{zero_bytes32}} {{zero_bytes32}})
  echo "timelock calldata: $data"

_schedule-v3-erc1967-upgrade-params nonce type: info-env
  #!/bin/bash
  set -euo pipefail
  deployment=$(cat deployments/{{environment}}/{{chain}}.json)
  timelockAdmin=$(echo $deployment | jq -re ".ics26Router.timelockAdmin")
  accessManager=$(echo $deployment | jq -re ".accessManager")
  if [ "$accessManager" = "{{zero_address}}" ]; then
    echo "AccessManager is not set in deployments/{{environment}}/{{chain}}.json. Run deploy-v3-access-manager before generating v3 upgrade params."
    exit 1
  fi
  newImplementation=$(echo $deployment | jq -re ".{{type}}.implementation")
  proxy=$(echo $deployment | jq -re ".{{type}}.proxy")
  initCalldata=$({{cast_binary}} calldata "{{INITIALIZE_V2_SIG}}" $accessManager)
  calldata=$({{cast_binary}} calldata "{{UPGRADE_TO_AND_CALL_SIG}}" $newImplementation $initCalldata)
  minDelay=$({{cast_binary}} call $timelockAdmin "{{GET_MIN_DELAY_SIG}}")

  echo "function: schedule"
  echo "to: $proxy"
  echo "value: 0"
  echo "data: $calldata"
  echo "predecessor: 0x"
  echo "salt: 0x"
  echo "delay: $minDelay"
  data=$({{cast_binary}} calldata "schedule(address,uint256,bytes calldata,bytes32,bytes32,uint256)" $proxy 0 $calldata {{zero_bytes32}} {{zero_bytes32}} $minDelay)
  echo "timelock calldata: $data"
  if [ -n "{{nonce}}" ]; then
    {{just}} get_safe_hashes {{nonce}} $data $timelockAdmin
  fi

_execute-v3-erc1967-upgrade-params nonce type: info-env
  #!/bin/bash
  set -euo pipefail
  deployment=$(cat deployments/{{environment}}/{{chain}}.json)
  timelockAdmin=$(echo $deployment | jq -re ".ics26Router.timelockAdmin")
  accessManager=$(echo $deployment | jq -re ".accessManager")
  if [ "$accessManager" = "{{zero_address}}" ]; then
    echo "AccessManager is not set in deployments/{{environment}}/{{chain}}.json. Run deploy-v3-access-manager before generating v3 upgrade params."
    exit 1
  fi
  newImplementation=$(echo $deployment | jq -re ".{{type}}.implementation")
  proxy=$(echo $deployment | jq -re ".{{type}}.proxy")
  initCalldata=$({{cast_binary}} calldata "{{INITIALIZE_V2_SIG}}" $accessManager)
  calldata=$({{cast_binary}} calldata "{{UPGRADE_TO_AND_CALL_SIG}}" $newImplementation $initCalldata)

  echo "function: execute"
  echo "to: $proxy"
  echo "value: 0"
  echo "data: $calldata"
  echo "predecessor: 0x"
  echo "salt: 0x"
  data=$({{cast_binary}} calldata "execute(address,uint256,bytes calldata,bytes32,bytes32)" $proxy 0 $calldata {{zero_bytes32}} {{zero_bytes32}})
  echo "timelock calldata: $data"
  if [ -n "{{nonce}}" ]; then
    {{just}} get_safe_hashes {{nonce}} $data $timelockAdmin
  fi

_schedule-beacon-upgrade-params nonce sig type:
  #!/bin/bash
  set -euo pipefail
  deployment=$(cat deployments/{{environment}}/{{chain}}.json)
  timelockAdmin=$(echo $deployment | jq -re ".ics26Router.timelockAdmin")
  newImplementation=$(echo $deployment | jq -re ".ics20Transfer.{{type}}Implementation")
  proxy=$(echo $deployment | jq -re ".ics20Transfer.proxy")
  calldata=$({{cast_binary}} calldata "{{sig}}" $newImplementation)
  minDelay=$({{cast_binary}} call $timelockAdmin "{{GET_MIN_DELAY_SIG}}")

  echo "function: schedule"
  echo "to: $proxy"
  echo "value: 0"
  echo "data: $calldata"
  echo "predecessor: 0x"
  echo "salt: 0x"
  echo "delay: $minDelay"
  data=$({{cast_binary}} calldata "schedule(address,uint256,bytes calldata,bytes32,bytes32,uint256)" $proxy 0 $calldata {{zero_bytes32}} {{zero_bytes32}} $minDelay)
  echo "timelock calldata: $data"
  if [ -n "{{nonce}}" ]; then
    {{just}} get_safe_hashes {{nonce}} $data $timelockAdmin
  fi

_execute-beacon-upgrade-params nonce sig type:
  #!/bin/bash
  set -euo pipefail
  deployment=$(cat deployments/{{environment}}/{{chain}}.json)
  timelockAdmin=$(echo $deployment | jq -re ".ics26Router.timelockAdmin")
  newImplementation=$(echo $deployment | jq -re ".ics20Transfer.{{type}}Implementation")
  proxy=$(echo $deployment | jq -re ".ics20Transfer.proxy")
  calldata=$({{cast_binary}} calldata "{{sig}}" $newImplementation)

  echo "function: execute"
  echo "to: $proxy"
  echo "value: 0"
  echo "data: $calldata"
  echo "predecessor: 0x"
  echo "salt: 0x"

  data=$({{cast_binary}} calldata "execute(address,uint256,bytes calldata,bytes32,bytes32)" $proxy 0 $calldata {{zero_bytes32}} {{zero_bytes32}})
  {{just}} get_safe_hashes {{nonce}} $data $timelockAdmin

_v3-light-client-migration-calldata client_id:
  #!/bin/bash
  set -euo pipefail
  deployment_path="deployments/{{environment}}/{{chain}}.json"
  deployment=$(cat "$deployment_path")
  match_count=$(echo "$deployment" | jq --arg client_id "{{client_id}}" '[.light_clients[] | select(.clientId == $client_id)] | length')
  if [ "$match_count" -ne 1 ]; then
    echo "Expected exactly one light client with clientId {{client_id}} in $deployment_path, found $match_count."
    exit 1
  fi

  client=$(echo "$deployment" | jq -c --arg client_id "{{client_id}}" '.light_clients[] | select(.clientId == $client_id)')
  newImplementation=$(echo "$client" | jq -re ".implementation")
  if [ "$newImplementation" = "{{zero_address}}" ]; then
    echo "Light client {{client_id}} has zero implementation in $deployment_path. Deploy the new SP1 light client first."
    exit 1
  fi

  counterpartyClientId=$(echo "$client" | jq -re ".counterpartyClientId")
  merklePrefixHexes=()
  while IFS= read -r prefix; do
    merklePrefixHexes+=("$({{cast_binary}} from-utf8 "$prefix")")
  done < <(echo "$client" | jq -re ".merklePrefix[]")

  merklePrefixArray=$(IFS=,; echo "[${merklePrefixHexes[*]}]")
  counterpartyInfo="($counterpartyClientId,$merklePrefixArray)"
  {{cast_binary}} calldata "{{MIGRATE_CLIENT_V3_SIG}}" "{{client_id}}" "$counterpartyInfo" "$newImplementation"

_schedule-v3-light-client-migration-params client_id nonce: info-env
  #!/bin/bash
  set -euo pipefail
  deployment=$(cat deployments/{{environment}}/{{chain}}.json)
  timelockAdmin=$(echo "$deployment" | jq -re ".ics26Router.timelockAdmin")
  proxy=$(echo "$deployment" | jq -re ".ics26Router.proxy")
  calldata=$({{just}} _v3-light-client-migration-calldata "{{client_id}}")
  minDelay=$({{cast_binary}} call $timelockAdmin "{{GET_MIN_DELAY_SIG}}")

  echo "function: schedule"
  echo "to: $proxy"
  echo "value: 0"
  echo "data: $calldata"
  echo "predecessor: 0x"
  echo "salt: 0x"
  echo "delay: $minDelay"
  data=$({{cast_binary}} calldata "schedule(address,uint256,bytes calldata,bytes32,bytes32,uint256)" $proxy 0 $calldata {{zero_bytes32}} {{zero_bytes32}} $minDelay)
  echo "timelock calldata: $data"
  if [ -n "{{nonce}}" ]; then
    {{just}} get_safe_hashes {{nonce}} $data $timelockAdmin
  fi

_execute-v3-light-client-migration-params client_id nonce: info-env
  #!/bin/bash
  set -euo pipefail
  deployment=$(cat deployments/{{environment}}/{{chain}}.json)
  timelockAdmin=$(echo "$deployment" | jq -re ".ics26Router.timelockAdmin")
  proxy=$(echo "$deployment" | jq -re ".ics26Router.proxy")
  calldata=$({{just}} _v3-light-client-migration-calldata "{{client_id}}")

  echo "function: execute"
  echo "to: $proxy"
  echo "value: 0"
  echo "data: $calldata"
  echo "predecessor: 0x"
  echo "salt: 0x"
  data=$({{cast_binary}} calldata "execute(address,uint256,bytes calldata,bytes32,bytes32)" $proxy 0 $calldata {{zero_bytes32}} {{zero_bytes32}})
  echo "timelock calldata: $data"
  if [ -n "{{nonce}}" ]; then
    {{just}} get_safe_hashes {{nonce}} $data $timelockAdmin
  fi

[group('upgrade-params')]
execute-ics20transfer-upgrade-params nonce: (_execute-erc1967-upgrade-params nonce "ics20Transfer")

[group('upgrade-params')]
schedule-ics20transfer-upgrade-params: (_schedule-erc1967-upgrade-params "ics20Transfer")

[group('upgrade-params')]
execute-v3-ics20transfer-upgrade-params nonce="": (_execute-v3-erc1967-upgrade-params nonce "ics20Transfer")

[group('upgrade-params')]
schedule-v3-ics20transfer-upgrade-params nonce="": (_schedule-v3-erc1967-upgrade-params nonce "ics20Transfer")

[group('upgrade-params')]
execute-ics26router-upgrade-params nonce: (_execute-erc1967-upgrade-params nonce "ics26Router")

[group('upgrade-params')]
schedule-ics26router-upgrade-params: (_schedule-erc1967-upgrade-params "ics26Router")

[group('upgrade-params')]
execute-v3-ics26router-upgrade-params nonce="": (_execute-v3-erc1967-upgrade-params nonce "ics26Router")

[group('upgrade-params')]
schedule-v3-ics26router-upgrade-params nonce="": (_schedule-v3-erc1967-upgrade-params nonce "ics26Router")

[group('upgrade-params')]
execute-ibcerc20-upgrade-params nonce: (_execute-beacon-upgrade-params nonce UPGRADE_IBC_ERC20_SIG "ibcERC20")

[group('upgrade-params')]
schedule-ibcerc20-upgrade-params nonce="": (_schedule-beacon-upgrade-params nonce UPGRADE_IBC_ERC20_SIG "ibcERC20")

[group('upgrade-params')]
execute-escrow-upgrade-params nonce: (_execute-beacon-upgrade-params nonce UPGRADE_ESCROW_SIG "escrow")

[group('upgrade-params')]
schedule-escrow-upgrade-params nonce="": (_schedule-beacon-upgrade-params nonce UPGRADE_ESCROW_SIG "escrow")

[group('upgrade-params')]
schedule-v3-light-client-migration-params client_id nonce="": (_schedule-v3-light-client-migration-params client_id nonce)

[group('upgrade-params')]
execute-v3-light-client-migration-params client_id nonce="": (_execute-v3-light-client-migration-params client_id nonce)

[group('upgrade-params')]
initialize-escrow-v2-params client_id: info-env
  #!/bin/bash
  set -euo pipefail
  deployment=$(cat deployments/{{environment}}/{{chain}}.json)
  ics20=$(echo $deployment | jq -re ".ics20Transfer.proxy")
  escrow=$({{cast_binary}} call $ics20 "getEscrow(string)(address)" "{{client_id}}")
  if [ "$escrow" = "{{zero_address}}" ]; then
    echo "No escrow found for client id {{client_id}}"
    exit 1
  fi
  calldata=$({{cast_binary}} calldata "{{INITIALIZE_ESCROW_V2_SIG}}")

  echo "function: initializeV2"
  echo "to: $escrow"
  echo "value: 0"
  echo "data: $calldata"

[group('upgrade-params')]
initialize-known-escrows-v2-params: info-env
  #!/bin/bash
  set -euo pipefail
  deployment_path="deployments/{{environment}}/{{chain}}.json"
  deployment=$(cat "$deployment_path")
  ics20=$(echo "$deployment" | jq -re ".ics20Transfer.proxy")
  calldata=$({{cast_binary}} calldata "{{INITIALIZE_ESCROW_V2_SIG}}")

  while IFS= read -r client_id; do
    if [ -z "$client_id" ]; then
      continue
    fi

    escrow=$({{cast_binary}} call "$ics20" "getEscrow(string)(address)" "$client_id")
    if [ "$escrow" = "{{zero_address}}" ]; then
      continue
    fi

    echo "client_id: $client_id"
    echo "function: initializeV2"
    echo "to: $escrow"
    echo "value: 0"
    echo "data: $calldata"

    echo
  done < <(echo "$deployment" | jq -r '.light_clients[]?.clientId // empty')
