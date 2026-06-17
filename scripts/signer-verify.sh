#!/usr/bin/env bash
set -euo pipefail

# Safe signer verification — recompute the EIP-712 hashes for a pending Safe transaction, decode what it
# actually does, and tell you PASS / REJECT so an owner can confirm it on a hardware wallet. NOTHING is
# signed or sent. Needs only `cast` (Foundry); `curl`+`jq` are used by the fetch-by-nonce convenience mode.
# The hash math is plain keccak/abi-encode, so the Foundry version does not matter.
#
#   scripts/signer-verify.sh <chain-id> <safe-address> <nonce> [--expect <0xSafeTxHash>]
#       Fetch the pending tx at that nonce from the Safe service and verify it.
#   scripts/signer-verify.sh <chain-id> <safe-address> --to <addr> --data <0x..> --operation <0|1> --nonce <n> [--expect <0x..>]
#       Manual mode (no network): paste `to`/`data`/`operation` from the Safe UI "Advanced details".
#
# --expect <hash>: paste the safeTxHash from the coordinator's table; the script does a full byte-for-byte
# compare and prints one unmissable PASS or REJECT (and exits non-zero on REJECT). USE IT.
# --expect-subcalls <N>: for the step-7 MultiSend, REJECT unless it has exactly N sub-calls (catches an
# omitted/extra op the per-op pending guard can't see; e.g. N=10 = 4 core + 2 migrations + 4 rate-limiter).
#
# Exit code: 0 only if no REJECT condition fired (and, if --expect/--expect-subcalls were given, they matched).
# A duplicate same-nonce result (>1 tx at the nonce) is also a non-zero exit. Non-zero otherwise.

ZERO=0x0000000000000000000000000000000000000000
DOMAIN_TYPEHASH=0x47e79534a245952e8b16893a336b85a3d9ea9fa8c573f3d803afb92a79469218
SAFE_TX_TYPEHASH=0xbb8310d486368db6bd6f849402fdd73ad53d316b5a4b2644ad6efe0f941286d8

# Known mainnet addresses for this upgrade (override via env for testnet). Lowercased for comparison.
MULTISEND="$(printf '%s' "${MULTISEND_CALL_ONLY:-0x9641d764fc13c8B624c04430C7356C1C7C8102e2}" | tr 'A-Z' 'a-z')"
TIMELOCK_ADDR="$(printf '%s' "${TIMELOCK:-0xb3999B2D30dD8c9faEcE5A8a503fAe42b8b1b614}" | tr 'A-Z' 'a-z')"

command -v cast >/dev/null || { echo "ERROR: 'cast' not found. Install Foundry, open a NEW terminal, then re-run. (curl -L https://foundry.paradigm.xyz | bash ; foundryup)" >&2; exit 2; }

[ "$#" -ge 3 ] || { sed -n '3,22p' "$0"; exit 2; }
chain="$1"; safe="$2"; shift 2

is_hex_addr() { printf '%s' "$1" | grep -Eiq '^0x[0-9a-f]{40}$'; }
is_hex_data() { printf '%s' "$1" | grep -Eiq '^0x([0-9a-f]{2})*$'; }
is_zero()     { printf '%s' "$1" | grep -Eiq '^0x?0*$'; }   # 0, 0x0, 0x000...0
lc()          { printf '%s' "$1" | tr 'A-Z' 'a-z'; }

sel_name() {
  case "$(lc "$1")" in
    0x8d80ff0a) echo "multiSend(bytes)";; 0x134008d3) echo "TimelockController.execute";;
    0x01d5062a) echo "TimelockController.schedule";; 0x4f1ef286) echo "upgradeToAndCall";;
    0x5f516889) echo "addIBCApp";; 0xac9650d8) echo "multicall";;
    0xcce0b265) echo "migrateClient";; 0x25c471a0) echo "grantRole";;
    "0x"|"") echo "(no calldata)";; *) echo "(unknown selector $1)";;
  esac
}

REJECTS=(); WARNS=()
rej()  { REJECTS=( ${REJECTS[@]+"${REJECTS[@]}"} "$1" ); }
warn() { WARNS=( ${WARNS[@]+"${WARNS[@]}"} "$1" ); }

