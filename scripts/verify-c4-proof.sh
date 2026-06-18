#!/usr/bin/env bash
set -euo pipefail

# C4 — end-to-end proof gate. Proves the running new-build proof-api emits an SP1 proof that the LIVE
# on-chain v6.1.0 verifier ACCEPTS. A vkey match (check-relayer-vkeys) proves the prover loaded the right
# PROGRAMS; it does NOT prove the prover's SP1-SDK build emits a proof the verifier accepts. This does, by
# running the exact call SP1ICS07Tendermint._verifySP1Proof makes: VERIFIER.verifyProof(vKey, pub, proof).
#
# Flow: CreateClient (record target vkeys, guard != current v5) -> UpdateClient (a REAL proof; may take
# minutes) -> decode out the SP1Proof -> guard it is genuinely v6.1 (proof selector 0x4388a21c, not the v5
# 0xa4594c59) -> cast call gateway.verifyProof + the routed verifier directly. No revert == PASS.
#
# Read-only: verifyProof is a view call; nothing is broadcast. Uses a public mainnet RPC for the verify.
#
# Usage: scripts/verify-c4-proof.sh [--client cosmoshub-0] [--src cosmoshub-4] [--dst 1] [--addr host:port]
# Env: PROOF_API_ADDR (default localhost:3000), MAINNET_RPC (default publicnode), CLIENT_ID/SRC_CHAIN/DST_CHAIN,
#      UPDATE_TIMEOUT (grpcurl -max-time for UpdateClient, default 900s).
# Requires: grpcurl, jq, python3, cast.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ADDR="${PROOF_API_ADDR:-localhost:3000}"
CLIENT="${CLIENT_ID:-cosmoshub-0}"
SRC="${SRC_CHAIN:-cosmoshub-4}"
DST="${DST_CHAIN:-1}"
MRPC="${MAINNET_RPC:-https://ethereum-rpc.publicnode.com}"
GF="${GRPCURL_FLAGS:--plaintext}"
SVC="proofapi.ProofApiService"
UPDATE_TIMEOUT="${UPDATE_TIMEOUT:-900}"

GATEWAY="${SP1_GATEWAY:-0x397A5f7f3dBd538f23DE225B51f532c34448dA9B}"
V5_VKEY_LC="0x009443d9d0658974b5fecb61555406ad45bebbfa4ae3540ff0462e49b0925346"  # current v5 updateClient vkey
V6_SELECTOR="0x4388a21c"   # first 4 bytes of the v6.1.0 verifier's VERIFIER_HASH
V5_SELECTOR="0xa4594c59"   # current v5 verifier selector (must NOT appear -> would mean old proof-api)

while [ "$#" -gt 0 ]; do case "$1" in
  --client) CLIENT="$2"; shift 2;; --src) SRC="$2"; shift 2;; --dst) DST="$2"; shift 2;;
  --addr) ADDR="$2"; shift 2;; -h|--help) sed -n '3,20p' "$0"; exit 0;;
  *) echo "unknown arg: $1" >&2; exit 1;; esac; done

for t in grpcurl jq python3 cast; do command -v "$t" >/dev/null || { echo "missing tool: $t" >&2; exit 1; }; done
ADDR="${ADDR#http://}"; ADDR="${ADDR#https://}"; ADDR="${ADDR%/}"
lc(){ printf '%s' "$1" | tr 'A-Z' 'a-z'; }
die(){ echo "FAIL: $*" >&2; exit 1; }

echo "== C4 proof gate =="
echo "   proof-api : $ADDR  ($SVC, src=$SRC dst=$DST, client=$CLIENT)"
echo "   verify on : $MRPC  gateway=$GATEWAY"
echo

echo "-- reachability --"
grpcurl $GF -max-time 8 "$ADDR" list >/dev/null 2>&1 || die "cannot reach proof-api at $ADDR (is the port-forward up?)"
echo "   reachable."

echo
echo "-- 1/4 CreateClient (record target vkeys; guard != current v5) --"
sp1v="$(jq -r 'first(.light_clients[].verifier // empty) // "0x0000000000000000000000000000000000000000"' "$ROOT/deployments/mainnet/1.json")"
ccreq="$(jq -nc --arg s "$SRC" --arg d "$DST" --arg v "$sp1v" '{src_chain:$s,dst_chain:$d,parameters:{sp1_verifier:$v,zk_algorithm:"groth16"}}')"
ccresp="$(grpcurl $GF -max-time 60 -d "$ccreq" "$ADDR" "$SVC/CreateClient")" || die "CreateClient failed"
cctx="$(jq -r '.tx // empty' <<<"$ccresp")"; [ -n "$cctx" ] || die "CreateClient returned no tx"
cccd="0x$(printf '%s' "$cctx" | base64 -d | od -An -v -tx1 | tr -d ' \n')"
ccdec="$(CALLDATA="$cccd" python3 "$ROOT/script/helpers/decode_create_client.py")"
TARGET_UC_VKEY="$(jq -r '.updateClientVkey' <<<"$ccdec")"
echo "   proof-api updateClient vkey : $TARGET_UC_VKEY"
echo "   (membership $(jq -r '.membershipVkey' <<<"$ccdec") | ucAndMem $(jq -r '.ucAndMembershipVkey' <<<"$ccdec") | misbeh $(jq -r '.misbehaviourVkey' <<<"$ccdec"))"
[ "$(lc "$TARGET_UC_VKEY")" != "$V5_VKEY_LC" ] || die "proof-api reports the CURRENT v5 vkey ($V5_VKEY_LC) — this is the OLD proof-api, not the new v6.1 build. Aborting."
echo "   GUARD ok: not the current v5 vkey."

