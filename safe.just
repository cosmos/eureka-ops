# Proposer/executor Safe for the configured environment+chain, read from deployments/<env>/<chain>.json (.safe).
# Stored per-deployment (not an env var) so the signer-facing Safe hashes can never be computed against the wrong
# Safe. Empty when environment/chain are unset (keeps `just --list` working); fails loudly when the file or the
# .safe key is missing rather than silently falling back to a default Safe.
safe_address := shell('if [ -z "$1" ] || [ -z "$2" ]; then echo ""; exit 0; fi; f="deployments/$1/$2.json"; test -f "$f" || { echo "safe lookup failed: $f not found" >&2; exit 1; }; jq -re ".safe" "$f" || { echo "safe address (.safe) not set in $f" >&2; exit 1; }', environment, chain)
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

[group('safe_helpers')]
[doc('PROPOSE (not execute) a Safe tx to the Safe Transaction Service so it appears in the Safe UI to sign/execute. Signs the safeTxHash with PRIVATE_KEY (must be a Safe owner); operation 0=Call, 1=DelegateCall. Nonce is auto-queried when omitted. Nothing is broadcast. See scripts/safe-propose.sh (supports --dry-run).')]
safe-propose to data nonce="" operation="0":
    #!/bin/bash
    set -euo pipefail
    nonce_arg=""
    [ -n "{{nonce}}" ] && nonce_arg="--nonce {{nonce}}"
    bash scripts/safe-propose.sh --to {{to}} --data {{data}} $nonce_arg --operation {{operation}}

[group('safe_helpers')]
[doc('Propose a timelock schedule(...) straight from a schedule-v3-* recipe: runs the recipe to get its `timelock calldata`, then proposes it to the Safe. The nonce is auto-queued (consecutive across calls; override with SAFE_NONCE). e.g. `just propose-schedule schedule-v3-ics20transfer-upgrade-params` or `just propose-schedule schedule-v3-light-client-migration-params hub-testnet-0`.')]
propose-schedule recipe *recipe_args:
    #!/bin/bash
    set -euo pipefail
    timelock=$(jq -re "(.accessManagerRoles.admin // .ics26Router.timelockAdmin)" deployments/{{environment}}/{{chain}}.json)
    if ! out=$({{just}} {{recipe}} {{recipe_args}} ""); then
      echo "recipe failed: just {{recipe}} {{recipe_args}}" >&2
      printf '%s\n' "$out" >&2
      exit 1
    fi
    data=$(printf '%s\n' "$out" | sed -n 's/^timelock calldata: //p')
    if [ -z "$data" ]; then
      echo "no 'timelock calldata:' line from: just {{recipe}} {{recipe_args}}" >&2
      printf '%s\n' "$out" >&2
      exit 1
    fi
    nonce_arg=""
    [ -n "${SAFE_NONCE:-}" ] && nonce_arg="--nonce ${SAFE_NONCE}"
    bash scripts/safe-propose.sh --to "$timelock" --data "$data" $nonce_arg --operation 0 --origin "{{recipe}} {{recipe_args}}"

