# Refuses an empty-calldata UUPS upgrade when the proxy is not yet AccessManaged by the recorded AccessManager.
# During the v2-to-v3 upgrade ICS26Router/ICS20Transfer must be upgraded with initializeV2 calldata via the
# schedule-v3-* recipes; an empty-calldata upgrade then would leave the proxy without an authority and brick it.
_require-already-access-managed proxy:
  #!/bin/bash
  set -euo pipefail
  deployment=$(cat deployments/{{environment}}/{{chain}}.json)
  accessManager=$(echo $deployment | jq -r ".accessManager // \"{{zero_address}}\"")
  if [ "$accessManager" = "{{zero_address}}" ]; then
    # Pre-v3 deployment (no AccessManager): the legacy empty-calldata upgrade is the intended behavior.
    exit 0
  fi
  authority=$({{cast_binary}} call "{{proxy}}" "authority()(address)" 2>/dev/null || echo "{{zero_address}}")
  if [ "$(echo "$authority" | tr 'A-Z' 'a-z')" != "$(echo "$accessManager" | tr 'A-Z' 'a-z')" ]; then
    echo "Proxy {{proxy}} is not yet AccessManaged by $accessManager."
    echo "For the v2-to-v3 upgrade use the schedule-v3-*/execute-v3-*-upgrade-params recipes (they call initializeV2)."
    echo "See runbooks/upgrade-v2-to-v3.md."
    exit 1
  fi

_schedule-erc1967-upgrade-params nonce type: info-env
  #!/bin/bash
  set -euo pipefail
  deployment=$(cat deployments/{{environment}}/{{chain}}.json)
  timelockAdmin=$(echo $deployment | jq -re "(.accessManagerRoles.admin // .ics26Router.timelockAdmin)")
  newImplementation=$(echo $deployment | jq -re ".{{type}}.implementation")
  proxy=$(echo $deployment | jq -re ".{{type}}.proxy")
  {{just}} _require-already-access-managed "$proxy"
  calldata=$({{cast_binary}} calldata "{{UPGRADE_TO_AND_CALL_SIG}}" $newImplementation 0x)
  minDelay=$({{cast_binary}} call $timelockAdmin "{{GET_MIN_DELAY_SIG}}" | awk '{print $1}')

  echo "function: schedule"
  echo "to: $proxy"
  echo "value: 0"
  echo "data: $calldata"
  echo "predecessor: {{zero_bytes32}}"
  echo "salt: {{zero_bytes32}}"
  echo "delay: $minDelay"
  data=$({{cast_binary}} calldata "schedule(address,uint256,bytes calldata,bytes32,bytes32,uint256)" $proxy 0 $calldata {{zero_bytes32}} {{zero_bytes32}} $minDelay)
  echo "timelock calldata: $data"
  if [ -n "{{nonce}}" ]; then
    {{just}} get_safe_hashes {{nonce}} $data $timelockAdmin
  fi

_execute-erc1967-upgrade-params nonce type: info-env
  #!/bin/bash
  set -euo pipefail
  deployment=$(cat deployments/{{environment}}/{{chain}}.json)
  timelockAdmin=$(echo $deployment | jq -re "(.accessManagerRoles.admin // .ics26Router.timelockAdmin)")
  newImplementation=$(echo $deployment | jq -re ".{{type}}.implementation")
  proxy=$(echo $deployment | jq -re ".{{type}}.proxy")
  {{just}} _require-already-access-managed "$proxy"
  calldata=$({{cast_binary}} calldata "{{UPGRADE_TO_AND_CALL_SIG}}" $newImplementation 0x)

  echo "function: execute"
  echo "to: $proxy"
  echo "value: 0"
  echo "data: $calldata"
  echo "predecessor: {{zero_bytes32}}"
  echo "salt: {{zero_bytes32}}"
  data=$({{cast_binary}} calldata "execute(address,uint256,bytes calldata,bytes32,bytes32)" $proxy 0 $calldata {{zero_bytes32}} {{zero_bytes32}})
  echo "timelock calldata: $data"
  if [ -n "{{nonce}}" ]; then
    {{just}} get_safe_hashes {{nonce}} $data $timelockAdmin
  fi