echo
echo "-- 2/4 UpdateClient (generating a REAL proof — can take minutes) --"
ucreq="$(jq -nc --arg s "$SRC" --arg d "$DST" --arg c "$CLIENT" '{src_chain:$s,dst_chain:$d,dst_client_id:$c}')"
ucresp="$(grpcurl $GF -max-time "$UPDATE_TIMEOUT" -d "$ucreq" "$ADDR" "$SVC/UpdateClient")" || die "UpdateClient failed (timeout ${UPDATE_TIMEOUT}s or prover error)"
uctx="$(jq -r '.tx // empty' <<<"$ucresp")"; [ -n "$uctx" ] || die "UpdateClient returned no tx (response: $ucresp)"
uctarget="$(jq -r '.address // empty' <<<"$ucresp")"
uccd="0x$(printf '%s' "$uctx" | base64 -d | od -An -v -tx1 | tr -d ' \n')"
echo "   tx target (proof-api .address): ${uctarget:-<none>}"
echo "   calldata bytes: $(( (${#uccd}-2)/2 ))"

echo
echo "-- 3/4 decode SP1Proof + guards --"
dec="$(CALLDATA="$uccd" python3 "$ROOT/script/helpers/decode_update_client.py")"
VKEY="$(jq -r '.vKey' <<<"$dec")"; PUB="$(jq -r '.publicValues' <<<"$dec")"; PROOF="$(jq -r '.proof' <<<"$dec")"
PSEL="$(jq -r '.selector' <<<"$dec")"; WRAP="$(jq -r '.wrapper' <<<"$dec")"
echo "   wrapper selector : $WRAP   (0x6fbf8079=updateClient(string,bytes))"
echo "   proof vKey       : $VKEY"
echo "   proof selector   : $PSEL"
echo "   publicValues len : $(( (${#PUB}-2)/2 )) bytes   proof len: $(( (${#PROOF}-2)/2 )) bytes"
[ "$(lc "$PSEL")" = "$(lc "$V6_SELECTOR")" ] || {
  [ "$(lc "$PSEL")" = "$(lc "$V5_SELECTOR")" ] && die "proof carries the v5 selector $V5_SELECTOR — old proof-api. Aborting."
  die "proof selector $PSEL is neither v6.1 ($V6_SELECTOR) nor v5 ($V5_SELECTOR) — unexpected verifier. Aborting."; }
echo "   GUARD ok: proof selector == v6.1 ($V6_SELECTOR)."
[ "$(lc "$VKEY")" = "$(lc "$TARGET_UC_VKEY")" ] || die "proof vKey $VKEY != CreateClient updateClient vkey $TARGET_UC_VKEY (self-inconsistent proof-api)."
echo "   GUARD ok: proof vKey == proof-api target updateClient vkey."

# resolve the routed verifier from the gateway for this proof's selector
route="$(cast call "$GATEWAY" 'routes(bytes4)(address,bool)' "$PSEL" --rpc-url "$MRPC")"
RVERIFIER="$(printf '%s\n' "$route" | sed -n '1p')"; RFROZEN="$(printf '%s\n' "$route" | sed -n '2p')"
echo "   gateway routes $PSEL -> $RVERIFIER (frozen=$RFROZEN)"
[ "$(lc "$RFROZEN")" = "false" ] || die "gateway route for $PSEL is FROZEN."
[ "$(lc "$RVERIFIER")" != "$(lc 0x0000000000000000000000000000000000000000)" ] || die "gateway has no route for $PSEL."
echo "   routed verifier VERSION: $(cast call "$RVERIFIER" 'VERSION()(string)' --rpc-url "$MRPC" 2>&1 | head -1)"

echo
echo "-- 4/4 on-chain verifyProof (the C4 assertion) --"
echo "   [a] gateway.verifyProof (production path: client -> gateway -> verifier)"
if cast call "$GATEWAY" 'verifyProof(bytes32,bytes,bytes)' "$VKEY" "$PUB" "$PROOF" --rpc-url "$MRPC" >/dev/null 2>/tmp/c4_gw.err; then
  echo "       PASS — gateway accepted the proof (no revert)."; GW_OK=1
else
  echo "       FAIL — gateway reverted:"; sed 's/^/         /' /tmp/c4_gw.err; GW_OK=0
fi
echo "   [b] routed verifier.verifyProof (direct)"
if cast call "$RVERIFIER" 'verifyProof(bytes32,bytes,bytes)' "$VKEY" "$PUB" "$PROOF" --rpc-url "$MRPC" >/dev/null 2>/tmp/c4_v.err; then
  echo "       PASS — verifier accepted the proof (no revert)."; V_OK=1
else
  echo "       FAIL — verifier reverted:"; sed 's/^/         /' /tmp/c4_v.err; V_OK=0
fi

echo
echo "============================================================"
if [ "${GW_OK:-0}" = 1 ] && [ "${V_OK:-0}" = 1 ]; then
  cat <<EOF
C4 PASS — the new-build proof-api's SP1 proof verifies on-chain against the live v6.1.0 verifier.

RECORD:
  proof-api addr      : $ADDR   (src=$SRC dst=$DST client=$CLIENT)
  target updateClient : $VKEY
  proof selector      : $PSEL  -> gateway $GATEWAY -> verifier $RVERIFIER (v6.1.0)
  publicValues / proof: $(( (${#PUB}-2)/2 )) / $(( (${#PROOF}-2)/2 )) bytes
  verifyProof         : gateway=PASS  direct-verifier=PASS  (read-only cast call, no revert)
  >> still record the proof-api / sp1-programs build (commit + SP1-SDK version) for the lockstep assertion.
EOF
  exit 0
else
  echo "C4 FAIL — see reverts above. Do NOT treat the prover<->verifier path as proven."
  exit 1
fi
