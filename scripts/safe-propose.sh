#!/usr/bin/env bash
set -euo pipefail

# Propose a Safe transaction to the Safe Transaction Service so it appears in the Safe UI as a pending tx to
# review / sign / execute. NOTHING is broadcast on-chain: this signs the Safe EIP-712 `safeTxHash` with
# PRIVATE_KEY (which must be a Safe owner) and POSTs the proposal to the transaction service.
#
# The `safeTxHash` is computed exactly as `just get_safe_hashes` / the schedule recipes print it, so the value
# you confirm in those recipes is the value signed here.
#
# Usage: scripts/safe-propose.sh --to <addr> --data <0xhex> [--nonce <n>] [--operation 0|1] [--origin <label>]
#                                [--safe <addr>] [--ledger] [--mnemonic-index <n>] [--hd-path <path>] [--dry-run]
# --safe overrides the proposing Safe (default: .safe in deployments/<env>/<chain>.json, the governance Safe);
# pass it to propose to a different Safe such as the 2-of-5 customizer Safe.
# If --nonce is omitted it is auto-queried as max(on-chain nonce, highest already-queued nonce + 1) from the
# tx service, so proposing several in a row queues them at consecutive nonces instead of colliding.
#
# Signer: a Ledger (--ledger / LEDGER=1) or a raw PRIVATE_KEY; both post a v in {27,28} "EIP-712" Safe
# signature over the safeTxHash. PRIVATE_KEY signs the hash directly (--no-hash). A Ledger cannot sign a raw
# hash ("sign_hash not supported"), so it is handed the Safe EIP-712 typed data and derives the same
# safeTxHash on-device (enable blind signing / EIP-712 on the Ethereum app); the script then re-checks the
# device signature recovers to the printed safeTxHash before posting. --ledger takes precedence over PRIVATE_KEY.
# Env (used when the flag is omitted):
#   EUREKA_ENVIRONMENT, EUREKA_CHAIN   -> deployments/<env>/<chain>.json (.safe is the proposer Safe)
#   PRIVATE_KEY                        -> the proposing owner's key (signs the safeTxHash)
#   LEDGER=1                           -> sign with a Ledger instead of PRIVATE_KEY (same as --ledger)
#   MNEMONIC_INDEX                     -> Ledger account index, m/44'/60'/0'/0/<index> (default 0; --mnemonic-index)
#   MNEMONIC_DERIVATION_PATH           -> full Ledger derivation path override (--hd-path; for Ledger Live paths)
#   ETH_RPC                            -> used to verify the signer is an owner and show the on-chain nonce
#   SAFE_TX_SERVICE                    -> override the transaction-service base URL
#   SAFE_API_KEY                       -> optional bearer token (newer Safe services require one)
# Requires: cast (foundry), jq, curl.

DOMAIN_TYPEHASH=0x47e79534a245952e8b16893a336b85a3d9ea9fa8c573f3d803afb92a79469218
SAFE_TX_TYPEHASH=0xbb8310d486368db6bd6f849402fdd73ad53d316b5a4b2644ad6efe0f941286d8
ZERO=0x0000000000000000000000000000000000000000

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
env="${EUREKA_ENVIRONMENT:-}"
chain="${EUREKA_CHAIN:-}"
rpc="${ETH_RPC:-}"
to=""
data=""
safe_override=""
nonce=""
operation=0
origin="eureka-ops safe-propose"
dry_run=0
use_ledger=0
[ -n "${LEDGER:-}" ] && [ "${LEDGER}" != 0 ] && use_ledger=1
mnemonic_index="${MNEMONIC_INDEX:-0}"
hd_path="${MNEMONIC_DERIVATION_PATH:-}"

while [ "$#" -gt 0 ]; do
  case "$1" in
    --to) to="${2:?--to needs an address}"; shift 2 ;;
    --data) data="${2:?--data needs 0x calldata}"; shift 2 ;;
    --nonce) nonce="${2:?--nonce needs a value}"; shift 2 ;;
    --operation) operation="${2:?--operation needs 0|1}"; shift 2 ;;
    --safe) safe_override="${2:?--safe needs an address}"; shift 2 ;;
    --origin) origin="${2:?--origin needs a label}"; shift 2 ;;
    --env) env="${2:?}"; shift 2 ;;
    --chain) chain="${2:?}"; shift 2 ;;
    --ledger) use_ledger=1; shift ;;
    --mnemonic-index) mnemonic_index="${2:?--mnemonic-index needs a value}"; shift 2 ;;
    --hd-path) hd_path="${2:?--hd-path needs a derivation path}"; shift 2 ;;
    --dry-run) dry_run=1; shift ;;
    -h | --help) sed -n '4,29p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 1 ;;
  esac
