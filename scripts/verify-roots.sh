#!/usr/bin/env bash
set -euo pipefail

# T-minus trust-root assertions. The whole upgrade trusts three roots that NO other tool checks: the
# TimelockController's own role config, the governance Safe's owner set/threshold, and the SP1 verifier
# gateway route. This turns "someone checked manually once" into a re-runnable, fail-closed gate. Read-only.
#
# Usage: ETH_RPC=<rpc> scripts/verify-roots.sh [env=mainnet] [chain=1]
# Env:
#   ETH_RPC                 required RPC.
#   FROM_BLOCK              timelock deploy block, for the stray-DEFAULT_ADMIN event reconstruction. If unset,
#                           that one check is skipped (the direct hasRole checks still run).
#   EXPECTED_MIN_DELAY      default 259200 (72 h). EXPECTED_THRESHOLD default 4. EXPECTED_OWNERS default 7.
#   SP1_GATEWAY / SP1_REAL_VERIFIER  default the mainnet v6.1.0 Groth16 gateway / real verifier.
#
# Reads .safe and .accessManagerRoles.admin (the timelock) + the escrows from deployments/<env>/<chain>.json.

ENV="${1:-mainnet}"; CHAIN="${2:-1}"
RPC="${ETH_RPC:-${FOUNDRY_ETH_RPC_URL:-}}"; [ -n "$RPC" ] || { echo "set ETH_RPC" >&2; exit 2; }
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEP="$ROOT/deployments/$ENV/$CHAIN.json"; test -f "$DEP" || { echo "deployment not found: $DEP" >&2; exit 2; }

EXP_DELAY="${EXPECTED_MIN_DELAY:-259200}"
EXP_THRESH="${EXPECTED_THRESHOLD:-4}"
EXP_OWNERS="${EXPECTED_OWNERS:-7}"
GATEWAY="${SP1_GATEWAY:-0x397A5f7f3dBd538f23DE225B51f532c34448dA9B}"
REAL_VERIFIER="${SP1_REAL_VERIFIER:-0xb69f2584CBcFf99a58C4e7002E8b89Af54a6f4e2}"
ZERO=0x0000000000000000000000000000000000000000
ADMIN_ROLE=0x0000000000000000000000000000000000000000000000000000000000000000

SAFE="$(jq -re '.safe' "$DEP")"
TL="$(jq -re '(.accessManagerRoles.admin // .ics26Router.timelockAdmin)' "$DEP")"
PROP="$(cast keccak 'PROPOSER_ROLE')"; EXEC="$(cast keccak 'EXECUTOR_ROLE')"; CANC="$(cast keccak 'CANCELLER_ROLE')"

lc(){ printf '%s' "$1" | tr 'A-Z' 'a-z'; }
call(){ cast call "$@" --rpc-url "$RPC"; }
pass=0; fail=0
ok(){  pass=$((pass+1)); printf '  \033[32mPASS\033[0m  %s\n' "$1"; }
bad(){ fail=$((fail+1)); printf '  \033[31mFAIL\033[0m  %s\n' "$1"; }
chk(){ # chk "<label>" "<got>" "<want>"
  [ "$(lc "$2")" = "$(lc "$3")" ] && ok "$1 = $2" || bad "$1 = $2 (expected $3)"; }

echo "Verifying trust roots for $ENV/$CHAIN  (Safe=$SAFE  Timelock=$TL)"

echo "=== A. TimelockController roles ($TL) ==="
# cast annotates large uints (e.g. "259200 [2.592e5]"); take the first token for numeric compares.
chk "getMinDelay" "$(call "$TL" 'getMinDelay()(uint256)' | awk '{print $1}')" "$EXP_DELAY"
chk "EXECUTOR(address(0)) [open-executor DoS]" "$(call "$TL" 'hasRole(bytes32,address)(bool)' "$EXEC" "$ZERO")" "false"
chk "PROPOSER  = Safe"  "$(call "$TL" 'hasRole(bytes32,address)(bool)' "$PROP" "$SAFE")" "true"
chk "EXECUTOR  = Safe"  "$(call "$TL" 'hasRole(bytes32,address)(bool)' "$EXEC" "$SAFE")" "true"
chk "CANCELLER = Safe"  "$(call "$TL" 'hasRole(bytes32,address)(bool)' "$CANC" "$SAFE")" "true"
chk "DEFAULT_ADMIN = Timelock (self-admin)" "$(call "$TL" 'hasRole(bytes32,address)(bool)' "$ADMIN_ROLE" "$TL")" "true"
chk "DEFAULT_ADMIN = Safe (must be false)"  "$(call "$TL" 'hasRole(bytes32,address)(bool)' "$ADMIN_ROLE" "$SAFE")" "false"

