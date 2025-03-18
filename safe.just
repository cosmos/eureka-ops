eip712_separator_typehash := "0x47e79534a245952e8b16893a336b85a3d9ea9fa8c573f3d803afb92a79469218"
safe_tx_typehash := "0xbb8310d486368db6bd6f849402fdd73ad53d316b5a4b2644ad6efe0f941286d8"
zero_address := "0x0000000000000000000000000000000000000000"

[group('safe')]
get_safe_owners safe_address:
    #!/bin/bash
    set -euo pipefail
    owners=$({{cast_command}} call {{safe_address}} "getOwners()(address[])")
    owners=$(echo $owners | sed -E 's/(0x[0-9a-fA-F]+)/"\1"/g' | jq -r)
    echo $owners

[group('safe')]
get_safe_nonce safe_address:
    #!/bin/bash
    set -euo pipefail
    nonce=$({{cast_command}} call {{safe_address}} "nonce()(uint256)")
    echo $nonce

[group('safe')]
get_safe_tx safe_address nonce:
    #!/bin/bash
    set -euo pipefail
    tx=$(curl -X 'GET' \
        "https://safe-transaction-sepolia.safe.global/api/v2/safes/{{safe_address}}/multisig-transactions/?nonce={{nonce}}" \
        -H 'accept: application/json' --silent | jq -re ".results[0]")
    
    echo $tx

[group('safe')]
verify_safe_tx safe_address nonce:
    #!/bin/bash
    set -euo pipefail
    tx=$({{just}} get_safe_tx {{safe_address}} {{nonce}})
    owners=$({{just}} get_safe_owners {{safe_address}})

    safe_is_correct=$(echo $tx | jq -re '.safe == "{{safe_address}}"')
    if [ $safe_is_correct != "true" ]; then
        echo "DO NOT SIGN, SAFE ADDRESS IS NOT CORRECT"; exit 1;
    fi

    echo "Transaction proposed in Safe: {{safe_address}}"

    proposer=$(echo $tx | jq -re ".proposer")
    echo "Proposer: $proposer"

    proposer_is_owner=$(echo $owners | jq -re "contains([\"$proposer\"])")
    if [ $proposer_is_owner != "true" ]; then
        echo "DO NOT SIGN, TX PROPOSER IS NOT AN OWNER"; exit 1;
    fi

[group('safe')]
get_last_safe_tx safe_address:
    {{just}} get_safe_tx {{safe_address}} $({{just}} get_safe_nonce {{safe_address}})

_get_safe_domain_hash safe_address nonce:
  #!/bin/bash
  set -euo pipefail
  domain_hash=$(chisel eval --json "keccak256(abi.encode({{eip712_separator_typehash}}, {{chain}}, {{safe_address}}))" | awk '/Data:/ {gsub(/\x1b\[[0-9;]*m/, "", $3); print $3}')
  echo $domain_hash
  
_get_safe_message_hash safe_address nonce:
  #!/bin/bash
  set -euo pipefail
  tx=$({{just}} get_safe_tx {{safe_address}} {{nonce}})
  data=$(echo $tx | jq -re ".data // \"0x\"")
  data_hashed=$(cast keccak "$data")

  to=$(echo $tx | jq -re ".to")
  value=$(echo $tx | jq -re ".value")
  operation=$(echo $tx | jq -re ".operation // \"0\"")
  safe_tx_gas=$(echo $tx | jq -re ".safeTxGas // \"0\"")
  base_gas=$(echo $tx | jq -re ".baseGas // \"0\"")
  gas_price=$(echo $tx | jq -re ".gasPrice // \"0\"")
  gas_token=$(echo $tx | jq -re ".gasToken // \"{{zero_address}}\"")
  refund_receiver=$(echo $tx | jq -re ".refundReceiver // \"{{zero_address}}\"")

  message=$({{cast_command}} abi-encode "SafeTxStruct(bytes32,address,uint256,bytes32,uint8,uint256,uint256,uint256,address,address,uint256)" \
          "{{safe_tx_typehash}}" \
          "$to" \
          "$value" \
          "$data_hashed" \
          "$operation" \
          "$safe_tx_gas" \
          "$base_gas" \
          "$gas_price" \
          "$gas_token" \
          "$refund_receiver" \
          "{{nonce}}")

  echo $(cast keccak "$message")

_get_safe_tx_hash safe_address nonce domain_hash message_hash:
  #!/bin/bash
  set -euo pipefail
  safe_tx_hash=$(chisel eval "keccak256(abi.encodePacked(bytes1(0x19), bytes1(0x01), bytes32({{domain_hash}}), bytes32({{message_hash}})))" |
        awk '/Data:/ {gsub(/\x1b\[[0-9;]*m/, "", $3); print $3}')
  echo $safe_tx_hash

[group('verify-safe')]
get_safe_hashes safe_address nonce:
  #!/bin/bash
  set -euo pipefail
  echo "{{separator}}"
  domain_hash=$({{just}} _get_safe_domain_hash {{safe_address}} {{nonce}})
  message_hash=$({{just}} _get_safe_message_hash {{safe_address}} {{nonce}})
  tx_hash=$({{just}} _get_safe_tx_hash {{safe_address}} {{nonce}} $domain_hash $message_hash)
  echo "safeTxHash: $tx_hash"
  echo "Message hash: $message_hash"
  echo "Domain hash: $domain_hash"