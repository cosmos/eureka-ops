#!/usr/bin/env bash
set -euo pipefail

# Verify each SP1 light client's `.verifier` in a deployment JSON is the correct SP1 verifier for that client's
# zk algorithm and the target SP1 program version. The deployed SP1ICS07Tendermint calls
# `verifier.verifyProof(vkey, publicValues, proof)`; if `.verifier` is wrong, every proof the prover submits
# reverts and the client is stuck.
#
# Checks (per light client):
#   offline   `.verifier` == the canonical SP1 verifier *gateway* for this chain + the client's zkAlgorithm
#             (from node_modules/sp1-contracts/contracts/deployments/<chain>.json:
#              SP1_VERIFIER_GATEWAY_GROTH16 / SP1_VERIFIER_GATEWAY_PLONK). zkAlgorithm is decoded from
#              `.trustedClientState`. The gateway routes a proof to the right version verifier by its selector.
#   on-chain  (with an RPC) the gateway actually routes the target SP1 version's proof selector to the canonical
#             version verifier, and that verifier reports VERSION() == <sp1-version> (so it is the real, non-broken
#             verifier the prover's proofs target).
#
# Usage: scripts/check-sp1-verifier.sh [--env <env>] [--chain <chain>] [--rpc <url>] [--sp1-version v6.1.0]
# Env:   EUREKA_ENVIRONMENT, EUREKA_CHAIN, ETH_RPC  (used when the matching flag is omitted)
# Requires: jq, cast (foundry). The on-chain checks additionally need an RPC for the chain.

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
env="${EUREKA_ENVIRONMENT:-}"
chain="${EUREKA_CHAIN:-}"
rpc="${ETH_RPC:-}"
sp1_version="v6.1.0"

while [ "$#" -gt 0 ]; do
  case "$1" in
    --env) env="${2:?--env needs a value}"; shift 2 ;;
    --chain) chain="${2:?--chain needs a value}"; shift 2 ;;
    --rpc) rpc="${2:?--rpc needs a url}"; shift 2 ;;
    --sp1-version) sp1_version="${2:?--sp1-version needs a value}"; shift 2 ;;
    -h | --help) sed -n '3,24p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 1 ;;
  esac
done

command -v jq >/dev/null || { echo "jq not found" >&2; exit 1; }
command -v cast >/dev/null || { echo "cast not found (foundry)" >&2; exit 1; }
[ -n "$env" ] && [ -n "$chain" ] || { echo "set EUREKA_ENVIRONMENT/EUREKA_CHAIN or pass --env/--chain" >&2; exit 1; }

dep="$root/deployments/$env/$chain.json"
sp1="$root/node_modules/sp1-contracts/contracts/deployments/$chain.json"
test -f "$dep" || { echo "deployment not found: $dep" >&2; exit 1; }
test -f "$sp1" || { echo "no canonical SP1 deployments for chain $chain ($sp1); run bun/npm install" >&2; exit 1; }

# v6.1.0 -> V6_1_0 (the key prefix sp1-contracts uses for version verifiers)
ver_prefix="V$(printf '%s' "${sp1_version#v}" | tr '.' '_')"
lc() { printf '%s' "$1" | tr 'A-Z' 'a-z'; }

# ClientState ABI tuple (solidity-ibc-eureka IICS07TendermintMsgs.ClientState); zkAlgorithm is the last field.
CS_TYPE='(string,(uint8,uint8),(uint64,uint64),uint32,uint32,bool,uint8)'

fail=0
clients="$(jq -c '.light_clients[] | select(.clientId != null and .clientId != "")' "$dep")"
[ -n "$clients" ] || { echo "no light clients in $dep"; exit 0; }

while IFS= read -r client; do
  cid="$(jq -r '.clientId' <<<"$client")"
  verifier="$(jq -r '.verifier // ""' <<<"$client")"
  cs="$(jq -r '.trustedClientState // ""' <<<"$client")"

  if [ -z "$cs" ] || [ "$cs" = "null" ]; then
    echo "FAIL $cid: no trustedClientState to decode zkAlgorithm from"; fail=1; continue
  fi
  zk="$(cast abi-decode "x()($CS_TYPE)" "$cs" 2>/dev/null | sed -E 's/.*, (false|true), ([0-9]+)\)[[:space:]]*$/\2/')"
  case "$zk" in
    0) algo=GROTH16 ;;
    1) algo=PLONK ;;
    *) echo "FAIL $cid: could not decode zkAlgorithm (got '$zk')"; fail=1; continue ;;
  esac

  expected_gw="$(jq -r ".SP1_VERIFIER_GATEWAY_$algo // empty" "$sp1")"
  if [ -z "$expected_gw" ]; then
    echo "FAIL $cid: no SP1_VERIFIER_GATEWAY_$algo for chain $chain in $sp1"; fail=1; continue
  fi
  if [ "$(lc "$verifier")" != "$(lc "$expected_gw")" ]; then
    echo "FAIL $cid: .verifier=$verifier is not the $algo gateway ($expected_gw)"; fail=1; continue
  fi

  if [ -z "$rpc" ]; then
    echo "OK   $cid: $algo, .verifier is the canonical $algo gateway $expected_gw (offline; pass --rpc to check routing)"
    continue
  fi

  canon_ver="$(jq -r ".${ver_prefix}_SP1_VERIFIER_$algo // empty" "$sp1")"
  if [ -z "$canon_ver" ]; then
    echo "FAIL $cid: no ${ver_prefix}_SP1_VERIFIER_$algo for chain $chain in $sp1 (unknown SP1 version $sp1_version?)"; fail=1; continue
  fi
  vh="$(cast call "$canon_ver" "VERIFIER_HASH()(bytes32)" --rpc-url "$rpc" 2>/dev/null || true)"
  if [ -z "$vh" ]; then echo "FAIL $cid: could not read VERIFIER_HASH() from $canon_ver"; fail=1; continue; fi
  selector="${vh:0:10}" # 0x + 4 bytes
  route_raw="$(cast call "$verifier" "routes(bytes4)(address,bool)" "$selector" --rpc-url "$rpc" 2>/dev/null || true)"
  routed="$(printf '%s\n' "$route_raw" | sed -n '1p')"   # routes() returns (address verifier, bool frozen)
  frozen="$(printf '%s\n' "$route_raw" | sed -n '2p')"
  if [ "$(lc "$routed")" != "$(lc "$canon_ver")" ]; then
    echo "FAIL $cid: gateway $verifier routes selector $selector to '$routed', expected the $sp1_version $algo verifier $canon_ver"; fail=1; continue
  fi
  # A frozen route reverts every proof (SP1VerifierGateway.RouteIsFrozen), even though the address matches.
  if [ "$frozen" = "true" ]; then
    echo "FAIL $cid: gateway route for $selector is FROZEN (verifier $routed) -- proofs would revert RouteIsFrozen"; fail=1; continue
  fi
  reported="$(cast call "$routed" "VERSION()(string)" --rpc-url "$rpc" 2>/dev/null | tr -d '"' || true)"
  if [ "$reported" != "$sp1_version" ]; then
    echo "FAIL $cid: routed verifier $routed reports VERSION '$reported', expected '$sp1_version'"; fail=1; continue
  fi
  echo "OK   $cid: $algo, gateway $verifier routes $sp1_version proofs to $routed (VERSION $reported)"
done <<<"$clients"

if [ "$fail" -ne 0 ]; then
  echo "verifier check FAILED for $dep" >&2
  exit 1
fi
echo "verifier check passed for $dep"
