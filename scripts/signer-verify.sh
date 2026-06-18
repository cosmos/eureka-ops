#!/usr/bin/env bash
set -euo pipefail

# Safe signer verification — OFFLINE generator. Given a pending Safe transaction's canonical payload
# (published per-nonce in COORDINATOR-HASH-TABLE.md), recompute the EIP-712 hashes, decode what it does,
# and print the exact values you must then see in the Safe UI (Advanced details) and on your Ledger before
# signing. NOTHING is fetched, signed, or sent — no network, no API key, no jq. Needs only `cast` (Foundry).
#
#   scripts/signer-verify.sh <nonce> [--table <path>] [--expect-subcalls <N>]
#       Run it from the repo you checked out: it finds the operation's COORDINATOR-HASH-TABLE.md
#       automatically (under <repo>/runbooks/operations/), recomputes the nonce's hashes, confirms they
#       match the table's published safeTxHash, and prints the expected card. --table overrides discovery.
#   scripts/signer-verify.sh --to <addr> --operation <0|1> --data <0x..> --nonce <n> --expect <0xHash> [--safe <addr>]
#       Manual mode: paste the row's to/operation/data/expect FROM THE TABLE (never from the Safe UI).
#
# It recomputes the safeTxHash from the payload and compares it to the published value -> one PASS or REJECT
# (exit non-zero on REJECT). Then you confirm the printed domainHash/messageHash (your Ledger) and safeTxHash
# (Safe UI) match. The hash math is plain keccak/abi-encode, so the Foundry version does not matter.
#
# --expect-subcalls <N>: for the step-7 MultiSend execute, REJECT unless it has exactly N sub-calls.

CHAIN="${CHAIN:-1}"   # mainnet — this bundle is for the chain-1 v3 upgrade
ZERO=0x0000000000000000000000000000000000000000
DOMAIN_TYPEHASH=0x47e79534a245952e8b16893a336b85a3d9ea9fa8c573f3d803afb92a79469218
SAFE_TX_TYPEHASH=0xbb8310d486368db6bd6f849402fdd73ad53d316b5a4b2644ad6efe0f941286d8
GOV_SAFE=0x7B96CD54aA750EF83ca90eA487e0bA321707559a

# Known mainnet addresses for this upgrade (override via env for testnet). Lowercased for comparison.
MULTISEND="$(printf '%s' "${MULTISEND_CALL_ONLY:-0x9641d764fc13c8B624c04430C7356C1C7C8102e2}" | tr 'A-Z' 'a-z')"
TIMELOCK_ADDR="$(printf '%s' "${TIMELOCK:-0xb3999B2D30dD8c9faEcE5A8a503fAe42b8b1b614}" | tr 'A-Z' 'a-z')"

command -v cast >/dev/null || { echo "ERROR: 'cast' not found. Install Foundry, open a NEW terminal, then re-run. (curl -L https://foundry.paradigm.xyz | bash ; foundryup)" >&2; exit 2; }

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
      # operationId == keccak(abi.encode(target,value,data,predecessor,salt)) — informational.
      local opid; opid="$(cast keccak "$(cast abi-encode 'x(address,uint256,bytes,bytes32,bytes32)' "$target" "${val:-0}" "$inner" "$pre" "$salt" 2>/dev/null)" 2>/dev/null || echo '?')"
      echo "    operationId:    $opid"
      case "$(lc "$isel")" in
        0x4f1ef286) local ni; ni="$(cast decode-calldata 'upgradeToAndCall(address,bytes)' "$inner" 2>/dev/null | sed -n '1p')"; echo "    new impl:       ${ni:-?}";;
        0x25c471a0) local rid; rid="$(cast decode-calldata 'grantRole(uint64,address,uint32)' "$inner" 2>/dev/null | sed -n '1p')"; echo "    grants role:    ${rid:-?}  (RATE_LIMITER is 5)"; if [ "${rid:-x}" = 0 ]; then rej "scheduled grantRole targets ADMIN_ROLE (0) — NOT part of this upgrade"; fi;;
        0xac9650d8) echo "    (multicall — rate-limiter grant: role 5 + escrow; bound by the safeTxHash)";;
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

