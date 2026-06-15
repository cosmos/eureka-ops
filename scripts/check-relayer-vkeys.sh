#!/usr/bin/env bash
set -euo pipefail

# Verify the RUNNING proof-api / eureka-relayer is serving the SP1 programs whose vkeys are recorded in the
# deployment JSON (i.e. the keys the on-chain light clients are/were migrated to). This is the end-to-end
# check that `just sp1-vkeys` cannot give you: sp1-vkeys only hashes the *released* ELFs, it does not prove
# the deployed relayer actually loaded them.
#
# How: the proof-api `CreateClient` RPC returns the SP1ICS07Tendermint *creation calldata*, whose constructor
# args embed the four vkeys the relayer derived from its loaded programs. We decode those (structurally, via
# script/helpers/decode_create_client.py -- no dependency on local contract bytecode/version) and compare
# them to deployments/<env>/<chain>.json. Match => proofs from this relayer will verify against the clients;
# mismatch => every client update would revert, so do NOT cut over.
#
# The vkeys are a property of the loaded programs, so they are the same for every client the relayer serves;
# one CreateClient call is therefore enough to validate all clients in the deployment.
#
# Usage: scripts/check-relayer-vkeys.sh [--env e] [--chain c] [--addr host:port] [--src SRC] [--dst DST]
#                                       [--service S] [--zk groth16|plonk] [--client <id>]
# Env (used when the flag is omitted): EUREKA_ENVIRONMENT, EUREKA_CHAIN, PROOF_API_ADDR, SRC_CHAIN, DST_CHAIN,
#      PROOFAPI_SERVICE, GRPCURL_FLAGS (default -plaintext), PROOF_TYPE (default groth16).
# Requires: grpcurl, jq, python3.

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
env="${EUREKA_ENVIRONMENT:-}"
chain="${EUREKA_CHAIN:-}"
addr="${PROOF_API_ADDR:-localhost:3000}"
src="${SRC_CHAIN:-}"
dst="${DST_CHAIN:-}"
service="${PROOFAPI_SERVICE:-}"
grpcurl_flags="${GRPCURL_FLAGS:--plaintext}"
zk="${PROOF_TYPE:-groth16}"
only_client=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    --env) env="${2:?--env needs a value}"; shift 2 ;;
    --chain) chain="${2:?--chain needs a value}"; shift 2 ;;
    --addr) addr="${2:?--addr needs host:port}"; shift 2 ;;
    --src) src="${2:?--src needs a chain id}"; shift 2 ;;
    --dst) dst="${2:?--dst needs a chain id}"; shift 2 ;;
    --service) service="${2:?--service needs a value}"; shift 2 ;;
    --zk) zk="${2:?--zk needs groth16|plonk}"; shift 2 ;;
    --client) only_client="${2:?--client needs an id}"; shift 2 ;;
    -h | --help) sed -n '3,26p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 1 ;;
  esac
done

command -v grpcurl >/dev/null || { echo "grpcurl not found (needed to call the proof-api)" >&2; exit 1; }
command -v jq >/dev/null || { echo "jq not found" >&2; exit 1; }
command -v python3 >/dev/null || { echo "python3 not found (needed to decode the response)" >&2; exit 1; }
[ -n "$env" ] && [ -n "$chain" ] || { echo "set EUREKA_ENVIRONMENT/EUREKA_CHAIN or pass --env/--chain" >&2; exit 1; }
[ -n "$src" ] || { echo "SRC_CHAIN not set (proof-api source / Cosmos chain id); pass --src" >&2; exit 1; }
[ -n "$dst" ] || { echo "DST_CHAIN not set (Ethereum chain id, decimal, e.g. 11155111); pass --dst" >&2; exit 1; }

dep="$root/deployments/$env/$chain.json"
test -f "$dep" || { echo "deployment not found: $dep" >&2; exit 1; }

# grpcurl wants a bare host:port (TLS is chosen via GRPCURL_FLAGS, not a scheme). Strip an accidental
# URL scheme / trailing slash so PROOF_API_ADDR=http://localhost:3000 still works.
addr="${addr#http://}"; addr="${addr#https://}"; addr="${addr#grpc://}"; addr="${addr%/}"