# --- one level deeper: decode the timelock op a schedule/execute carries, and enumerate a MultiSend ------
decode_inner() {
  local outer_sel="$1" data="$2"
  case "$(lc "$outer_sel")" in
    0x01d5062a|0x134008d3)   # schedule(target,value,data,pre,salt[,delay]) / execute(...)
      local sig fields target val inner pre salt
      if [ "$(lc "$outer_sel")" = 0x01d5062a ]; then sig='schedule(address,uint256,bytes,bytes32,bytes32,uint256)'; else sig='execute(address,uint256,bytes,bytes32,bytes32)'; fi
      fields="$(cast decode-calldata "$sig" "$data" 2>/dev/null)" || { echo "    inner: COULD NOT DECODE"; rej "schedule/execute inner calldata did not decode"; return; }
      target="$(printf '%s\n' "$fields" | sed -n '1p')"; val="$(printf '%s\n' "$fields" | sed -n '2p')"
      inner="$(printf '%s\n' "$fields" | sed -n '3p')"; pre="$(printf '%s\n' "$fields" | sed -n '4p')"; salt="$(printf '%s\n' "$fields" | sed -n '5p')"
      local isel="0x$(printf '%s' "${inner#0x}" | cut -c1-8)"
      echo "    inner target:   $target"
      echo "    inner call:     $(sel_name "$isel")  ($isel)"
      [ -n "$val" ] && ! is_zero "$val" && rej "scheduled op carries non-zero value ($val)"
      # operationId == keccak(abi.encode(target,value,data,predecessor,salt)) — compare to the table.
      local opid; opid="$(cast keccak "$(cast abi-encode 'x(address,uint256,bytes,bytes32,bytes32)' "$target" "${val:-0}" "$inner" "$pre" "$salt" 2>/dev/null)" 2>/dev/null || echo '?')"
      echo "    operationId:    $opid   (must match the coordinator table)"
      case "$(lc "$isel")" in
        0x4f1ef286) local ni; ni="$(cast decode-calldata 'upgradeToAndCall(address,bytes)' "$inner" 2>/dev/null | sed -n '1p')"; echo "    new impl:       ${ni:-?}  (must match the step-4 implementation)";;
        0x25c471a0) local rid; rid="$(cast decode-calldata 'grantRole(uint64,address,uint32)' "$inner" 2>/dev/null | sed -n '1p')"; echo "    grants role:    ${rid:-?}  (RATE_LIMITER is 5)"; [ "${rid:-x}" = 0 ] && rej "scheduled grantRole targets ADMIN_ROLE (0) — NOT part of this upgrade";;
        0xac9650d8) echo "    (multicall — for the rate-limiter grant: confirm role 5 + escrow in the table)";;
      esac
      ;;
    0x8d80ff0a)              # multiSend(bytes): enumerate each packed sub-call
      local packed; packed="$(cast decode-calldata 'multiSend(bytes)' "$data" 2>/dev/null | sed -n '1p')"; packed="${packed#0x}"
      [ -n "$packed" ] || { echo "    multiSend: COULD NOT DECODE"; rej "multiSend payload did not decode"; return; }
      local pos=0 i=0 total=${#packed}
      while [ "$pos" -lt "$total" ]; do
        local op to val dlen dbytes isel
        op="${packed:pos:2}"; to="0x${packed:$((pos+2)):40}"; val="${packed:$((pos+42)):64}"; dlen="${packed:$((pos+106)):64}"
        local dld=$(( 16#${dlen: -12} )); dbytes=$(( dld * 2 ))
        isel="0x${packed:$((pos+170)):8}"
        i=$((i+1))
        echo "    sub-call $i:     op=$op to=$to  call=$(sel_name "$isel") ($isel)"
        [ "$op" = 00 ] || rej "MultiSend sub-call $i is operation=$op (not CALL)"
        [ "$(lc "$to")" = "$TIMELOCK_ADDR" ] || rej "MultiSend sub-call $i targets $to, not the timelock $TIMELOCK_ADDR"
        printf '%s' "$val" | grep -Eq '^0+$' || rej "MultiSend sub-call $i carries non-zero value"
        [ "$(lc "$isel")" = 0x134008d3 ] || rej "MultiSend sub-call $i is not a timelock execute() ($isel)"
        pos=$(( pos + 170 + dbytes ))
      done
      echo "    ($i sub-call(s); each must be a timelock execute() — confirm the count matches expectations)"
      if [ -n "$EXPECT_SUBCALLS" ] && [ "$i" != "$EXPECT_SUBCALLS" ]; then
        rej "MultiSend has $i sub-calls, expected $EXPECT_SUBCALLS (--expect-subcalls) -- an op may be missing or extra"
      fi
      ;;
    0x5f516889)              # addIBCApp(string,address)
      local f port app; f="$(cast decode-calldata 'addIBCApp(string,address)' "$data" 2>/dev/null)"
      port="$(printf '%s\n' "$f" | sed -n '1p')"; app="$(printf '%s\n' "$f" | sed -n '2p')"
      echo "    port:           ${port:-?}   app: ${app:-?}"
      [ "$port" = '"gmpport"' ] || [ "$port" = 'gmpport' ] || rej "addIBCApp port is ${port:-?}, expected gmpport"
      ;;
    *) echo "    inner: CONTENTS NOT VERIFIED — compare to the coordinator table" ;;
  esac
}