# --- core: print the expected card + verdict for one tx -------------------------------------------------
EXPECT=""
EXPECT_SUBCALLS=""
verify_one() {
  REJECTS=(); WARNS=()
  local to="$1" value="$2" data="$3" operation="$4" nonce="$5" safe="$6"
  [ -n "$data" ] && [ "$data" != "null" ] || data=0x

  is_hex_addr "$to"   || { echo "REJECT: 'to' ($to) is not a 0x+40-hex address (the table row is malformed)" >&2; return 1; }
  is_hex_addr "$safe" || { echo "REJECT: 'safe' ($safe) is not a 0x+40-hex address" >&2; return 1; }
  is_hex_data "$data" || { echo "REJECT: 'data' is not 0x-hex with an even length" >&2; return 1; }
  case "$operation" in 0|1) ;; *) echo "REJECT: operation is '$operation' (must be 0=CALL or 1=DELEGATECALL)" >&2; return 1;; esac

  local domain data_hashed message message_hash safe_tx_hash
  domain="$(cast keccak "$(cast abi-encode 'x(bytes32,uint256,address)' "$DOMAIN_TYPEHASH" "$CHAIN" "$safe")")"
  data_hashed="$(cast keccak "$data")"
  # canonical Safe tx for this upgrade: gas/refund fields are all zero
  message="$(cast abi-encode 'x(bytes32,address,uint256,bytes32,uint8,uint256,uint256,uint256,address,address,uint256)' \
    "$SAFE_TX_TYPEHASH" "$to" "$value" "$data_hashed" "$operation" 0 0 0 "$ZERO" "$ZERO" "$nonce")"
  message_hash="$(cast keccak "$message")"
  safe_tx_hash="$(cast keccak "$(cast concat-hex 0x1901 "$domain" "$message_hash")")"

  local op_label="CALL (0)"; [ "$operation" = 1 ] && op_label="DELEGATECALL (1)"
  local sel="0x$(printf '%s' "${data#0x}" | cut -c1-8)"

  is_zero "$value" || rej "value is non-zero ($value)"
  if [ "$operation" = 1 ] && [ "$(lc "$to")" != "$MULTISEND" ]; then rej "DELEGATECALL to $to, not MultiSendCallOnly ($MULTISEND)"; fi

  echo "========================================================================"
  echo "  EXPECTED VALUES — confirm your Safe UI (Advanced details) + Ledger match these, then sign"
  echo "  Safe $safe   chain $CHAIN   nonce $nonce"
  echo "  to:          $to"
  echo "  value:       $value      operation: $op_label"
  echo "  action:      $(sel_name "$sel")  ($sel)"
  decode_inner "$sel" "$data"
  echo "  gas/refund:  safeTxGas/baseGas/gasPrice = 0 ; gasToken/refundReceiver = $ZERO"
  echo "  ----- your Ledger shows these TWO (it does NOT show the safeTxHash) -----"
  echo "  domainHash:  $domain"
  echo "  messageHash: $message_hash"
  echo "  ----- the Safe UI -> Advanced details shows this -----"
  echo "  safeTxHash:  $safe_tx_hash"

  if [ -n "$EXPECT" ]; then
    if [ "$(lc "$safe_tx_hash")" = "$(lc "$EXPECT")" ]; then echo "  integrity:   computed safeTxHash == the published table value"; else rej "computed safeTxHash != the published table value ($EXPECT) — the table payload is INCONSISTENT; do not use it, tell the coordinator"; fi
  fi

  echo "========================================================================"
  if [ "${#REJECTS[@]}" -ne 0 ]; then
    echo "  ##############  REJECT — DO NOT SIGN  ##############"
    for r in ${REJECTS[@]+"${REJECTS[@]}"}; do echo "   - $r"; done
    echo "  Capture this output and tell the coordinator so ALL signers hold."
    return 1
  fi
  for w in ${WARNS[@]+"${WARNS[@]}"}; do echo "  !! note: $w"; done
  echo "  ==>  PASS — these are the exact values to expect. In the Safe UI open this nonce's"
  echo "       Advanced details and confirm to / operation / data match; when you click Sign, confirm your"
  echo "       Ledger's Domain hash + Message hash equal the two above (whole 64 chars). All match -> sign."
  echo "       Anything different in the UI/Ledger, or more than one tx at this nonce -> reject and report."
  return 0
}

