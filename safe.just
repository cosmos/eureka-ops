safe_address := "0x85CF98533e3275450a0d61D9BC236225947C5882"
eip712_separator_typehash := "0x47e79534a245952e8b16893a336b85a3d9ea9fa8c573f3d803afb92a79469218"
safe_tx_typehash := "0xbb8310d486368db6bd6f849402fdd73ad53d316b5a4b2644ad6efe0f941286d8"
zero_address := "0x0000000000000000000000000000000000000000"
zero_bytes32 := "0x0000000000000000000000000000000000000000000000000000000000000000"

[group('safe_helpers')]
get_safe_owners:
    #!/bin/bash
    set -euo pipefail
    owners=$({{cast_binary}} call {{safe_address}} "getOwners()(address[])")
    owners=$(echo $owners | sed -E 's/(0x[0-9a-fA-F]+)/"\1"/g' | jq -r)
    echo $owners

[group('safe_helpers')]
get_safe_nonce:
    #!/bin/bash
    set -euo pipefail
    nonce=$({{cast_binary}} call {{safe_address}} "nonce()(uint256)")
    echo $nonce

_get_safe_domain_hash nonce:
  #!/bin/bash
  set -euo pipefail
  domain_hash=$(chisel eval --json "keccak256(abi.encode({{eip712_separator_typehash}}, {{chain}}, {{safe_address}}))" | awk '/Data:/ {gsub(/\x1b\[[0-9;]*m/, "", $3); print $3}')
  echo $domain_hash
  
_get_safe_message_hash nonce data to:
  #!/bin/bash
  set -euo pipefail
  data_hashed=$(cast keccak "{{data}}")

  value="0"
  operation="0"
  safe_tx_gas="0"
  base_gas="0"
  gas_price="0"
  gas_token="{{zero_address}}"
  refund_receiver="{{zero_address}}"

  message=$({{cast_binary}} abi-encode "SafeTxStruct(bytes32,address,uint256,bytes32,uint8,uint256,uint256,uint256,address,address,uint256)" \
          "{{safe_tx_typehash}}" \
          "{{to}}" \
          "$value" \
          "$data_hashed" \
          "$operation" \
          "$safe_tx_gas" \
          "$base_gas" \
          "$gas_price" \
          "$gas_token" \
          "$refund_receiver" \
          "{{nonce}}")

  echo $({{cast_binary}} keccak "$message")

_get_safe_tx_hash nonce domain_hash message_hash:
  #!/bin/bash
  set -euo pipefail
  safe_tx_hash=$({{chisel_binary}} eval "keccak256(abi.encodePacked(bytes1(0x19), bytes1(0x01), bytes32({{domain_hash}}), bytes32({{message_hash}})))" |
        awk '/Data:/ {gsub(/\x1b\[[0-9;]*m/, "", $3); print $3}')
  echo $safe_tx_hash

[group('verify-safe')]
get_safe_hashes nonce data to:
  #!/bin/bash
  set -euo pipefail
  domain_hash=$({{just}} _get_safe_domain_hash {{nonce}})
  message_hash=$({{just}} _get_safe_message_hash {{nonce}} {{data}} {{to}})
  tx_hash=$({{just}} _get_safe_tx_hash {{nonce}} $domain_hash $message_hash)
  echo "Message hash: $message_hash"
  echo "Domain hash: $domain_hash"
  echo "safeTxHash: $tx_hash"
