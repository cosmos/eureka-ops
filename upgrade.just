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

_execute-erc1967-upgrade-params safe_address nonce type: info-env
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

_schedule-beacon-upgrade-params sig type:
  #!/bin/bash
  set -euo pipefail
  deployment=$(cat deployments/{{environment}}/{{chain}}.json)
  timelockAdmin=$(echo $deployment | jq -re ".ics26Router.timelockAdmin")
  newImplementation=$(echo $deployment | jq -re ".ics20Transfer.{{type}}Implementation")
  proxy=$(echo $deployment | jq -re ".ics20Transfer.proxy")
  calldata=$({{cast_binary}} calldata "{{sig}}" $newImplementation 0x)
  minDelay=$({{cast_binary}} call $timelockAdmin "{{GET_MIN_DELAY_SIG}}")

  echo "function: schedule"
  echo "to: $proxy"
  echo "value: 0"
  echo "data: $calldata"
  echo "predecessor: 0x"
  echo "salt: 0x"
  echo "delay: $minDelay"

_execute-beacon-upgrade-params safe_address nonce sig type:
  #!/bin/bash
  set -euo pipefail
  deployment=$(cat deployments/{{environment}}/{{chain}}.json)
  timelockAdmin=$(echo $deployment | jq -re ".ics26Router.timelockAdmin")
  newImplementation=$(echo $deployment | jq -re ".ics20Transfer.{{type}}Implementation")
  proxy=$(echo $deployment | jq -re ".ics20Transfer.proxy")
  calldata=$({{cast_binary}} calldata "{{sig}}" $newImplementation 0x)

  echo "function: execute"
  echo "to: $proxy"
  echo "value: 0"
  echo "data: $calldata"
  echo "predecessor: 0x"
  echo "salt: 0x"

  data=$({{cast_binary}} calldata "execute(address,uint256,bytes calldata,bytes32,bytes32)" $proxy 0 $calldata {{zero_bytes32}} {{zero_bytes32}})
  {{just}} get_safe_hashes {{safe_address}} {{nonce}} $data $timelockAdmin

[group('upgrade-params')]
execute-ics20transfer-upgrade-params safe_address nonce: (_execute-erc1967-upgrade-params safe_address nonce "ics20Transfer")

[group('upgrade-params')]
schedule-ics20transfer-upgrade-params: (_schedule-erc1967-upgrade-params "ics20Transfer")

[group('upgrade-params')]
execute-ics26router-upgrade-params safe_address nonce: (_execute-erc1967-upgrade-params safe_address nonce "ics26Router")

[group('upgrade-params')]
schedule-ics26router-upgrade-params: (_schedule-erc1967-upgrade-params "ics26Router")

[group('upgrade-params')]
execute-ibcerc20-upgrade-params safe_address nonce: (_execute-beacon-upgrade-params safe_address nonce UPGRADE_IBC_ERC20_SIG "ibcERC20")

[group('upgrade-params')]
schedule-ibcerc20-upgrade-params: (_schedule-beacon-upgrade-params UPGRADE_IBC_ERC20_SIG "ibcERC20")

[group('upgrade-params')]
execute-escrow-upgrade-params safe_address nonce: (_execute-beacon-upgrade-params safe_address nonce UPGRADE_ESCROW_SIG "escrow")

[group('upgrade-params')]
schedule-escrow-upgrade-params: (_schedule-beacon-upgrade-params UPGRADE_ESCROW_SIG "escrow")

[group('upgrade-params')]
schedule-light-client-upgrade-params safe_address nonce oldClientIndex newClientIndex:
  #!/bin/bash
  set -euo pipefail
  deployment=$(cat deployments/{{environment}}/{{chain}}.json)
  timelockAdmin=$(echo $deployment | jq -re ".ics26Router.timelockAdmin")
  oldClientId=$(echo $deployment | jq -re ".light_clients[\"{{oldClientIndex}}\"].clientId")
  newClientId=$(echo $deployment | jq -re ".light_clients[\"{{newClientIndex}}\"].clientId")
  proxy=$(echo $deployment | jq -re ".ics26Router.proxy")
  calldata=$({{cast_binary}} calldata "{{MIGRATE_CLIENT_SIG}}" $oldClientId $newClientId)
  minDelay=$({{cast_binary}} call $timelockAdmin "{{GET_MIN_DELAY_SIG}}")

  echo "function: schedule"
  echo "to: $proxy"
  echo "value: 0"
  echo "data: $calldata"
  echo "predecessor: 0x"
  echo "salt: 0x"
  echo "delay: $minDelay"
  data=$({{cast_binary}} calldata "execute(address,uint256,bytes calldata,bytes32,bytes32)" $proxy 0 $calldata {{zero_bytes32}} {{zero_bytes32}})
  {{just}} get_safe_hashes {{safe_address}} {{nonce}} $data $timelockAdmin

[group('upgrade-params')]
execute-light-client-upgrade-params safe_address nonce oldClientIndex newClientIndex:
  #!/bin/bash
  set -euxo pipefail
  deployment=$(cat deployments/{{environment}}/{{chain}}.json)
  timelockAdmin=$(echo $deployment | jq -re ".ics26Router.timelockAdmin")
  oldClientId=$(echo $deployment | jq -re ".light_clients[\"{{oldClientIndex}}\"].clientId")
  newClientId=$(echo $deployment | jq -re ".light_clients[\"{{newClientIndex}}\"].clientId")
  proxy=$(echo $deployment | jq -re ".ics26Router.proxy")
  calldata=$({{cast_binary}} calldata "{{MIGRATE_CLIENT_SIG}}" $oldClientId $newClientId)

  echo "function: schedule"
  echo "to: $proxy"
  echo "value: 0"
  echo "data: $calldata"
  echo "predecessor: 0x"
  echo "salt: 0x"
  data=$({{cast_binary}} calldata "execute(address,uint256,bytes calldata,bytes32,bytes32)" $proxy 0 $calldata {{zero_bytes32}} {{zero_bytes32}})
  {{just}} get_safe_hashes {{safe_address}} {{nonce}} $data $timelockAdmin