# --- core: print hashes + decoded action + verdict for one tx -------------------------------------------
EXPECT=""
EXPECT_SUBCALLS=""
verify_one() {
  REJECTS=(); WARNS=()
  local to="$1" value="$2" data="$3" operation="$4" nonce="$5"
  local safeTxGas="$6" baseGas="$7" gasPrice="$8" gasToken="$9" refundReceiver="${10}"
  [ -n "$data" ] && [ "$data" != "null" ] || data=0x

  is_hex_addr "$to"   || { echo "REJECT: 'to' ($to) is not a 0x+40-hex address (paste it WITH 0x)" >&2; return 1; }
  is_hex_data "$data" || { echo "REJECT: 'data' is not 0x-hex with an even length (paste it WITH 0x)" >&2; return 1; }
  case "$operation" in 0|1) ;; *) echo "REJECT: operation is '$operation' (must be 0=CALL or 1=DELEGATECALL)" >&2; return 1;; esac

  local domain data_hashed message message_hash safe_tx_hash
  domain="$(cast keccak "$(cast abi-encode 'x(bytes32,uint256,address)' "$DOMAIN_TYPEHASH" "$chain" "$safe")")"
  data_hashed="$(cast keccak "$data")"
  message="$(cast abi-encode 'x(bytes32,address,uint256,bytes32,uint8,uint256,uint256,uint256,address,address,uint256)' \
    "$SAFE_TX_TYPEHASH" "$to" "$value" "$data_hashed" "$operation" "$safeTxGas" "$baseGas" "$gasPrice" "$gasToken" "$refundReceiver" "$nonce")"
  message_hash="$(cast keccak "$message")"
  safe_tx_hash="$(cast keccak "$(cast concat-hex 0x1901 "$domain" "$message_hash")")"

  local op_label="CALL (0)"; [ "$operation" = 1 ] && op_label="DELEGATECALL (1)"
  local sel="0x$(printf '%s' "${data#0x}" | cut -c1-8)"

  # Deploy-independent invariants (true for every tx in this upgrade).
  is_zero "$value"          || rej "value is non-zero ($value)"
  is_zero "$safeTxGas"      || rej "safeTxGas is non-zero"
  is_zero "$baseGas"        || rej "baseGas is non-zero"
  is_zero "$gasPrice"       || rej "gasPrice is non-zero"
  is_zero "$gasToken"       || rej "gasToken is set ($gasToken) — refund vector"
  is_zero "$refundReceiver" || rej "refundReceiver is set ($refundReceiver) — refund vector"
  if [ "$operation" = 1 ] && [ "$(lc "$to")" != "$MULTISEND" ]; then rej "DELEGATECALL to $to, not MultiSendCallOnly ($MULTISEND)"; fi

  echo "========================================================================"
  echo "  Safe $safe   chain $chain   nonce $nonce"
  echo "  to:          $to"
  echo "  value:       $value      operation: $op_label"
  echo "  action:      $(sel_name "$sel")  ($sel)"
  decode_inner "$sel" "$data"
  echo "  ----- COMPARE THESE TO YOUR HARDWARE WALLET -----"
  echo "  domainHash:  $domain"
  echo "  messageHash: $message_hash"
  echo "  safeTxHash:  $safe_tx_hash"

  if [ -n "$EXPECT" ]; then
    if [ "$(lc "$safe_tx_hash")" = "$(lc "$EXPECT")" ]; then echo "  --expect:    MATCHES the coordinator table"; else rej "safeTxHash != --expect ($EXPECT)"; fi
  fi

  echo "========================================================================"
  if [ "${#REJECTS[@]}" -ne 0 ]; then
    echo "  ##############  REJECT — DO NOT SIGN  ##############"
    for r in ${REJECTS[@]+"${REJECTS[@]}"}; do echo "   - $r"; done
    echo "  Capture this output and tell the coordinator so ALL signers hold."
    return 1
  fi
  for w in ${WARNS[@]+"${WARNS[@]}"}; do echo "  !! note: $w"; done
  if [ -n "$EXPECT" ]; then
    echo "  ==>  PASS. Confirm this safeTxHash matches the Safe UI (Advanced details) AND your hardware"
    echo "       wallet display, then sign in the Safe UI."
  else
    echo "  ==>  No red flags. Re-run with --expect <table hash> for a machine-checked PASS; then confirm"
    echo "       it matches the Safe UI + your wallet and sign in the Safe UI."
  fi
  return 0
}