done

command -v cast >/dev/null || { echo "cast not found (foundry)" >&2; exit 1; }
command -v jq >/dev/null || { echo "jq not found" >&2; exit 1; }
command -v curl >/dev/null || { echo "curl not found" >&2; exit 1; }
[ -n "$env" ] && [ -n "$chain" ] || { echo "set EUREKA_ENVIRONMENT/EUREKA_CHAIN or pass --env/--chain" >&2; exit 1; }
[ -n "$to" ] && [ -n "$data" ] || { echo "need --to and --data (nonce is auto-queried when --nonce is omitted)" >&2; exit 1; }
case "$operation" in 0 | 1) ;; *) echo "--operation must be 0 (Call) or 1 (DelegateCall)" >&2; exit 1 ;; esac

# Target Safe: --safe overrides the deployment's .safe (e.g. proposing to the 2-of-5 customizer Safe instead
# of the governance Safe). Everything downstream — nonce(), domain separator, owner/delegate check, POST URL —
# flows from this one value, so the override is all that's needed to retarget a different Safe.
if [ -n "$safe_override" ]; then
  safe="$safe_override"
else
  dep="$root/deployments/$env/$chain.json"
  test -f "$dep" || { echo "deployment not found: $dep" >&2; exit 1; }
  safe="$(jq -re '.safe' "$dep")" || { echo "no .safe in $dep" >&2; exit 1; }
fi
[ "$safe" != "$ZERO" ] || { echo "Safe address is the zero address" >&2; exit 1; }
safe_cs="$(cast to-check-sum-address "$safe")"

# Transaction-service base URL + Safe-UI chain shortname (override the URL with SAFE_TX_SERVICE).
case "$chain" in
  1)        service_default="https://safe-transaction-mainnet.safe.global"; shortname="eth" ;;
  11155111) service_default="https://safe-transaction-sepolia.safe.global"; shortname="sep" ;;
  *)        service_default=""; shortname="$chain" ;;
esac
service="${SAFE_TX_SERVICE:-$service_default}"
[ -n "$service" ] || { echo "no known Safe Transaction Service for chain $chain; set SAFE_TX_SERVICE" >&2; exit 1; }
service="${service%/}"

# curl with the optional Safe API key as a properly-separated header. Building it via
# ${SAFE_API_KEY:+-H "Authorization: ..."} would collapse into one malformed argv element under word
# splitting (a header field name with a leading space), sending an unauthenticated request; pass it as a
# real, separate -H argument instead.
curl_auth() {
  if [ -n "${SAFE_API_KEY:-}" ]; then
    curl "$@" -H "Authorization: Bearer $SAFE_API_KEY"
  else
    curl "$@"
  fi
}

# Auto-query the next queue nonce when not given: max(on-chain nonce, highest already-queued nonce + 1).
# Reading only the on-chain nonce() would collide a batch (every not-yet-executed schedule would get the
# same value); asking the tx service for the highest queued nonce lets consecutive proposals stack into a queue.
if [ -z "$nonce" ]; then
  [ -n "$rpc" ] || { echo "auto-nonce needs ETH_RPC (or pass --nonce)" >&2; exit 1; }
  onchain="$(cast call "$safe" 'nonce()(uint256)' --rpc-url "$rpc" | awk '{print $1}')"
  q="$service/api/v1/safes/$safe_cs/multisig-transactions/?ordering=-nonce&limit=1"
  code="$(curl_auth -sSL -o /tmp/safe_nonce_resp.$$ -w '%{http_code}' "$q" || echo 000)"
  qresp="$(cat /tmp/safe_nonce_resp.$$ 2>/dev/null || true)"; rm -f /tmp/safe_nonce_resp.$$
  [ "$code" = 200 ] || { echo "could not query queued nonce from $service (HTTP $code); pass --nonce explicitly" >&2; printf '%s\n' "$qresp" | head -3 >&2; exit 1; }
  highest="$(printf '%s' "$qresp" | jq -r '.results[0].nonce // empty')"
  if [ -n "$highest" ] && [ "$((highest + 1))" -gt "$onchain" ]; then nonce="$((highest + 1))"; else nonce="$onchain"; fi
  echo "auto-nonce: on-chain=$onchain, highest queued=${highest:-none} -> proposing at nonce $nonce" >&2