# Stray-admin reconstruction: the ONLY DEFAULT_ADMIN holder must be the timelock itself.
if [ -n "${FROM_BLOCK:-}" ]; then
  echo "  -- reconstructing DEFAULT_ADMIN holders from events (from block $FROM_BLOCK) --"
  admins=""
  while IFS= read -r a; do admins="$admins $a"; done < <(
    cast logs 'RoleGranted(bytes32 indexed,address indexed,address indexed)' --address "$TL" \
      --from-block "$FROM_BLOCK" --to-block latest "$ADMIN_ROLE" --rpc-url "$RPC" --json 2>/dev/null \
      | jq -r '.[].topics[2]' | sed 's/^0x000000000000000000000000/0x/' | sort -u)
  stray=0
  for a in $admins; do
    [ "$(lc "$a")" = "$(lc "$TL")" ] && continue
    held="$(call "$TL" 'hasRole(bytes32,address)(bool)' "$ADMIN_ROLE" "$a")"
    [ "$held" = "true" ] && { bad "STRAY DEFAULT_ADMIN holder still active: $a"; stray=1; }
  done
  [ "$stray" = 0 ] && ok "no stray DEFAULT_ADMIN holders (only the timelock)"
else
  echo "  INFO  set FROM_BLOCK=<timelock deploy block> to also reconstruct stray DEFAULT_ADMIN holders"
fi

echo "=== B. Governance Safe ($SAFE) ==="
chk "threshold" "$(call "$SAFE" 'getThreshold()(uint256)' | awk '{print $1}')" "$EXP_THRESH"
owners="$(call "$SAFE" 'getOwners()(address[])' | tr -d '[]' | tr ',' '\n' | tr -d ' ' | grep -E '^0x' || true)"
ocount="$(printf '%s\n' "$owners" | grep -c '^0x' || true)"
[ "$ocount" = "$EXP_OWNERS" ] && ok "owner count = $ocount" || bad "owner count = $ocount (expected $EXP_OWNERS)"
echo "  owners (eyeball against the signer table):"; printf '%s\n' "$owners" | sed 's/^/      /'

echo "=== C. SP1 verifier gateway route ($GATEWAY) ==="
# selector = first 4 bytes of the real verifier's VERIFIER_HASH (NOT a fixed constant)
vh="$(call "$REAL_VERIFIER" 'VERIFIER_HASH()(bytes32)' 2>/dev/null || echo '')"
if [ -z "$vh" ]; then bad "could not read VERIFIER_HASH() from $REAL_VERIFIER"; else
  sel="${vh:0:10}"
  route="$(call "$GATEWAY" 'routes(bytes4)(address,bool)' "$sel" 2>/dev/null || echo '')"
  routed="$(printf '%s\n' "$route" | sed -n '1p')"; frozen="$(printf '%s\n' "$route" | sed -n '2p')"
  chk "gateway routes $sel -> real verifier" "$routed" "$REAL_VERIFIER"
  chk "route frozen == false" "${frozen:-?}" "false"
fi

echo "=== D. Escrows match the JSON (consistency) ==="
ICS20="$(jq -re '.ics20Transfer.proxy' "$DEP")"
while IFS= read -r cid; do
  [ -n "$cid" ] || continue
  onchain="$(call "$ICS20" 'getEscrow(string)(address)' "$cid")"
  jsonesc="$(jq -r --arg c "$cid" '(.light_clients | to_entries[] | select(.value.clientId==$c) | .value.escrow) // empty' "$DEP")"
  if [ -n "$jsonesc" ] && [ "$jsonesc" != "$ZERO" ]; then chk "escrow $cid" "$onchain" "$jsonesc"
  else echo "  INFO  escrow $cid -> $onchain (no JSON escrow recorded to compare)"; fi
done < <(jq -r '.light_clients[].clientId // empty' "$DEP")
echo "  NOTE: this compares the JSON clients only; enumerating escrows for clients NOT in the JSON needs an"
echo "        event scan (see READINESS-REVIEW §6.2) — confirm the on-chain client set equals the JSON's."

echo
echo "============================================================"
echo "SUMMARY: $pass passed, $fail failed"
[ "$fail" -eq 0 ] && { echo "ALL TRUST-ROOT CHECKS PASSED"; exit 0; } || { echo "TRUST-ROOT CHECKS FAILED — do NOT proceed"; exit 1; }