_schedule-v3-erc1967-upgrade-params nonce type predecessor=zero_bytes32: info-env
  #!/bin/bash
  set -euo pipefail
  deployment=$(cat deployments/{{environment}}/{{chain}}.json)
  timelockAdmin=$(echo $deployment | jq -re "(.accessManagerRoles.admin // .ics26Router.timelockAdmin)")
  accessManager=$(echo $deployment | jq -re ".accessManager")
  if [ "$accessManager" = "{{zero_address}}" ]; then
    echo "AccessManager is not set in deployments/{{environment}}/{{chain}}.json. Run deploy-v3-access-manager before generating v3 upgrade params."
    exit 1
  fi
  newImplementation=$(echo $deployment | jq -re ".{{type}}.implementation")
  proxy=$(echo $deployment | jq -re ".{{type}}.proxy")
  initCalldata=$({{cast_binary}} calldata "{{INITIALIZE_V2_SIG}}" $accessManager)
  calldata=$({{cast_binary}} calldata "{{UPGRADE_TO_AND_CALL_SIG}}" $newImplementation $initCalldata)
  minDelay=$({{cast_binary}} call $timelockAdmin "{{GET_MIN_DELAY_SIG}}" | awk '{print $1}')

  echo "function: schedule"
  echo "to: $proxy"
  echo "value: 0"
  echo "data: $calldata"
  echo "predecessor: {{predecessor}}"
  echo "salt: {{zero_bytes32}}"
  echo "delay: $minDelay"
  data=$({{cast_binary}} calldata "schedule(address,uint256,bytes calldata,bytes32,bytes32,uint256)" $proxy 0 $calldata {{predecessor}} {{zero_bytes32}} $minDelay)
  echo "timelock calldata: $data"
  if [ -n "{{nonce}}" ]; then
    {{just}} get_safe_hashes {{nonce}} $data $timelockAdmin
  fi

_execute-v3-erc1967-upgrade-params nonce type predecessor=zero_bytes32: info-env
  #!/bin/bash
  set -euo pipefail
  deployment=$(cat deployments/{{environment}}/{{chain}}.json)
  timelockAdmin=$(echo $deployment | jq -re "(.accessManagerRoles.admin // .ics26Router.timelockAdmin)")
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
  echo "predecessor: {{predecessor}}"
  echo "salt: {{zero_bytes32}}"
  data=$({{cast_binary}} calldata "execute(address,uint256,bytes calldata,bytes32,bytes32)" $proxy 0 $calldata {{predecessor}} {{zero_bytes32}})
  echo "timelock calldata: $data"
  if [ -n "{{nonce}}" ]; then
    {{just}} get_safe_hashes {{nonce}} $data $timelockAdmin
  fi

# Computes the TimelockController operation id of the v3 ICS20Transfer upgrade, so the ICS26Router upgrade can
# set it as its predecessor. This makes the timelock enforce ICS20-before-ICS26 ordering on-chain: the router
# execute reverts until the ICS20 op is done. Mis-ordering would otherwise permanently brick the ICS20 upgrade
# path (v3 router deinitializes the legacy admin that v2 ICS20Transfer.upgradeToAndCall authenticates against).
_v3-ics20-upgrade-operation-id:
  #!/bin/bash
  set -euo pipefail
  deployment=$(cat deployments/{{environment}}/{{chain}}.json)
  timelockAdmin=$(echo $deployment | jq -re "(.accessManagerRoles.admin // .ics26Router.timelockAdmin)")
  accessManager=$(echo $deployment | jq -re ".accessManager")
  ics20proxy=$(echo $deployment | jq -re ".ics20Transfer.proxy")
  ics20impl=$(echo $deployment | jq -re ".ics20Transfer.implementation")
  # The predecessor must match the ICS20 upgrade operation exactly; bail if the inputs it is built from are
  # unset, otherwise the ICS26Router upgrade would be scheduled against a predecessor that never executes.
  if [ "$accessManager" = "{{zero_address}}" ]; then
    echo "AccessManager is not set in deployments/{{environment}}/{{chain}}.json. Run deploy-v3-access-manager first." >&2
    exit 1
  fi
  if [ "$ics20impl" = "{{zero_address}}" ]; then
    echo "ICS20Transfer implementation is zero in deployments/{{environment}}/{{chain}}.json. Set it (runbook step 4) before scheduling the ICS26Router upgrade." >&2
    exit 1
  fi
  initCalldata=$({{cast_binary}} calldata "{{INITIALIZE_V2_SIG}}" $accessManager)
  ics20calldata=$({{cast_binary}} calldata "{{UPGRADE_TO_AND_CALL_SIG}}" $ics20impl $initCalldata)
  {{cast_binary}} call $timelockAdmin "hashOperation(address,uint256,bytes,bytes32,bytes32)(bytes32)" $ics20proxy 0 $ics20calldata {{zero_bytes32}} {{zero_bytes32}}