fi

# safeTxHash, computed identically to safe.just's get_safe_hashes (value is always 0 for these ops).
domain="$(cast keccak "$(cast abi-encode 'x(bytes32,uint256,address)' "$DOMAIN_TYPEHASH" "$chain" "$safe")")"
data_hashed="$(cast keccak "$data")"
message="$(cast abi-encode 'x(bytes32,address,uint256,bytes32,uint8,uint256,uint256,uint256,address,address,uint256)' \
  "$SAFE_TX_TYPEHASH" "$to" 0 "$data_hashed" "$operation" 0 0 0 "$ZERO" "$ZERO" "$nonce")"
message_hash="$(cast keccak "$message")"
safe_tx_hash="$(cast keccak "$(cast concat-hex 0x1901 "$domain" "$message_hash")")"

# Signer selection: a Ledger (--ledger / LEDGER=1, takes precedence) or a raw PRIVATE_KEY. The wallet-selector
# flags (hw_args) are shared by `cast wallet address` and `cast wallet sign`; the SIGN call differs by signer.
hw_args=()
if [ "$use_ledger" = 1 ]; then
  hw_args=(--ledger --mnemonic-index "$mnemonic_index")
  [ -n "$hd_path" ] && hw_args+=(--mnemonic-derivation-path "$hd_path")
else
  [ -n "${PRIVATE_KEY:-}" ] || { echo "no signer: set PRIVATE_KEY, or pass --ledger (LEDGER=1) for a hardware wallet" >&2; exit 1; }
  hw_args=(--private-key "$PRIVATE_KEY")
fi
sender="$(cast wallet address "${hw_args[@]}")"

if [ "$use_ledger" = 1 ]; then
  # A Ledger cannot sign a raw hash (foundry: "operation `sign_hash` is not supported by the signer"); it signs
  # EIP-712 typed data. So hand the device the Safe `SafeTx` typed data and let it derive the SAME safeTxHash and
  # sign it -- producing the identical v in {27,28} signature the --no-hash private-key path makes. (Verified
  # offline that this typed data hashes to $safe_tx_hash; the post-sign check below re-asserts it on the device
  # output.) The Safe domain is chainId + verifyingContract only (matches DOMAIN_TYPEHASH above).
  eip712_file="$(mktemp -t safetx_eip712.XXXXXX)"
  trap 'rm -f "$eip712_file"' EXIT
  cat > "$eip712_file" <<JSON
{ "types": {
    "EIP712Domain": [ {"name":"chainId","type":"uint256"}, {"name":"verifyingContract","type":"address"} ],
    "SafeTx": [ {"name":"to","type":"address"}, {"name":"value","type":"uint256"}, {"name":"data","type":"bytes"},
      {"name":"operation","type":"uint8"}, {"name":"safeTxGas","type":"uint256"}, {"name":"baseGas","type":"uint256"},
      {"name":"gasPrice","type":"uint256"}, {"name":"gasToken","type":"address"}, {"name":"refundReceiver","type":"address"},
      {"name":"nonce","type":"uint256"} ] },
  "primaryType": "SafeTx",
  "domain": { "chainId": $chain, "verifyingContract": "$safe_cs" },
  "message": { "to": "$to", "value": "0", "data": "$data", "operation": $operation,
    "safeTxGas": "0", "baseGas": "0", "gasPrice": "0",
    "gasToken": "$ZERO", "refundReceiver": "$ZERO", "nonce": "$nonce" } }
JSON
  echo "Signing with Ledger (mnemonic-index $mnemonic_index${hd_path:+, path $hd_path}) via EIP-712; confirm on the device. safeTxHash: $safe_tx_hash" >&2
  signature="$(cast wallet sign "${hw_args[@]}" --data --from-file "$eip712_file")"
  # Safety net: the device-derived signature MUST recover to $safe_tx_hash (the value printed for signers and
  # used by the Safe). If it does not, the typed data and the posted hash disagree -- refuse rather than post a
  # proposal the Safe will reject.
  if ! cast wallet verify --no-hash --address "$sender" "$safe_tx_hash" "$signature" >/dev/null 2>&1; then
    echo "Ledger signature does not recover to safeTxHash $safe_tx_hash; refusing to post." >&2
    exit 1
  fi