# Discover the gRPC service via reflection unless one was provided (relayer.RelayerService on v0.7.x,
# proofapi.ProofApiService on v0.8.x).
if [ -z "$service" ]; then
  service="$(grpcurl $grpcurl_flags "$addr" list 2>/dev/null | grep -E '(^|\.)(RelayerService|ProofApiService)$' | head -1 || true)"
fi
[ -n "$service" ] || {
  echo "could not find a CreateClient service via reflection on $addr; set PROOFAPI_SERVICE / --service. Services seen:" >&2
  grpcurl $grpcurl_flags "$addr" list >&2 || true
  exit 1
}

# sp1_verifier is required by CreateClient but is just echoed back into the constructor args; it does NOT
# affect the relayer-derived vkeys. Reuse any client's verifier, else the zero address.
sp1_verifier="$(jq -r 'first(.light_clients[].verifier // empty) // "0x0000000000000000000000000000000000000000"' "$dep")"

echo "==> Asking $addr ($service, src=$src dst=$dst, zk=$zk) for a CreateClient to read its vkeys" >&2
req="$(jq -nc --arg s "$src" --arg d "$dst" --arg v "$sp1_verifier" --arg z "$zk" \
  '{src_chain:$s, dst_chain:$d, parameters:{sp1_verifier:$v, zk_algorithm:$z}}')"
resp="$(grpcurl $grpcurl_flags -d "$req" "$addr" "$service/CreateClient")" || { echo "CreateClient call failed against $addr" >&2; exit 1; }
txb64="$(jq -r '.tx // empty' <<<"$resp")"
[ -n "$txb64" ] || { echo "proof-api returned no tx; response: $resp" >&2; exit 1; }
calldata="0x$(printf '%s' "$txb64" | base64 -d | od -An -v -tx1 | tr -d ' \n')"

decoded="$(CALLDATA="$calldata" python3 "$root/script/helpers/decode_create_client.py")"
r_uc="$(jq -r '.updateClientVkey' <<<"$decoded")"
r_mem="$(jq -r '.membershipVkey' <<<"$decoded")"
r_ucm="$(jq -r '.ucAndMembershipVkey' <<<"$decoded")"
r_mis="$(jq -r '.misbehaviourVkey' <<<"$decoded")"

echo
echo "Relayer-reported vkeys (from $service/CreateClient):"
echo "  updateClient     $r_uc"
echo "  membership       $r_mem"
echo "  ucAndMembership  $r_ucm"
echo "  misbehaviour     $r_mis"
echo

lc() { printf '%s' "$1" | tr 'A-Z' 'a-z'; }
clients="$(jq -c --arg cid "$only_client" '.light_clients[] | select(.clientId != null and .clientId != "") | select($cid == "" or .clientId == $cid)' "$dep")"
[ -n "$clients" ] || { echo "no matching light clients in $dep (client id '$only_client'?)" >&2; exit 1; }

fail=0
while IFS= read -r c; do
  cid="$(jq -r '.clientId' <<<"$c")"
  ok=1
  for pair in \
    "updateClient:updateClientVkey:$r_uc" \
    "membership:membershipVkey:$r_mem" \
    "ucAndMembership:ucAndMembershipVkey:$r_ucm" \
    "misbehaviour:misbehaviourVkey:$r_mis"; do
    label="${pair%%:*}"; rest="${pair#*:}"; field="${rest%%:*}"; rval="${rest#*:}"
    jval="$(jq -r --arg f "$field" '.[$f] // ""' <<<"$c")"
    if [ "$(lc "$jval")" != "$(lc "$rval")" ]; then
      echo "FAIL $cid: $label vkey mismatch"
      echo "    json:    $jval"
      echo "    relayer: $rval"
      ok=0; fail=1
    fi
  done
  [ "$ok" = 1 ] && echo "OK   $cid: all four vkeys match the running relayer"
done <<<"$clients"

if [ "$fail" -ne 0 ]; then
  echo >&2
  echo "relayer vkey check FAILED for $dep -- the running relayer is NOT serving the programs these clients expect." >&2
  echo "Do NOT migrate / cut over: proofs from this relayer would revert. Fix the relayer's program version or re-run 'just sp1-vkeys --write'." >&2
  exit 1
fi
echo
echo "relayer vkey check passed: $addr serves the exact SP1 programs recorded in $dep"