# Packs an arbitrary list of already-scheduled TimelockController operations into ONE atomic Safe MultiSend
# (MultiSendCallOnly.multiSend via DelegateCall). Every sub-call is a `timelock.execute(...)` targeting the
# TimelockController, so the Safe (which holds EXECUTOR_ROLE) is the msg.sender of each execute. Atomicity gives
# all-or-nothing; an in-batch timelock predecessor (e.g. ICS20 before ICS26) is satisfied as long as the
# dependency's sub-tx precedes the dependent's -- so ORDER MATTERS for predecessor-linked ops.
#
# `ops` is a ';'-separated list; each item is either:
#   - an execute-* recipe invocation to run -- it must print a `timelock calldata: 0x...` line -- e.g.
#     `execute-v3-ics20transfer-upgrade-params` or `execute-v3-light-client-migration-params hub-testnet-0`; or
#   - a raw `0x...` execute(...) calldata, for ops captured out-of-band (e.g. the interactive
#     `timelock-grant-rate-limiter-role execute` / `timelock-grant-role execute` recipes, whose `timelock
#     calldata:` you generate once and paste in -- they prompt, so they can't be run headless inside the packer).
# Each packed sub-tx is validated to be a timelock `execute(...)` call (selector 0x134008d3).
#
# Empty nonce -> safeTxHash uses the Safe's current on-chain nonce and only the machine-greppable `multisend *`
# lines print; a non-empty nonce also prints the signer hashes. Propose with: just safe-propose <to> <data> <nonce> 1
[group('upgrade-params')]
execute-timelock-multisend nonce ops:
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

    # Schedule-state guard. Confirm a sub-op is a PENDING TimelockController operation on-chain -- scheduled and not
    # yet executed -- BEFORE packing it. This catches a mistyped/omitted client id, a forgotten schedule, or a
    # folded grant whose execute blob does not byte-match its scheduled op: all of those otherwise pack cleanly and
    # only blow up at execute time (a revert, or a silently shorter-but-valid MultiSend) after the full timelock
    # delay. isOperationPending is true for scheduled-but-not-done regardless of whether the delay has elapsed, so
    # this also holds while previewing the safeTxHash during the delay window. Needs an RPC (FOUNDRY_ETH_RPC_URL);
    # if none is configured it is skipped with a loud warning so an offline calldata preview still works.
    assert_pending() {
      local data_hex="${1#0x}"
      if [ -z "${FOUNDRY_ETH_RPC_URL:-${ETH_RPC:-}}" ]; then
        echo "WARNING: no RPC set (FOUNDRY_ETH_RPC_URL) -- SKIPPING the on-chain schedule-state check for a sub-op." >&2
        return 0
      fi
      local decoded target value payload predecessor salt opid pending
      if ! decoded=$({{cast_binary}} decode-calldata "execute(address,uint256,bytes,bytes32,bytes32)" "0x${data_hex}" 2>/dev/null); then
        echo "could not decode a packed execute(...) sub-call to verify it is scheduled; refusing to pack" >&2
        exit 1
      fi
      target=$(printf '%s\n' "$decoded" | sed -n '1p')
      value=$(printf '%s\n' "$decoded" | sed -n '2p')
      payload=$(printf '%s\n' "$decoded" | sed -n '3p')
      predecessor=$(printf '%s\n' "$decoded" | sed -n '4p')
      salt=$(printf '%s\n' "$decoded" | sed -n '5p')
      opid=$({{cast_binary}} call "$timelock" "hashOperation(address,uint256,bytes,bytes32,bytes32)(bytes32)" "$target" "$value" "$payload" "$predecessor" "$salt")
      pending=$({{cast_binary}} call "$timelock" "isOperationPending(bytes32)(bool)" "$opid" | awk '{print $1}')
      if [ "$pending" != "true" ]; then
        echo "refusing to pack an op that is NOT a pending timelock operation (opId $opid, isOperationPending=$pending):" >&2
        echo "  target=$target predecessor=$predecessor salt=$salt" >&2
        echo "  It was never scheduled (mistyped client id / forgotten schedule), a folded grant's execute blob" >&2
        echo "  does not byte-match its scheduled op, or it already executed. Fix before building the bundle." >&2
        exit 1
      fi
    }

    # Pack one validated timelock.execute(...) calldata as a MultiSend sub-tx: operation(00) + to(20) + value(32)
    # + dataLength(32) + data. Rejects anything that is not a timelock execute() call (selector 0x134008d3).
    packed=""
    pack_data() {
      local data_hex="${1#0x}"
      if [ -z "$data_hex" ]; then echo "refusing to pack an empty sub-transaction" >&2; exit 1; fi
      if [ "$(printf '%s' "${data_hex:0:8}" | tr 'A-Z' 'a-z')" != "134008d3" ]; then
        echo "sub-tx is not a timelock execute(...) call (selector 0x${data_hex:0:8}); refusing to pack" >&2
        exit 1
      fi
      assert_pending "$data_hex"
      local len=$(( ${#data_hex} / 2 ))
      packed="${packed}00${timelock_hex}${value_hex}$(printf '%064x' "$len")${data_hex}"
    }

    # Run an execute-* recipe and pull out its "timelock calldata: 0x..." line, then pack it. The `if ! out=$(...)`
    # form makes a recipe failure trip `set -e` and abort the whole bundle -- an arg-list `$(...)` would discard
    # the failure and pack a zero-length no-op, silently dropping that op from a MultiSend the operator then signs
    # and submits as "complete".
    append_recipe() {
      local out
      if ! out=$({{just}} "$@"); then echo "recipe failed: just $*" >&2; printf '%s\n' "${out:-}" >&2; exit 1; fi
      local d
      d=$(printf '%s\n' "$out" | sed -n 's/^timelock calldata: //p')
      if [ -z "$d" ]; then echo "could not find 'timelock calldata:' in output of: just $*" >&2; printf '%s\n' "$out" >&2; exit 1; fi
      pack_data "$d"
    }

    IFS=';' read -ra _ops <<< "{{ops}}"
    # "${_ops[@]:-}" (not "${_ops[@]}") so an empty list doesn't trip set -u on bash 3.2; it falls through to the
    # "no ops to pack" guard below instead of an unbound-variable error. `set -f` disables pathname (glob)
    # expansion so the intentional word-splitting of `append_recipe $op` can't be mangled by a glob char in an
    # op token matching a file in the working dir.
    set -f
    for raw in "${_ops[@]:-}"; do
      op=$(printf '%s' "$raw" | awk '{$1=$1};1')   # trim leading/trailing whitespace
      [ -z "$op" ] && continue
      if [ "${op:0:2}" = "0x" ]; then
        pack_data "$op"
      else
        # shellcheck disable=SC2086
        append_recipe $op
      fi
    done
    set +f
    [ -n "$packed" ] || { echo "no ops to pack (empty ops list)" >&2; exit 1; }

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

# The v3 upgrade as the default op set for execute-timelock-multisend: ICS20Transfer, ICS26Router, the Escrow /
# IBCERC20 beacons, then one migration per SP1 client_id -- in the order the timelock predecessor requires (ICS20
# before ICS26). Set EXTRA_TIMELOCK_OPS (';'-separated, same format as execute-timelock-multisend's `ops`) to fold
# additional already-scheduled ops -- e.g. rate-limiter or role grants -- into the SAME atomic execute instead of
# a second timelock round.
[group('upgrade-params')]
execute-v3-upgrade-multisend nonce *client_ids:
    #!/bin/bash
    set -euo pipefail
    ops="execute-v3-ics20transfer-upgrade-params;execute-v3-ics26router-upgrade-params;execute-escrow-upgrade-params;execute-ibcerc20-upgrade-params"
    for cid in {{client_ids}}; do
      ops="${ops};execute-v3-light-client-migration-params ${cid}"
    done
    [ -n "${EXTRA_TIMELOCK_OPS:-}" ] && ops="${ops};${EXTRA_TIMELOCK_OPS}"
    {{just}} execute-timelock-multisend "{{nonce}}" "$ops"