# --- arg parsing ----------------------------------------------------------------------------------------
manual=0; to=""; data="0x"; operation=""; nonce=""; value=0
args=( ${@+"$@"} )
for a in ${args[@]+"${args[@]}"}; do case "$a" in --to|--data|--operation) manual=1;; esac; done

if [ "$manual" = 1 ]; then
  while [ "$#" -gt 0 ]; do case "$1" in
    --to) to="$2"; shift 2;; --data) data="$2"; shift 2;; --operation) operation="$2"; shift 2;;
    --nonce) nonce="$2"; shift 2;; --value) value="$2"; shift 2;; --expect) EXPECT="$2"; shift 2;;
    --expect-subcalls) EXPECT_SUBCALLS="$2"; shift 2;;
    *) echo "unknown arg: $1" >&2; exit 2;; esac; done
  [ -n "$to" ] && [ -n "$operation" ] && [ -n "$nonce" ] || { echo "manual mode needs --to --operation --nonce (and --data)" >&2; exit 2; }
  verify_one "$to" "$value" "$data" "$operation" "$nonce" 0 0 0 "$ZERO" "$ZERO"; exit $?
fi

# fetch-by-nonce
nonce="$1"; shift || true
while [ "$#" -gt 0 ]; do case "$1" in
  --expect) EXPECT="$2"; shift 2;; --expect-subcalls) EXPECT_SUBCALLS="$2"; shift 2;;
  *) echo "unknown arg: $1" >&2; exit 2;; esac; done
command -v curl >/dev/null || { echo "ERROR: 'curl' not found (needed for fetch mode; or use manual mode)" >&2; exit 2; }
command -v jq   >/dev/null || { echo "ERROR: 'jq' not found (only needed for fetch mode — use manual mode, which needs just cast)" >&2; exit 2; }

case "$chain" in
  1)        base="https://safe-transaction-mainnet.safe.global";;
  11155111) base="https://safe-transaction-sepolia.safe.global";;
  *)        base="${SAFE_TX_SERVICE:-}"; [ -n "$base" ] || { echo "set SAFE_TX_SERVICE for chain $chain" >&2; exit 2; };;
esac
safe_cs="$(cast to-check-sum-address "$safe")"

# curl with the optional Safe API key as a properly separated header (if/else avoids the empty-array trap).
fetch() { if [ -n "${SAFE_API_KEY:-}" ]; then curl -fsSL -H "Authorization: Bearer $SAFE_API_KEY" "$1"; else curl -fsSL "$1"; fi; }
url="$base/api/v1/safes/$safe_cs/multisig-transactions/?nonce=$nonce"
resp="$(fetch "$url" 2>/dev/null)" || { echo "ERROR: could not reach the Safe service at $base (network/API key/rate-limit). Set SAFE_API_KEY and retry, or use manual mode with values from the Safe UI." >&2; exit 2; }

n="$(printf '%s' "$resp" | jq '.results | length')"
[ "$n" -gt 0 ] || { echo "No pending transaction found at nonce $nonce for $safe_cs." >&2; exit 1; }
rc=0
if [ "$n" -gt 1 ]; then
  echo "##### STOP: $n different transactions exist at nonce $nonce. This is ABNORMAL for this upgrade." >&2
  echo "Do NOT sign. Re-run with --expect <the table hash> so only the matching one is accepted, and tell the coordinator." >&2
  rc=1   # duplicate same-nonce is abnormal: force a non-zero exit even if a sibling passes its invariants
fi

for (( i=0; i<n; i++ )); do
  IFS=$'\t' read -r to value data operation nonce_i safeTxGas baseGas gasPrice gasToken refundReceiver apihash <<EOF
$(printf '%s' "$resp" | jq -r ".results[$i] | [.to,(.value//\"0\"),(.data//\"0x\"),(.operation|tostring),(.nonce|tostring),(.safeTxGas//\"0\"),(.baseGas//\"0\"),(.gasPrice//\"0\"),(.gasToken//\"$ZERO\"),(.refundReceiver//\"$ZERO\"),(.safeTxHash//\"\")] | @tsv")
EOF
  verify_one "$to" "$value" "$data" "$operation" "$nonce_i" "$safeTxGas" "$baseGas" "$gasPrice" "$gasToken" "$refundReceiver" || rc=1
done
exit $rc