# --- arg parsing ----------------------------------------------------------------------------------------
TABLE=""; to=""; data="0x"; operation=""; nonce=""; value=0; safe="$GOV_SAFE"; manual=0
args=( ${@+"$@"} )
for a in ${args[@]+"${args[@]}"}; do case "$a" in --to|--data|--operation) manual=1;; esac; done

if [ "$manual" = 1 ]; then
  while [ "$#" -gt 0 ]; do case "$1" in
    --to) to="$2"; shift 2;; --data) data="$2"; shift 2;; --operation) operation="$2"; shift 2;;
    --nonce) nonce="$2"; shift 2;; --value) value="$2"; shift 2;; --expect) EXPECT="$2"; shift 2;;
    --safe) safe="$2"; shift 2;; --expect-subcalls) EXPECT_SUBCALLS="$2"; shift 2;;
    *) echo "unknown arg: $1" >&2; exit 2;; esac; done
  [ -n "$to" ] && [ -n "$operation" ] && [ -n "$nonce" ] || { echo "manual mode needs --to --operation --nonce (and --data), and --expect taken FROM THE TABLE (never the Safe UI)" >&2; exit 2; }
  verify_one "$to" "$value" "$data" "$operation" "$nonce" "$safe"; exit $?
fi

# table mode: first arg is the nonce
[ "$#" -ge 1 ] || { sed -n '3,18p' "$0"; exit 2; }
nonce="$1"; shift || true
while [ "$#" -gt 0 ]; do case "$1" in
  --table) TABLE="$2"; shift 2;; --expect-subcalls) EXPECT_SUBCALLS="$2"; shift 2;;
  *) echo "unknown arg: $1" >&2; exit 2;; esac; done
printf '%s' "$nonce" | grep -Eq '^[0-9]+$' || { echo "first argument must be a nonce (a number), or use manual mode (--to/--operation/--data/--nonce/--expect)" >&2; exit 2; }

find_table() {
  if [ -n "$TABLE" ]; then [ -f "$TABLE" ] && { printf '%s' "$TABLE"; return 0; }; return 1; fi
  local d root m; local matches=()
  d="$(cd "$(dirname "$0")" 2>/dev/null && pwd || true)"
  # checked-out repo: this script lives at <repo>/scripts/, the table at <repo>/runbooks/operations/<op>/
  root="$(cd "${d:-.}/.." 2>/dev/null && pwd || true)"
  if [ -n "$root" ]; then
    for m in "$root"/runbooks/operations/*/COORDINATOR-HASH-TABLE.md; do [ -f "$m" ] && matches+=("$m"); done
    [ "${#matches[@]}" -eq 1 ] && { printf '%s' "${matches[0]}"; return 0; }
    [ "${#matches[@]}" -gt 1 ] && { echo "ERROR: multiple operation tables under $root/runbooks/operations/ — pass --table <path>" >&2; return 2; }
  fi
  # fallback: co-located with the script, the current dir, or $HOME
  for m in "${d:-.}/COORDINATOR-HASH-TABLE.md" "./COORDINATOR-HASH-TABLE.md" "$HOME/COORDINATOR-HASH-TABLE.md"; do
    [ -f "$m" ] && { printf '%s' "$m"; return 0; }
  done
  return 1
}
tbl="$(find_table)" || { echo "ERROR: payloads table not found. Put COORDINATOR-HASH-TABLE.md next to this script (or in this dir / \$HOME), or pass --table <path>." >&2; exit 2; }

# payload rows look like:  <nonce>|<safe>|<to>|<operation>|<safeTxHash>|<data>
row="$(grep "^${nonce}|0x" "$tbl" | head -1)" || true
row="$(printf '%s' "$row" | tr -d '\r')"   # tolerate CRLF if the repo was checked out on Windows
[ -n "$row" ] || { echo "No payload row for nonce $nonce in $tbl. Sign ONLY nonces listed there; anything else -> stop and report." >&2; exit 1; }
IFS='|' read -r r_nonce r_safe r_to r_op r_exp r_data <<EOF
$row
EOF
EXPECT="$r_exp"
verify_one "$r_to" 0 "$r_data" "$r_op" "$r_nonce" "$r_safe"; exit $?