else
  signature="$(cast wallet sign "${hw_args[@]}" --no-hash "$safe_tx_hash")"
fi

# Confirm the signer is allowed to propose, and surface the on-chain nonce. The service accepts a proposal
# from a Safe OWNER or from a registered DELEGATE of that Safe (a delegate may propose but never counts
# toward the signing threshold); anything else the service rejects, so fail early. Failing closed: if the
# delegate lookup can't be made, a non-owner is refused.
if [ -n "$rpc" ]; then
  owners="$(cast call "$safe" 'getOwners()(address[])' --rpc-url "$rpc" 2>/dev/null || true)"
  if [ -n "$owners" ] && ! printf '%s' "$owners" | grep -qi "${sender#0x}"; then
    # Not an owner -> allow only if a registered delegate of this Safe on the tx service.
    delresp="$(curl_auth -sSL "$service/api/v2/delegates/?safe=$safe_cs" 2>/dev/null || true)"
    if printf '%s' "$delresp" | jq -e --arg s "$sender" \
         '[.results[]?.delegate // empty | ascii_downcase] | index(($s|ascii_downcase))' >/dev/null 2>&1; then
      echo "note: $sender is not an owner but IS a registered delegate of Safe $safe_cs — proposing as delegate (no threshold weight)." >&2
    else
      echo "refusing to propose: signer $sender is neither an owner nor a registered delegate of Safe $safe" >&2
      echo "owners: $owners" >&2
      exit 1
    fi
  fi
  onchain_nonce="$(cast call "$safe" 'nonce()(uint256)' --rpc-url "$rpc" 2>/dev/null | awk '{print $1}' || echo '?')"
else
  onchain_nonce="(ETH_RPC unset; owner check skipped)"
fi

to_cs="$(cast to-check-sum-address "$to")"
sender_cs="$(cast to-check-sum-address "$sender")"

body="$(jq -nc \
  --arg to "$to_cs" --arg data "$data" --arg gt "$ZERO" --arg rr "$ZERO" \
  --arg hash "$safe_tx_hash" --arg sender "$sender_cs" --arg sig "$signature" --arg origin "$origin" \
  --argjson op "$operation" --argjson nonce "$nonce" \
  '{to:$to, value:"0", data:$data, operation:$op, safeTxGas:"0", baseGas:"0", gasPrice:"0",
    gasToken:$gt, refundReceiver:$rr, nonce:$nonce, contractTransactionHash:$hash,
    sender:$sender, signature:$sig, origin:$origin}')"

url="$service/api/v1/safes/$safe_cs/multisig-transactions/"

echo "About to PROPOSE (not execute) a Safe transaction:"
echo "  safe:        $safe_cs"
echo "  to:          $to_cs"
echo "  value:       0"
echo "  operation:   $operation ($([ "$operation" = 1 ] && echo DelegateCall || echo Call))"
echo "  nonce:       $nonce        (Safe on-chain nonce: $onchain_nonce)"
echo "  safeTxHash:  $safe_tx_hash"
echo "  signer:      $sender_cs"
echo "  service:     $url"
echo

if [ "$dry_run" = 1 ]; then
  echo "--dry-run: not posting. Request body:"
  echo "$body" | jq .
  exit 0
fi

printf 'Propose this to the Safe Transaction Service? (y/n) '
read -r reply
[ "$reply" = "y" ] || { echo "Aborted (nothing proposed)."; exit 1; }

http_code="$(curl_auth -sSL -o /tmp/safe_propose_resp.$$ -w '%{http_code}' -X POST "$url" \
  -H 'Content-Type: application/json' \
  -d "$body")"
resp="$(cat /tmp/safe_propose_resp.$$ 2>/dev/null || true)"; rm -f /tmp/safe_propose_resp.$$

if [ "$http_code" = 201 ] || [ "$http_code" = 200 ]; then
  echo "Proposed. It is now pending in the Safe UI (sign/execute there):"
  echo "  https://app.safe.global/transactions/queue?safe=$shortname:$safe_cs"
else
  echo "proposal failed (HTTP $http_code):" >&2
  printf '%s\n' "${resp:-<no body>}" >&2
  [ -z "${SAFE_API_KEY:-}" ] && echo "(if the service requires authentication, set SAFE_API_KEY; or override SAFE_TX_SERVICE)" >&2
  exit 1
fi