_schedule-beacon-upgrade-params nonce sig impl_path proxy_path:
  #!/bin/bash
  set -euo pipefail
  deployment=$(cat deployments/{{environment}}/{{chain}}.json)
  timelockAdmin=$(echo $deployment | jq -re "(.accessManagerRoles.admin // .ics26Router.timelockAdmin)")
  newImplementation=$(echo $deployment | jq -re "{{impl_path}}")
  proxy=$(echo $deployment | jq -re "{{proxy_path}}")
  calldata=$({{cast_binary}} calldata "{{sig}}" $newImplementation)
  minDelay=$({{cast_binary}} call $timelockAdmin "{{GET_MIN_DELAY_SIG}}" | awk '{print $1}')

  echo "function: schedule"
  echo "to: $proxy"
  echo "value: 0"
  echo "data: $calldata"
  echo "predecessor: {{zero_bytes32}}"
  echo "salt: {{zero_bytes32}}"
  echo "delay: $minDelay"
  data=$({{cast_binary}} calldata "schedule(address,uint256,bytes calldata,bytes32,bytes32,uint256)" $proxy 0 $calldata {{zero_bytes32}} {{zero_bytes32}} $minDelay)
  echo "timelock calldata: $data"
  if [ -n "{{nonce}}" ]; then
    {{just}} get_safe_hashes {{nonce}} $data $timelockAdmin
  fi

_execute-beacon-upgrade-params nonce sig impl_path proxy_path:
  #!/bin/bash
  set -euo pipefail
  deployment=$(cat deployments/{{environment}}/{{chain}}.json)
  timelockAdmin=$(echo $deployment | jq -re "(.accessManagerRoles.admin // .ics26Router.timelockAdmin)")
  newImplementation=$(echo $deployment | jq -re "{{impl_path}}")
  proxy=$(echo $deployment | jq -re "{{proxy_path}}")
  calldata=$({{cast_binary}} calldata "{{sig}}" $newImplementation)

  echo "function: execute"
  echo "to: $proxy"
  echo "value: 0"
  echo "data: $calldata"
  echo "predecessor: {{zero_bytes32}}"
  echo "salt: {{zero_bytes32}}"

  data=$({{cast_binary}} calldata "execute(address,uint256,bytes calldata,bytes32,bytes32)" $proxy 0 $calldata {{zero_bytes32}} {{zero_bytes32}})
  echo "timelock calldata: $data"
  if [ -n "{{nonce}}" ]; then
    {{just}} get_safe_hashes {{nonce}} $data $timelockAdmin
  fi

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

  # Require a non-empty merkle prefix. An empty/missing prefix would otherwise produce valid-looking migrateClient
  # calldata with an empty bytes[] (silently breaking all packet proof verification for the client), and on bash
  # 3.2 an empty array would also trip `set -u`. This mirrors the Solidity assert in the shadow rehearsal.
  merklePrefixCount=$(echo "$client" | jq -re ".merklePrefix | length")
  if [ "$merklePrefixCount" -eq 0 ]; then
    echo "Light client {{client_id}} has an empty or missing merklePrefix in $deployment_path."
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
  timelockAdmin=$(echo "$deployment" | jq -re "(.accessManagerRoles.admin // .ics26Router.timelockAdmin)")
  proxy=$(echo "$deployment" | jq -re ".ics26Router.proxy")
  calldata=$({{just}} _v3-light-client-migration-calldata "{{client_id}}")
  minDelay=$({{cast_binary}} call $timelockAdmin "{{GET_MIN_DELAY_SIG}}" | awk '{print $1}')

  echo "function: schedule"
  echo "to: $proxy"
  echo "value: 0"
  echo "data: $calldata"
  echo "predecessor: {{zero_bytes32}}"
  echo "salt: {{zero_bytes32}}"
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
  timelockAdmin=$(echo "$deployment" | jq -re "(.accessManagerRoles.admin // .ics26Router.timelockAdmin)")
  proxy=$(echo "$deployment" | jq -re ".ics26Router.proxy")
  calldata=$({{just}} _v3-light-client-migration-calldata "{{client_id}}")

  echo "function: execute"
  echo "to: $proxy"
  echo "value: 0"
  echo "data: $calldata"
  echo "predecessor: {{zero_bytes32}}"
  echo "salt: {{zero_bytes32}}"
  data=$({{cast_binary}} calldata "execute(address,uint256,bytes calldata,bytes32,bytes32)" $proxy 0 $calldata {{zero_bytes32}} {{zero_bytes32}})
  echo "timelock calldata: $data"
  if [ -n "{{nonce}}" ]; then
    {{just}} get_safe_hashes {{nonce}} $data $timelockAdmin
  fi

