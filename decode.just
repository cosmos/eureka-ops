schedule_sig := "schedule(address,uint256,bytes,bytes32,bytes32,uint256)"
execute_sig := "execute(address,uint256,bytes,bytes32,bytes32)"
get_min_delay_sig := "getMinDelay()(uint256)"
schedule_4byte_sig := "0x01d5062a"
execute_4byte_sig := "0x134008d3"
upgrade_to_and_call_sig := "upgradeToAndCall(address)"
upgrade_ibc_erc20_sig := "upgradeIBCERC20(address)"
upgrade_escrow_sig := "upgradeEscrow(address)"

separator := "===================================================================================="

_decode-timelock-tx safe_address nonce type:
    #!/bin/bash
    set -euo pipefail
    safeTx=$({{just}} get_safe_tx {{safe_address}} {{nonce}})
    safeTxHash=$(echo $safeTx | jq -re .safeTxHash)
    safeTxTo=$(echo $safeTx | jq -re .to)
    safeTxData=$(echo $safeTx | jq -re .data)

    tempTxFile="/tmp/$safeTxHash.json"
    echo "{}" > $tempTxFile

    deployment=$(cat deployments/{{environment}}/{{chain}}.json)
    timelockAdmin=$(echo $deployment | jq -re ".ics26Router.timeLockAdmin")

    if [ "$safeTxTo" != "$timelockAdmin" ]; then
        echo "DO NOT SIGN, TX TARGET IS NOT TIMELOCKCONTROLLER"; exit 1;
    fi;

    sig="{{ if type == "schedule" { schedule_sig } else if type == "execute" { execute_sig } else { "" } }}"
    fourbyte_sig="{{ if type == "schedule" { schedule_4byte_sig } else if type == "execute" { execute_4byte_sig } else { "" } }}"

    if [ -z $sig ]; then
        echo "improper timelock action, need schedule or execute"; exit 1;
    fi

    timelockArgs=$({{cast_command}} decode-calldata "$sig" $safeTxData --json)
    timelockTarget=$(echo "$timelockArgs" | jq -re ".[0]")
    timelockData=$(echo "$timelockArgs" | jq -re ".[2]")

    if [[ "$safeTxData" != $fourbyte_sig* ]]; then
      echo "Function signature does not match, do not sign or specify correct schedule/execute type"; exit 1;
    fi

    echo $(jq ".timelockData |= \"$timelockData\"" $tempTxFile) > $tempTxFile
    echo $(jq ".timelockTarget |= \"$timelockTarget\"" $tempTxFile) > $tempTxFile

    if [ "{{type}}" == "schedule" ]; then
        minDelay=$(echo "$timelockArgs" | jq -re ".[5]")
        echo $(jq ".minDelay |= $minDelay" $tempTxFile) > $tempTxFile
    fi

    echo $tempTxFile

[group('verify-safe')]
decode-ics20transfer-upgrade safe_address nonce type: env-info (get_safe_hashes safe_address nonce)
  #!/bin/bash
  set -euo pipefail
  tx_file=$({{just}} _decode-timelock-tx {{safe_address}} {{nonce}} {{type}}) || {
    echo $tx_file; exit 1;
  }
  tx=$(cat $tx_file)

  deployment=$(cat deployments/{{environment}}/{{chain}}.json)
  txData=$(echo $tx | jq -re ".timelockData")

  timelockTarget=$(echo $tx | jq -re ".timelockTarget")
  newImplementation=$(cast decode-calldata "{{upgrade_to_and_call_sig}}" $txData)

  expectedTimelockTarget=$(echo $deployment | jq -re ".ics20Transfer.proxy")
  expectedNewImplementation=$(echo $deployment | jq -re ".ics20Transfer.implementation")

  if [ "$timelockTarget" != "$expectedTimelockTarget" ]; then
    echo "Upgrade is called to an unexpected proxy ($timelockTarget vs expected proxy $expectedTimelockTarget). Do not sign."; exit 1;
  fi;

  if [ "$newImplementation" != "$expectedNewImplementation" ]; then
    echo "Upgrade is to an unexpected implementation ($newImplementation vs expected $expectedNewImplementation). Do not sign."; exit 1;
  fi;

  echo "ICS20Transfer upgrade details:"
  echo "New implementation: $expectedNewImplementation"
  echo "Targeting ICS20Transfer proxy: $expectedTimelockTarget"

[group('verify-safe-tx')]
decode-ics26router-upgrade safe_address nonce type: env-info (get_safe_hashes safe_address nonce)
  #!/bin/bash
  set -euo pipefail
  echo "{{separator}}"
  tx_file=$({{just}} _decode-timelock-tx {{safe_address}} {{nonce}} {{type}}) || {
    echo $tx_file; exit 1;
  }

  tx=$(cat $tx_file)

  deployment=$(cat deployments/{{environment}}/{{chain}}.json)
  txData=$(echo $tx | jq -re ".timelockData")

  timelockTarget=$(echo $tx | jq -re ".timelockTarget")
  newImplementation=$(cast decode-calldata "{{upgrade_to_and_call_sig}}" $txData)

  expectedTimelockTarget=$(echo $deployment | jq -re ".ics26Router.proxy")
  expectedNewImplementation=$(echo $deployment | jq -re ".ics26Router.implementation")

  if [ "$timelockTarget" != "$expectedTimelockTarget" ]; then
    echo "Upgrade is called to an unexpected proxy ($timelockTarget vs expected proxy $expectedTimelockTarget). Do not sign."; exit 1;
  fi;

  if [ "$newImplementation" != "$expectedNewImplementation" ]; then
    echo "Upgrade is to an unexpected implementation ($newImplementation vs expected $expectedNewImplementation). Do not sign."; exit 1;
  fi;

  echo "ICS26Router upgrade details:"
  echo "New implementation: $expectedNewImplementation"
  echo "Targeting ICS26Router proxy: $expectedTimelockTarget"
