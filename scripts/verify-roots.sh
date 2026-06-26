#!/usr/bin/env bash
set -euo pipefail

# T-minus trust-root assertions (read-only, fail-closed): the TimelockController's own roles, the
# governance + customizer Safe owner sets/thresholds, the SP1 gateway route, and the escrow set.
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

# Reconstruct every holder a timelock role was EVER granted, and assert none outside the allowed set is
# still active. Covers DEFAULT_ADMIN (self-admin), and CANCELLER/PROPOSER -- a stray CANCELLER can cancel()
# a scheduled op mid-delay (grief the 72 h round); a stray PROPOSER can schedule a malicious op.
stray_check() {  # stray_check <roleHash> <roleName> <allowed-addr>...
  local role="$1" name="$2"; shift 2
  local allowed=" "; local a; for a in "$@"; do allowed="$allowed$(lc "$a") "; done
  local h held s=0 holders=""
  while IFS= read -r h; do holders="$holders $h"; done < <(
    cast logs 'RoleGranted(bytes32 indexed,address indexed,address indexed)' --address "$TL" \
      --from-block "$FROM_BLOCK" --to-block latest "$role" --rpc-url "$RPC" --json 2>/dev/null \
      | jq -r '.[].topics[2]' | sed 's/^0x000000000000000000000000/0x/' | sort -u)
  for h in $holders; do
    [ -n "$h" ] || continue
    case "$allowed" in *" $(lc "$h") "*) continue ;; esac
    held="$(call "$TL" 'hasRole(bytes32,address)(bool)' "$role" "$h")"
    [ "$held" = "true" ] && { bad "STRAY $name holder still active: $h"; s=1; }
  done
  [ "$s" = 0 ] && ok "no stray $name holders (only the expected $name set)"
}
if [ -n "${FROM_BLOCK:-}" ]; then
  echo "  -- reconstructing timelock role holders from events (from block $FROM_BLOCK) --"
  stray_check "$ADMIN_ROLE" "DEFAULT_ADMIN" "$TL"
  stray_check "$CANC" "CANCELLER" "$SAFE"
  stray_check "$PROP" "PROPOSER" "$SAFE"
else
  echo "  INFO  set FROM_BLOCK=<timelock deploy block> to reconstruct stray DEFAULT_ADMIN/CANCELLER/PROPOSER holders"
fi

echo "=== B. Governance Safe ($SAFE) ==="
chk "threshold" "$(call "$SAFE" 'getThreshold()(uint256)' | awk '{print $1}')" "$EXP_THRESH"
owners="$(call "$SAFE" 'getOwners()(address[])' | tr -d '[]' | tr ',' '\n' | tr -d ' ' | grep -E '^0x' || true)"
ocount="$(printf '%s\n' "$owners" | grep -c '^0x' || true)"
[ "$ocount" = "$EXP_OWNERS" ] && ok "owner count = $ocount" || bad "owner count = $ocount (expected $EXP_OWNERS)"
echo "  owners (eyeball against the signer table):"; printf '%s\n' "$owners" | sed 's/^/      /'

echo "=== B2. Customizer Safe (UN-timelocked authority — step 8 / addIBCApp, ID_CUSTOMIZER) ==="
CUST="$(jq -re '.accessManagerRoles.idCustomizers[0] // empty' "$DEP" 2>/dev/null || true)"
if [ -z "$CUST" ] || [ "$(lc "$CUST")" = "$ZERO" ]; then
  echo "  INFO  no idCustomizer in $DEP"
elif ! call "$CUST" 'getThreshold()(uint256)' >/dev/null 2>&1; then
  echo "  INFO  customizer $CUST is not a Safe (EOA, e.g. testnet) — no owners/threshold to assert"
else
  chk "customizer Safe threshold" "$(call "$CUST" 'getThreshold()(uint256)' | awk '{print $1}')" "${EXP_CUST_THRESH:-2}"
  cust_owners="$(call "$CUST" 'getOwners()(address[])' | tr -d '[]' | tr ',' '\n' | tr -d ' ' | grep -cE '^0x' || true)"
  [ "$cust_owners" = "${EXP_CUST_OWNERS:-5}" ] && ok "customizer Safe owner count = $cust_owners" \
    || bad "customizer Safe owner count = $cust_owners (expected ${EXP_CUST_OWNERS:-5})"
fi

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

echo "=== D. Escrows: enumeration + stray probe ==="
# No `escrow` field in the JSON to compare against -- the real assertion is the stray-escrow probe below.
# Collect each JSON client's on-chain escrow for that probe; print it to eyeball vs RECORD.
ICS20="$(jq -re '.ics20Transfer.proxy' "$DEP")"
json_escrows=""
while IFS= read -r cid; do
  [ -n "$cid" ] || continue
  onchain="$(call "$ICS20" 'getEscrow(string)(address)' "$cid")"
  json_escrows="$json_escrows $(lc "$onchain")"
  echo "  INFO  escrow $cid -> $onchain"
done < <(jq -r '.light_clients[].clientId // empty' "$DEP")
# Best-effort enumeration: probe the client-N series for an escrow that is NOT one of the JSON clients'
# (getEscrow returns the zero address for an unregistered client). This closes the "rate-limiter holder on
# a non-JSON escrow" blind spot for the auto-numbered series; a client with an unrelated name would still
# need an event scan -- cross-checked against the prod relayer config (only the 2 migrated; client-4 is in the JSON but dropped).
stray=0
for n in $(seq 0 "${CLIENT_PROBE_MAX:-19}"); do
  e="$(call "$ICS20" 'getEscrow(string)(address)' "client-$n")"
  [ "$(lc "$e")" = "$ZERO" ] && continue
  case " $json_escrows " in *" $(lc "$e") "*) ;; *) bad "stray escrow for client-$n: $e (NOT a JSON light_client)"; stray=1 ;; esac
done
[ "$stray" = 0 ] && ok "no stray escrows in the client-0..${CLIENT_PROBE_MAX:-19} series (set CLIENT_PROBE_MAX to widen)"

echo
echo "============================================================"
echo "SUMMARY: $pass passed, $fail failed"
[ "$fail" -eq 0 ] && { echo "ALL TRUST-ROOT CHECKS PASSED"; exit 0; } || { echo "TRUST-ROOT CHECKS FAILED — do NOT proceed"; exit 1; }
