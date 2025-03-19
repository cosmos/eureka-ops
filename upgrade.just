_schedule-erc1967-upgrade-params type: env-info
  #!/bin/bash
  set -euo pipefail
  deployment=$(cat deployments/{{environment}}/{{chain}}.json)
  timelockAdmin=$(echo $deployment | jq -re ".ics26Router.timeLockAdmin")
  newImplementation=$(echo $deployment | jq -re ".ics20Transfer.implementation")
  proxy=$(echo $deployment | jq -re ".{{type}}.proxy")
  calldata=$(cast calldata "{{upgrade_to_and_call_sig}}" $newImplementation)
  minDelay=$(cast call $timelockAdmin "{{get_min_delay_sig}}")

  echo "function: schedule"
  echo "to: $proxy"
  echo "value: 0"
  echo "data: $calldata"
  echo "predecessor: 0x"
  echo "salt: 0x"
  echo "delay: $minDelay"

_execute-erc1967-upgrade-params type: env-info
  #!/bin/bash
  set -euo pipefail
  deployment=$(cat deployments/{{environment}}/{{chain}}.json)
  newImplementation=$(echo $deployment | jq -re ".{{type}}.implementation")
  proxy=$(echo $deployment | jq -re ".ics20Transfer.proxy")
  calldata=$(cast calldata "{{upgrade_to_and_call_sig}}" $newImplementation)

  echo "function: chedule"
  echo "to: $proxy"
  echo "value: 0"
  echo "data: $calldata"
  echo "predecessor: 0x"
  echo "salt: 0x"

_schedule-beacon-upgrade-params sig type:
  #!/bin/bash
  set -euo pipefail
  deployment=$(cat deployments/{{environment}}/{{chain}}.json)
  timelockAdmin=$(echo $deployment | jq -re ".ics26Router.timeLockAdmin")
  newImplementation=$(echo $deployment | jq -re ".ics20Transfer.{{type}}Implementation")
  proxy=$(echo $deployment | jq -re ".ics20Transfer.proxy")
  calldata=$(cast calldata "{{sig}}" $newImplementation)
  minDelay=$(cast call $timelockAdmin "{{get_min_delay_sig}}")

  echo "function: schedule"
  echo "to: $proxy"
  echo "value: 0"
  echo "data: $calldata"
  echo "predecessor: 0x"
  echo "salt: 0x"
  echo "delay: $minDelay"

_execute-beacon-upgrade-params sig type:
  #!/bin/bash
  set -euo pipefail
  deployment=$(cat deployments/{{environment}}/{{chain}}.json)
  timelockAdmin=$(echo $deployment | jq -re ".ics26Router.timeLockAdmin")
  newImplementation=$(echo $deployment | jq -re ".ics20Transfer.{{type}}Implementation")
  proxy=$(echo $deployment | jq -re ".ics20Transfer.proxy")
  calldata=$(cast calldata "{{sig}}" $newImplementation)

  echo "function: execute"
  echo "to: $proxy"
  echo "value: 0"
  echo "data: $calldata"
  echo "predecessor: 0x"
  echo "salt: 0x"

[group('upgrade-params')]
execute-ics20transfer-upgrade-params: (_execute-erc1967-upgrade-params "ics20Transfer")
[group('upgrade-params')]
schedule-ics20transfer-upgrade-params: (_schedule-erc1967-upgrade-params "ics20Transfer")
[group('upgrade-params')]
execute-ics26router-upgrade-params: (_execute-erc1967-upgrade-params "ics26Router")
[group('upgrade-params')]
schedule-ics26router-upgrade-params: (_schedule-erc1967-upgrade-params "ics26Router")

[group('upgrade-params')]
execute-ibcerc20-upgrade-params: (_execute-beacon-upgrade-params upgrade_ibc_erc20_sig "ibcERC20")
[group('upgrade-params')]
schedule-ibcerc20-upgrade-params: (_schedule-beacon-upgrade-params upgrade_ibc_erc20_sig "ibcERC20")
[group('upgrade-params')]
execute-escrow-upgrade-params: (_execute-beacon-upgrade-params upgrade_escrow_sig "escrow")
[group('upgrade-params')]
schedule-escrow-upgrade-params: (_schedule-beacon-upgrade-params upgrade_escrow_sig "escrow")

[group('upgrade-params')]
schedule-light-client-upgrade-params oldClientIndex newClientIndex:
  #!/bin/bash
  set -euo pipefail
  deployment=$(cat deployments/{{environment}}/{{chain}}.json)
  timelockAdmin=$(echo $deployment | jq -re ".ics26Router.timeLockAdmin")
  oldClientId=$(echo $deployment | jq -re ".light_clients[\"{{oldClientIndex}}\"].clientId")
  newClientId=$(echo $deployment | jq -re ".light_clients[\"{{newClientIndex}}\"].clientId")
  proxy=$(echo $deployment | jq -re ".ics26Router.proxy")
  calldata=$(cast calldata "{{migrate_client_sig}}" $oldClientId $newClientId)
  minDelay=$(cast call $timelockAdmin "{{get_min_delay_sig}}")

  echo "function: schedule"
  echo "to: $proxy"
  echo "value: 0"
  echo "data: $calldata"
  echo "predecessor: 0x"
  echo "salt: 0x"
  echo "delay: $minDelay"

[group('upgrade-params')]
execute-light-client-upgrade-params oldClientIndex newClientIndex:
  #!/bin/bash
  set -euo pipefail
  deployment=$(cat deployments/{{environment}}/{{chain}}.json)
  timelockAdmin=$(echo $deployment | jq -re ".ics26Router.timeLockAdmin")
  oldClientId=$(echo $deployment | jq -re ".light_clients[\"{{oldClientIndex}}\"].clientId")
  newClientId=$(echo $deployment | jq -re ".light_clients[\"{{newClientIndex}}\"].clientId")
  proxy=$(echo $deployment | jq -re ".ics26Router.proxy")
  calldata=$(cast calldata "{{migrate_client_sig}}" $oldClientId $newClientId)

  echo "function: schedule"
  echo "to: $proxy"
  echo "value: 0"
  echo "data: $calldata"
  echo "predecessor: 0x"
  echo "salt: 0x"