[group('upgrade-params')]
execute-ics20transfer-upgrade-params nonce="": (_execute-erc1967-upgrade-params nonce "ics20Transfer")

[group('upgrade-params')]
schedule-ics20transfer-upgrade-params nonce="": (_schedule-erc1967-upgrade-params nonce "ics20Transfer")

[group('upgrade-params')]
execute-v3-ics20transfer-upgrade-params nonce="": (_execute-v3-erc1967-upgrade-params nonce "ics20Transfer")

[group('upgrade-params')]
schedule-v3-ics20transfer-upgrade-params nonce="": (_schedule-v3-erc1967-upgrade-params nonce "ics20Transfer")

[group('upgrade-params')]
execute-ics26router-upgrade-params nonce="": (_execute-erc1967-upgrade-params nonce "ics26Router")

[group('upgrade-params')]
schedule-ics26router-upgrade-params nonce="": (_schedule-erc1967-upgrade-params nonce "ics26Router")

# Uses the ICS20Transfer upgrade operation as the timelock predecessor to enforce ICS20-before-ICS26 ordering.
[group('upgrade-params')]
execute-v3-ics26router-upgrade-params nonce="":
    #!/bin/bash
    set -euo pipefail
    predecessor=$({{just}} _v3-ics20-upgrade-operation-id)
    {{just}} _execute-v3-erc1967-upgrade-params "{{nonce}}" "ics26Router" "$predecessor"

# Uses the ICS20Transfer upgrade operation as the timelock predecessor to enforce ICS20-before-ICS26 ordering.
[group('upgrade-params')]
schedule-v3-ics26router-upgrade-params nonce="":
    #!/bin/bash
    set -euo pipefail
    predecessor=$({{just}} _v3-ics20-upgrade-operation-id)
    {{just}} _schedule-v3-erc1967-upgrade-params "{{nonce}}" "ics26Router" "$predecessor"

[group('upgrade-params')]
execute-ics27gmp-upgrade-params nonce="": (_execute-erc1967-upgrade-params nonce "ics27Gmp")

[group('upgrade-params')]
schedule-ics27gmp-upgrade-params nonce="": (_schedule-erc1967-upgrade-params nonce "ics27Gmp")

[group('upgrade-params')]
execute-ibcerc20-upgrade-params nonce="": (_execute-beacon-upgrade-params nonce UPGRADE_IBC_ERC20_SIG ".ics20Transfer.ibcERC20Implementation" ".ics20Transfer.proxy")

[group('upgrade-params')]
schedule-ibcerc20-upgrade-params nonce="": (_schedule-beacon-upgrade-params nonce UPGRADE_IBC_ERC20_SIG ".ics20Transfer.ibcERC20Implementation" ".ics20Transfer.proxy")

[group('upgrade-params')]
execute-escrow-upgrade-params nonce="": (_execute-beacon-upgrade-params nonce UPGRADE_ESCROW_SIG ".ics20Transfer.escrowImplementation" ".ics20Transfer.proxy")

[group('upgrade-params')]
schedule-escrow-upgrade-params nonce="": (_schedule-beacon-upgrade-params nonce UPGRADE_ESCROW_SIG ".ics20Transfer.escrowImplementation" ".ics20Transfer.proxy")

[group('upgrade-params')]
execute-ics27account-upgrade-params nonce="": (_execute-beacon-upgrade-params nonce UPGRADE_ACCOUNT_SIG ".ics27Gmp.accountImplementation" ".ics27Gmp.proxy")

[group('upgrade-params')]
schedule-ics27account-upgrade-params nonce="": (_schedule-beacon-upgrade-params nonce UPGRADE_ACCOUNT_SIG ".ics27Gmp.accountImplementation" ".ics27Gmp.proxy")

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
