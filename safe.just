safe_address := env_var_or_default("SAFE_ADDRESS", "0x7B96CD54aA750EF83ca90eA487e0bA321707559a")
eip712_separator_typehash := "0x47e79534a245952e8b16893a336b85a3d9ea9fa8c573f3d803afb92a79469218"
safe_tx_typehash := "0xbb8310d486368db6bd6f849402fdd73ad53d316b5a4b2644ad6efe0f941286d8"
zero_address := "0x0000000000000000000000000000000000000000"
zero_bytes32 := "0x0000000000000000000000000000000000000000000000000000000000000000"
# Canonical Safe v1.4.1 MultiSendCallOnly, identical on mainnet (1) and Sepolia (11155111).
multisend_call_only_address := env_var_or_default("MULTISEND_CALL_ONLY", "0x9641d764fc13c8B624c04430C7356C1C7C8102e2")

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
  
# Computes the Safe EIP-712 message hash. `operation` is the Safe operation (0 = Call, 1 = DelegateCall):
# plain Safe calls pass 0; the MultiSend bundle passes 1 (DelegateCall) so each sub-call's msg.sender
# stays the Safe.
_get_safe_message_hash nonce data to operation:
  #!/bin/bash
  set -euo pipefail
  data_hashed=$(cast keccak "{{data}}")

  value="0"
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
          "{{operation}}" \
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
  message_hash=$({{just}} _get_safe_message_hash {{nonce}} {{data}} {{to}} 0)
  tx_hash=$({{just}} _get_safe_tx_hash {{nonce}} $domain_hash $message_hash)
  echo "Domain hash: $domain_hash"
  echo "Message hash: $message_hash"
  echo "safeTxHash: $tx_hash"

# Builds a single Safe MultiSend bundling the whole v3 upgrade as one atomic Safe transaction.
#
# It collects the per-operation TimelockController.execute calldata from the existing execute-v3-* recipes
# (in the order the timelock must run them: ICS20Transfer, ICS26Router, then the Escrow / IBCERC20 beacons,
# then one per SP1 client_id), packs them as MultiSend sub-transactions all targeting the timelock, and wraps
# them in MultiSendCallOnly.multiSend(bytes). The Safe must execute this via DelegateCall (operation=1) so the
# msg.sender of every timelock.execute() stays the Safe (which holds EXECUTOR_ROLE). Because the timelock marks
# an op Done at the end of its own execute(), the in-batch predecessor (ICS20 before ICS26) is satisfied as long
# as ICS20's sub-tx precedes ICS26's — which it does here.
#
# With an empty nonce it prints only the machine-greppable `multisend *` lines (safeTxHash uses the Safe's
# current on-chain nonce). With a non-empty nonce it also prints the signer hashes for that Safe tx.
[group('upgrade-params')]
execute-v3-upgrade-multisend nonce *client_ids:
    #!/bin/bash
    set -euo pipefail
    deployment=$(cat deployments/{{environment}}/{{chain}}.json)
    timelock=$(echo "$deployment" | jq -re "(.accessManagerRoles.admin // .ics26Router.timelockAdmin)")

    # The timelock is the `to` of every MultiSend sub-call; pack it as 20 raw bytes (40 lowercase hex, no 0x).
    timelock_hex=$(echo "${timelock#0x}" | tr 'A-Z' 'a-z')
    if [ "${#timelock_hex}" -ne 40 ]; then
      echo "timelock address '$timelock' is not a 20-byte address" >&2
      exit 1
    fi
    value_hex=$(printf '%064x' 0)

    # Run an execute-v3-* recipe with an empty nonce and pull out the "timelock calldata: 0x..." line it prints.
    extract_calldata() {
      local out
      if ! out=$({{just}} "$@"); then
        echo "recipe failed: just $*" >&2
        printf '%s\n' "${out:-}" >&2
        exit 1
      fi
      local data
      data=$(printf '%s\n' "$out" | sed -n 's/^timelock calldata: //p')
      if [ -z "$data" ]; then
        echo "could not find 'timelock calldata:' in output of: just $*" >&2
        printf '%s\n' "$out" >&2
        exit 1
      fi
      printf '%s\n' "$data"
    }

    # Append one MultiSend sub-tx: operation(00) + to(20) + value(32) + dataLength(32) + data.
    packed=""
    append_subtx() {
      local data_hex="${1#0x}"
      local len=$(( ${#data_hex} / 2 ))
      local len_hex
      len_hex=$(printf '%064x' "$len")
      packed="${packed}00${timelock_hex}${value_hex}${len_hex}${data_hex}"
    }

    append_subtx "$(extract_calldata execute-v3-ics20transfer-upgrade-params "")"
    append_subtx "$(extract_calldata execute-v3-ics26router-upgrade-params "")"
    append_subtx "$(extract_calldata execute-escrow-upgrade-params "")"
    append_subtx "$(extract_calldata execute-ibcerc20-upgrade-params "")"
    for cid in {{client_ids}}; do
      append_subtx "$(extract_calldata execute-v3-light-client-migration-params "$cid" "")"
    done

    multisend_data=$({{cast_binary}} calldata "multiSend(bytes)" "0x${packed}")

    # safeTxHash needs a concrete nonce: use the given one, else the Safe's current on-chain nonce.
    effective_nonce="{{nonce}}"
    if [ -z "$effective_nonce" ]; then
      effective_nonce=$({{cast_binary}} call {{safe_address}} "nonce()(uint256)" | awk '{print $1}')
    fi

    domain_hash=$({{just}} _get_safe_domain_hash "$effective_nonce")
    message_hash=$({{just}} _get_safe_message_hash "$effective_nonce" "$multisend_data" "{{multisend_call_only_address}}" 1)
    safe_tx_hash=$({{just}} _get_safe_tx_hash "$effective_nonce" "$domain_hash" "$message_hash")

    echo "multisend to: {{multisend_call_only_address}}"
    echo "multisend value: 0"
    echo "multisend operation: 1"
    echo "multisend data: $multisend_data"
    echo "multisend safeTxHash: $safe_tx_hash"

    if [ -n "{{nonce}}" ]; then
      echo "Domain hash: $domain_hash"
      echo "Message hash: $message_hash"
      echo "safeTxHash: $safe_tx_hash"
    fi
