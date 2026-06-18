#!/usr/bin/env bash
set -euo pipefail

# Timelock-aware v2-to-v3 shadow rehearsal.
#
# Unlike scripts/shadow-v2-to-v3-upgrade.sh (which impersonates the AccessManager admin and calls the proxies
# directly), this driver exercises the *production* path against a v2 fork:
#   1. Deploys the v3 stack with ShadowForkV2ToV3Upgrade in SHADOW_FORK_DEPLOY_ONLY mode (proxies stay on v2).
#   2. Generates the schedule/execute timelock calldata from the actual `schedule-v3-*` / `execute-v3-*` recipes.
#   3. Submits it to the real TimelockController by impersonating the proposer Safe on the fork.
#   4. Proves the predecessor ordering: executing the ICS26Router upgrade before the ICS20Transfer upgrade must
#      revert.
#   5. Executes the whole upgrade (both proxy upgrades + beacon upgrades + SP1 migrations) as ONE atomic Safe
#      MultiSend transaction driven through the REAL Safe (execTransaction, pre-approved-hash signatures), then
#      registers ICS27 via the customizer's REAL authority (a 2-of-N Safe execTransaction CALL on a mainnet
#      fork — the production step-8 path; an EOA broadcast on testnet), initializes escrows, and verifies.
#
# This validates the timelock schedule/execute/ordering and the recipe-generated calldata end-to-end on the real
# v2 contracts — including the production atomic Safe MultiSend execute — the part the direct-broadcast rehearsal
# cannot cover.
#
# Requires an already-running Anvil fork of the (still-v2) chain, started with --auto-impersonate, e.g.
#   just shadow-start-sepolia
#
# Usage: [SP1_CLIENT_IDS=a,b,c] scripts/shadow-v2-to-v3-timelock-rehearsal.sh \
#          <chain-id> <source-env> <shadow-env> <fork-rpc>
#
# Env:
#   (The proposer/executor Safe is read from the deployment JSON's `.safe` key and impersonated on the fork.)
#   SP1_CLIENT_IDS               (optional) comma-separated client ids to deploy + migrate. Defaults to every
#                                clientId in the shadow deployment JSON; set this to migrate only a subset.
#   SHADOW_FORK_PRESERVE_DEPLOYMENT=1   reuse an already-prepared shadow JSON instead of copying the source.
#   SHADOW_FORK_DEPLOYER         (optional) funded EOA used to broadcast deploys (default: anvil account 0).
#   SHADOW_FORK_BALANCE_WEI      (optional) balance set on impersonated accounts (default: 100 ether).
#   MULTISEND_CALL_ONLY          (optional) override the MultiSendCallOnly address (default canonical Safe v1.4.1).
#   REHEARSE_RATE_LIMITER_GRANT=1      (optional) ALSO rehearse the production EXTRA_TIMELOCK_OPS folding path:
#                                schedule a representative rate-limiter role grant and fold its execute into the
#                                SAME atomic Safe MultiSend, then assert it landed. Off by default (core flow
#                                unchanged); set RL_GRANT_CLIENT_ID / RL_GRANT_ADDRESS to override the grant inputs.

usage() {
  sed -n '4,44p' "$0"
}

if [ "$#" -ne 4 ]; then
  usage
  exit 1
fi

chain_id="$1"
source_env="$2"
shadow_env="$3"
fork_rpc="$4"

if [[ "$shadow_env" != shadow-* ]]; then
  echo "shadow-env must start with 'shadow-' (got '$shadow_env') so real deployment files are not overwritten" >&2
  exit 1
fi

root="$(git rev-parse --show-toplevel)"
source_file="$root/deployments/$source_env/$chain_id.json"
shadow_dir="$root/deployments/$shadow_env"
shadow_file="$shadow_dir/$chain_id.json"
deployer="${SHADOW_FORK_DEPLOYER:-0xf39fd6e51aad88f6f4ce6ab8827279cfffb92266}"
balance="${SHADOW_FORK_BALANCE_WEI:-0x56BC75E2D63100000}"
sp1_client_ids="${SP1_CLIENT_IDS:-}"
# Opt-in rehearsal of the EXTRA_TIMELOCK_OPS folding path (off by default so the core flow is unchanged).
rehearse_rl_grant="${REHEARSE_RATE_LIMITER_GRANT:-0}"
rl_grant_addr="${RL_GRANT_ADDRESS:-0x000000000000000000000000000000000000dEaD}"
rl_grant_cid_override="${RL_GRANT_CLIENT_ID:-}"
# RL_GRANTS="cid:holder,cid:holder,..." rehearses the EXACT mainnet fold (e.g. 2 grants -> an 8-sub-call bundle).
# Unset = the single representative grant (back-compat). Setting RL_GRANTS implies REHEARSE_RATE_LIMITER_GRANT.
rl_grants_spec="${RL_GRANTS:-}"
[ -n "$rl_grants_spec" ] && rehearse_rl_grant=1

if [ ! -f "$source_file" ]; then
  echo "source deployment does not exist: $source_file" >&2
  exit 1
fi

actual_chain_id="$(cast chain-id --rpc-url "$fork_rpc")"
if [ "$actual_chain_id" != "$chain_id" ]; then
  echo "fork RPC chain id is $actual_chain_id, expected $chain_id" >&2
  echo "Start Anvil with --chain-id $chain_id so deployment paths line up." >&2
  exit 1
fi

mkdir -p "$shadow_dir"
if [ "${SHADOW_FORK_PRESERVE_DEPLOYMENT:-0}" = "1" ]; then
  if [ ! -f "$shadow_file" ]; then
    echo "SHADOW_FORK_PRESERVE_DEPLOYMENT=1 was set, but shadow deployment does not exist: $shadow_file" >&2
    exit 1
  fi
  echo "Using existing shadow deployment: $shadow_file"
else
  cp "$source_file" "$shadow_file"
fi

# Default the SP1 client ids to every client recorded in the shadow JSON; set SP1_CLIENT_IDS to override the set
# (e.g. a subset). The shadow JSON is the single source of truth for which clients get migrated.
if [ -z "$sp1_client_ids" ]; then
  sp1_client_ids="$(jq -r '[.light_clients[].clientId // empty] | join(",")' "$shadow_file")"
fi

# These exports make the `just` recipes operate on the shadow env / fork. Process env overrides .eureka-env.
export DEPLOYMENT_ENV="$shadow_env"
export EUREKA_ENVIRONMENT="$shadow_env"
export EUREKA_CHAIN="$chain_id"
export ETH_RPC="$fork_rpc"
export FOUNDRY_ETH_RPC_URL="$fork_rpc"

# ---------------------------------------------------------------------------
# 1. Deploy the v3 stack (proxies stay on v2 so the timelock can drive the upgrade below).
# ---------------------------------------------------------------------------
echo "==> Deploying v3 stack (deploy-only; proxies left on v2)"
cast rpc --rpc-url "$fork_rpc" anvil_setBalance "$deployer" "$balance" >/dev/null
(
  cd "$root"
  SHADOW_FORK_DEPLOY_ONLY=1 SP1_CLIENT_IDS="$sp1_client_ids" \
    forge script script/ShadowForkV2ToV3Upgrade.sol:ShadowForkV2ToV3Upgrade \
      --rpc-url "$fork_rpc" --broadcast --unlocked --sender "$deployer" -vvv
)

# Addresses are now recorded in the shadow JSON.
timelock="$(jq -re '(.accessManagerRoles.admin // .ics26Router.timelockAdmin)' "$shadow_file")"
id_customizer="$(jq -re '(.accessManagerRoles.idCustomizers[0] // .ics26Router.clientIdCustomizer // .ics26Router.portCustomizer)' "$shadow_file")"
ics20_proxy="$(jq -re '.ics20Transfer.proxy' "$shadow_file")"
# The proposer/executor Safe comes from the deployment JSON (.safe), the same source the just recipes read.
safe="$(jq -re '.safe' "$shadow_file")"
if [ "$safe" = "0x0000000000000000000000000000000000000000" ]; then
  echo "no proposer Safe configured in $shadow_file (.safe is the zero address)" >&2
  exit 1
fi

echo "==> Timelock: $timelock"
echo "==> Proposer Safe (impersonated): $safe"

# Fund the accounts that originate transactions on the fork.
cast rpc --rpc-url "$fork_rpc" anvil_setBalance "$safe" "$balance" >/dev/null
cast rpc --rpc-url "$fork_rpc" anvil_setBalance "$id_customizer" "$balance" >/dev/null

cd "$root"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
# Run a `just` recipe and extract the "timelock calldata: 0x..." line it prints (recipes called without a nonce,
# so they skip the Safe-hash step and print only the calldata).
recipe_calldata() {
  local out
  if ! out="$(just "$@")"; then
    echo "recipe failed: just $*" >&2
    exit 1
  fi
  local data
  data="$(printf '%s\n' "$out" | awk '/^timelock calldata: /{print $3; found=1} END{exit !found}')" || {
    echo "could not find 'timelock calldata:' in output of: just $*" >&2
    printf '%s\n' "$out" >&2
    exit 1
  }
  printf '%s\n' "$data"
}

# Submit timelock calldata as the proposer Safe; aborts on failure.
submit() {
  local data="$1" label="$2"
  if [ -z "$data" ] || [ "$data" = "0x" ]; then
    echo "refusing to submit empty calldata for: $label (a recipe likely failed)" >&2
    exit 1
  fi
  echo "    submit: $label"
  if ! cast send "$timelock" --data "$data" --from "$safe" --unlocked --rpc-url "$fork_rpc" >/dev/null; then
    echo "FAILED to submit: $label" >&2
    exit 1
  fi
}

# Submit timelock calldata expected to revert with the timelock's predecessor guard (the ordering assertion).
# A bare non-zero exit is NOT proof of ordering: an RPC/gas error, or a wrong-salt / wrong-predecessor revert
# from a buggy recipe (the very artifact this step exists to validate), would otherwise be mistaken for
# "ordering enforced". So require the revert to carry OZ TimelockController's TimelockUnexecutedPredecessor
# error and fail loudly on a revert for any other reason. (All ops are scheduled and the delay has passed
# before this runs, so the op is Ready and the unmet predecessor -- not a not-ready state -- is the trigger.)
submit_expect_revert() {
  local data="$1" label="$2"
  if [ -z "$data" ] || [ "$data" = "0x" ]; then
    echo "refusing to run the ordering assertion with empty calldata for: $label (a recipe likely failed)" >&2
    exit 1
  fi

  # Computed (not hardcoded) so it tracks the OZ error signature: if a dep bump renames the error, the on-chain
  # selector stops matching and this assertion fails loudly rather than silently passing on the wrong revert.
  local expected_sig="TimelockUnexecutedPredecessor(bytes32)"
  local expected_selector
  expected_selector="$(cast sig "$expected_sig")"
  if [ -z "$expected_selector" ] || [ "$expected_selector" = "0x" ]; then
    echo "could not compute the selector for $expected_sig via 'cast sig'" >&2
    exit 1
  fi

  # Capture combined output. The `if` condition keeps `set -e` from aborting on the (expected) non-zero exit;
  # cast surfaces the revert data (containing the custom-error selector) when anvil rejects the tx.
  local out
  if out="$(cast send "$timelock" --data "$data" --from "$safe" --unlocked --rpc-url "$fork_rpc" 2>&1)"; then
    echo "FAIL: $label was expected to revert (predecessor not met) but SUCCEEDED -- timelock ordering is NOT enforced" >&2
    exit 1
  fi

  if printf '%s' "$out" | grep -qiE "${expected_selector#0x}|TimelockUnexecutedPredecessor"; then
    echo "    ok: $label reverted with $expected_sig — timelock ordering is enforced"
  else
    echo "FAIL: $label reverted, but NOT with the expected predecessor guard ($expected_sig)." >&2
    echo "      A revert for any other reason (RPC/gas error, or a buggy recipe) does not prove ordering -- aborting." >&2
    echo "      cast output was:" >&2
    printf '%s\n' "$out" >&2
    exit 1
  fi
}

# Iterate SP1 client ids (comma-separated), bash-3.2 safe.
sp1_ids() {
  local IFS=','
  read -ra _ids <<< "$sp1_client_ids"
  for _id in ${_ids[@]+"${_ids[@]}"}; do
    [ -n "$_id" ] && printf '%s\n' "$_id"
  done
}

zero_addr="0x0000000000000000000000000000000000000000"
zero_bytes32="0x0000000000000000000000000000000000000000000000000000000000000000"
# Rate-limiter grant fold (REHEARSE_RATE_LIMITER_GRANT): role id + the single setRateLimit selector it gates.
rate_limiter_role=5                # IBCRolesLib.RATE_LIMITER_ROLE
rate_limit_set_sel="0xd34a3fd9"    # IRateLimit.setRateLimit(address,uint256) == rateLimiterSelectors()[0]

# Extract the value of a greppable "<label>: <value>" line (single-token value) from recipe output.
recipe_field() {
  local out="$1" label="$2"
  printf '%s\n' "$out" | awk -v lbl="$label" '
    !found && $0 ~ "^" lbl ": " { print $NF; found=1 }
    END { exit !found }'
}

# Collect SP1 client ids into the global _ms_ids array (passed as positional args to the *client_ids recipe).
build_client_id_args() {
  _ms_ids=()
  while IFS= read -r cid; do
    [ -n "$cid" ] && _ms_ids+=("$cid")
  done < <(sp1_ids)
}

# --- Rate-limiter grant fold (REHEARSE_RATE_LIMITER_GRANT=1) -----------------------------------------------
# Build the representative rate-limiter grant's schedule + execute timelock calldata into globals rl_schedule /
# rl_execute (plus rl_escrow / access_manager for the post-execute assertion). This is byte-identical to what
# `just timelock-grant-rate-limiter-role schedule|execute` (GrantRateLimiterRole.sol + _timelock-params) emits:
# the inner call is AccessManager.multicall([setTargetFunctionRole(escrow,[setRateLimit],RATE_LIMITER_ROLE),
# grantRole(RATE_LIMITER_ROLE, grantee, 0)]), wrapped in timelock schedule/execute with predecessor=0, salt=0
# (and getMinDelay() for schedule). We build the bytes with cast instead of driving that recipe because it is
# interactive (vm.prompt/vm.promptAddress + a `read -n1` confirm) and pulls bun install / forge build into the
# run -- too fragile to feed over a pipe -- and because the production fold itself takes this grant as a raw 0x
# execute blob captured out-of-band anyway (see safe.just execute-timelock-multisend). schedule and execute share
# the same target/value/data/predecessor/salt, so they map to the same TimelockController operation id.
# Parallel arrays over the grant set, plus rl_extra_ops (the ;-joined execute blobs for EXTRA_TIMELOCK_OPS).
rl_schedules=(); rl_executes=(); rl_escrows=(); rl_holders=(); rl_extra_ops=""

# Build one grant's schedule+execute timelock calldata for (cid, holder); echoes "schedule|execute|escrow".
# Byte-identical to GrantRateLimiterRole.sol: multicall([setTargetFunctionRole(escrow,[setRateLimit],ROLE),
# grantRole(ROLE, holder, 0)]) wrapped in schedule/execute (predecessor=0, salt=0, delay=getMinDelay()).
_build_rl_grant() {
  local cid="$1" holder="$2" escrow stfr grant am_data delay sched exe
  escrow="$(cast call "$ics20_proxy" "getEscrow(string)(address)" "$cid" --rpc-url "$fork_rpc")"
  [ "$escrow" != "$zero_addr" ] || { echo "client '$cid' has no escrow on the fork" >&2; exit 1; }
  stfr="$(cast calldata "setTargetFunctionRole(address,bytes4[],uint64)" "$escrow" "[$rate_limit_set_sel]" "$rate_limiter_role")"
  grant="$(cast calldata "grantRole(uint64,address,uint32)" "$rate_limiter_role" "$holder" 0)"
  am_data="$(cast calldata "multicall(bytes[])" "[$stfr,$grant]")"
  delay="$(cast call "$timelock" "getMinDelay()(uint256)" --rpc-url "$fork_rpc" | awk '{print $1}')"
  sched="$(cast calldata "schedule(address,uint256,bytes,bytes32,bytes32,uint256)" "$access_manager" 0 "$am_data" "$zero_bytes32" "$zero_bytes32" "$delay")"
  exe="$(cast calldata "execute(address,uint256,bytes,bytes32,bytes32)" "$access_manager" 0 "$am_data" "$zero_bytes32" "$zero_bytes32")"
  printf '%s|%s|%s\n' "$sched" "$exe" "$escrow"
}

prepare_rate_limiter_grant() {
  access_manager="$(jq -re '.accessManager' "$shadow_file")"
  if [ -z "$access_manager" ] || [ "$access_manager" = "$zero_addr" ]; then
    echo "rate-limiter fold requested but .accessManager is missing/zero in $shadow_file" >&2; exit 1
  fi
  # Grant set: RL_GRANTS="cid:holder,..." (the real mainnet fold) else a single representative grant.
  local pairs="$rl_grants_spec"
  if [ -z "$pairs" ]; then
    local cid="$rl_grant_cid_override"
    if [ -z "$cid" ]; then
      local _cid e
      while IFS= read -r _cid; do [ -n "$_cid" ] || continue
        e="$(cast call "$ics20_proxy" "getEscrow(string)(address)" "$_cid" --rpc-url "$fork_rpc")"
        [ "$e" != "$zero_addr" ] && { cid="$_cid"; break; }
      done < <(sp1_ids)
    fi
    [ -n "$cid" ] || { echo "no SP1 client has a non-zero escrow on the fork" >&2; exit 1; }
    pairs="$cid:$rl_grant_addr"
  fi
  local pair cid holder built sched exe escrow
  local oldifs="$IFS"; IFS=','
  for pair in $pairs; do
    IFS="$oldifs"
    [ -n "$pair" ] || continue
    cid="${pair%%:*}"; holder="${pair#*:}"
    built="$(_build_rl_grant "$cid" "$holder")"
    sched="${built%%|*}"; built="${built#*|}"; exe="${built%%|*}"; escrow="${built##*|}"
    rl_schedules+=("$sched"); rl_executes+=("$exe"); rl_escrows+=("$escrow"); rl_holders+=("$holder")
    [ -n "$rl_extra_ops" ] && rl_extra_ops="$rl_extra_ops;"
    rl_extra_ops="$rl_extra_ops$exe"
    echo "    rate-limiter grant: client '$cid' escrow $escrow grantee $holder"
    IFS=','
  done
  IFS="$oldifs"
  echo "    (${#rl_executes[@]} rate-limiter grant(s) to fold -> $(( 6 + ${#rl_executes[@]} )) total sub-calls with 4 core + 2 migrations)"
}

# Assert NONE of the folded grants' holders are members yet (so the post-execute assertion proves the work).
assert_rate_limiter_grant_absent() {
  local i member
  for i in $(seq 0 $(( ${#rl_holders[@]} - 1 )) ); do
    member="$(cast call "$access_manager" "hasRole(uint64,address)(bool,uint32)" "$rate_limiter_role" "${rl_holders[$i]}" --rpc-url "$fork_rpc" | head -n1 | awk '{print $1}')"
    [ "$member" != "true" ] || { echo "FAIL: ${rl_holders[$i]} already holds RATE_LIMITER_ROLE before execute" >&2; exit 1; }
  done
}

# Assert EVERY folded grant landed: each escrow's setRateLimit is wired to RATE_LIMITER and each holder holds it.
assert_rate_limiter_grant_landed() {
  local i got_role member
  for i in $(seq 0 $(( ${#rl_escrows[@]} - 1 )) ); do
    got_role="$(cast call "$access_manager" "getTargetFunctionRole(address,bytes4)(uint64)" "${rl_escrows[$i]}" "$rate_limit_set_sel" --rpc-url "$fork_rpc" | awk '{print $1}')"
    [ "$got_role" = "$rate_limiter_role" ] || { echo "FAIL: escrow ${rl_escrows[$i]} setRateLimit role=$got_role, expected $rate_limiter_role" >&2; exit 1; }
    member="$(cast call "$access_manager" "hasRole(uint64,address)(bool,uint32)" "$rate_limiter_role" "${rl_holders[$i]}" --rpc-url "$fork_rpc" | head -n1 | awk '{print $1}')"
    [ "$member" = "true" ] || { echo "FAIL: hasRole(RATE_LIMITER, ${rl_holders[$i]})=$member" >&2; exit 1; }
  done
  echo "    ok: all ${#rl_escrows[@]} folded grants landed (setTargetFunctionRole + grantRole)"
}

# Execute the entire v3 upgrade as ONE atomic Safe MultiSend transaction, driven through the REAL Safe via
# execTransaction. No private keys are needed on a fork: each of the first `threshold` owners pre-approves the
# tx hash on-chain (approveHash), and a prevalidated-signature (v=1) blob authorises the call.
execute_atomic() {
  # 1. Single source of truth: the recipe builds the MultiSend(bytes) calldata, target, and operation.
  build_client_id_args
  local ms_out
  if ! ms_out="$(just execute-v3-upgrade-multisend "" ${_ms_ids[@]+"${_ms_ids[@]}"})"; then
    echo "recipe failed: just execute-v3-upgrade-multisend" >&2
    printf '%s\n' "${ms_out:-}" >&2
    exit 1
  fi

  local to data operation
  to="$(recipe_field "$ms_out" "multisend to")" || {
    echo "could not parse 'multisend to:' from execute-v3-upgrade-multisend output" >&2
    printf '%s\n' "$ms_out" >&2
    exit 1
  }
  data="$(recipe_field "$ms_out" "multisend data")" || {
    echo "could not parse 'multisend data:' from execute-v3-upgrade-multisend output" >&2
    printf '%s\n' "$ms_out" >&2
    exit 1
  }
  operation="$(recipe_field "$ms_out" "multisend operation")" || {
    echo "could not parse 'multisend operation:' from execute-v3-upgrade-multisend output" >&2
    printf '%s\n' "$ms_out" >&2
    exit 1
  }
  if [ "$operation" != "1" ]; then
    echo "expected MultiSend operation=1 (DelegateCall) but recipe reported '$operation'" >&2
    exit 1
  fi
  echo "    multisend to:        $to"
  echo "    multisend operation: $operation (DelegateCall)"

  # 2. The canonical MultiSendCallOnly must already be deployed on the fork (mainnet/Sepolia have it).
  local ms_code
  ms_code="$(cast code "$to" --rpc-url "$fork_rpc")"
  if [ -z "$ms_code" ] || [ "$ms_code" = "0x" ]; then
    echo "no contract code at MultiSendCallOnly address $to on the fork." >&2
    echo "The canonical MultiSendCallOnly (0x9641d764fc13c8B624c04430C7356C1C7C8102e2) should be present on a" >&2
    echo "mainnet/Sepolia fork; set MULTISEND_CALL_ONLY if your fork uses a different address." >&2
    exit 1
  fi

  # 3. Read the Safe owner set + threshold and compute the tx hash on-chain (operation=1/DelegateCall).
  local threshold nonce tx_hash owners
  threshold="$(cast call "$safe" "getThreshold()(uint256)" --rpc-url "$fork_rpc" | awk '{print $1}')"
  nonce="$(cast call "$safe" "nonce()(uint256)" --rpc-url "$fork_rpc" | awk '{print $1}')"
  tx_hash="$(cast call "$safe" \
    "getTransactionHash(address,uint256,bytes,uint8,uint256,uint256,uint256,address,address,uint256)(bytes32)" \
    "$to" 0 "$data" 1 0 0 0 "$zero_addr" "$zero_addr" "$nonce" --rpc-url "$fork_rpc")"
  echo "    safe threshold:      $threshold"
  echo "    safe nonce:          $nonce"
  echo "    safe tx hash:        $tx_hash"

  # Cross-check the recipe's signer-facing safeTxHash (the value humans verify in the Safe UI) against the
  # hash the Safe itself computes here. A defect in the recipe's hashing would otherwise only surface in
  # production; assert they agree so the rehearsal covers the exact artifact signers approve.
  local recipe_tx_hash
  recipe_tx_hash="$(recipe_field "$ms_out" "multisend safeTxHash")" || {
    echo "could not parse 'multisend safeTxHash:' from execute-v3-upgrade-multisend output" >&2
    printf '%s\n' "$ms_out" >&2
    exit 1
  }
  if [ "$(printf '%s' "$recipe_tx_hash" | tr 'A-Z' 'a-z')" != "$(printf '%s' "$tx_hash" | tr 'A-Z' 'a-z')" ]; then
    echo "recipe safeTxHash ($recipe_tx_hash) does not match the Safe's on-chain getTransactionHash ($tx_hash);" >&2
    echo "the signer-facing hash and the hash actually executed disagree -- aborting." >&2
    exit 1
  fi
  echo "    recipe safeTxHash:   $recipe_tx_hash (matches on-chain)"

  # getOwners() prints "[0xAaa, 0xBbb]"; normalise to one lowercase 0x-address per line.
  owners="$(cast call "$safe" "getOwners()(address[])" --rpc-url "$fork_rpc" \
    | tr -d '[]' | tr ',' '\n' | tr -d ' ' | tr 'A-Z' 'a-z' | grep -E '^0x[0-9a-f]{40}$')"

  # 4. The first `threshold` owners pre-approve the hash on-chain (fork is --auto-impersonate).
  local approvers=()
  local count=0
  while IFS= read -r owner; do
    [ -n "$owner" ] || continue
    [ "$count" -ge "$threshold" ] && break
    cast rpc --rpc-url "$fork_rpc" anvil_setBalance "$owner" "$balance" >/dev/null
    echo "    approveHash by owner $owner"
    if ! cast send "$safe" "approveHash(bytes32)" "$tx_hash" --from "$owner" --unlocked --rpc-url "$fork_rpc" >/dev/null; then
      echo "FAILED: approveHash by $owner" >&2
      exit 1
    fi
    approvers+=("$owner")
    count=$((count + 1))
  done <<< "$owners"

  if [ "$count" -lt "$threshold" ]; then
    echo "Safe has fewer owners ($count) than its threshold ($threshold); cannot assemble signatures." >&2
    exit 1
  fi

  # 5. Build the prevalidated-signature blob: per approver a 65-byte sig of r=owner (left-padded), s=0, v=1.
  #    Safe's checkNSignatures requires owners strictly ascending, so sort the approvers by address.
  local zeros="0000000000000000000000000000000000000000000000000000000000000000"
  local sigs="0x"
  local exec_sender=""
  while IFS= read -r owner; do
    [ -n "$owner" ] || continue
    local r
    r="$(cast abi-encode "f(address)" "$owner")"   # 0x + 32-byte left-padded owner address
    r="${r#0x}"
    sigs="${sigs}${r}${zeros}01"
    [ -z "$exec_sender" ] && exec_sender="$owner"
  done < <(printf '%s\n' "${approvers[@]}" | sort)

  # 6. Submit the single atomic execTransaction through the real Safe; fail loudly on revert.
  echo "    execTransaction (operation=1/DelegateCall) from $exec_sender"
  local receipt
  if ! receipt="$(cast send "$safe" \
      "execTransaction(address,uint256,bytes,uint8,uint256,uint256,uint256,address,address,bytes)" \
      "$to" 0 "$data" 1 0 0 0 "$zero_addr" "$zero_addr" "$sigs" \
      --from "$exec_sender" --unlocked --rpc-url "$fork_rpc" --json)"; then
    echo "FAILED: atomic Safe MultiSend execTransaction reverted" >&2
    exit 1
  fi
  echo "    ok: v3 upgrade executed atomically via Safe MultiSend"
  # Bundle-gas measurement (F9): record the atomic execute's gas against the block limit so a mainnet
  # 8-sub-call bundle is known to fit. execTransaction status==1 here also proves the inner call did not
  # silently fail (which it could only do with a non-zero safeTxGas under-estimate -- we pass 0).
  local gas_used block_limit status
  gas_used="$(jq -r '.gasUsed // empty' <<<"$receipt")"; gas_used="$(cast to-dec "$gas_used" 2>/dev/null || echo "$gas_used")"
  status="$(jq -r '.status // empty' <<<"$receipt")"
  block_limit="$(cast block latest --json --rpc-url "$fork_rpc" | jq -r '.gasLimit')"; block_limit="$(cast to-dec "$block_limit" 2>/dev/null || echo "$block_limit")"
  echo "    bundle gas used: ${gas_used:-?}  (block gas limit: ${block_limit:-?}, status: ${status:-?})"
  [ "$status" = "0x1" ] || [ "$status" = "1" ] || { echo "FAILED: execTransaction receipt status != success ($status)" >&2; exit 1; }
}

# Drive an arbitrary Safe transaction through the REAL Safe via execTransaction, authorised by on-chain
# approveHash from the first `threshold` owners + a prevalidated-signature (v=1) blob — no private keys, fork
# only. Same signature machinery as execute_atomic, but generic over (safe,to,value,data,operation) so it can
# also drive the 2-of-5 customizer-Safe `addIBCApp` CALL. execute_atomic keeps its own inline copy unchanged
# (it is the proven atomic-execute path); this is purely additive.
safe_exec_tx() {
  local sx_safe="$1" sx_to="$2" sx_value="$3" sx_data="$4" sx_operation="$5" sx_label="$6"
  local threshold nonce tx_hash owners
  threshold="$(cast call "$sx_safe" "getThreshold()(uint256)" --rpc-url "$fork_rpc" | awk '{print $1}')"
  nonce="$(cast call "$sx_safe" "nonce()(uint256)" --rpc-url "$fork_rpc" | awk '{print $1}')"
  tx_hash="$(cast call "$sx_safe" \
    "getTransactionHash(address,uint256,bytes,uint8,uint256,uint256,uint256,address,address,uint256)(bytes32)" \
    "$sx_to" "$sx_value" "$sx_data" "$sx_operation" 0 0 0 "$zero_addr" "$zero_addr" "$nonce" --rpc-url "$fork_rpc")"
  echo "    $sx_label: safe $sx_safe (threshold $threshold, nonce $nonce)"
  echo "    safe tx hash:        $tx_hash"
  owners="$(cast call "$sx_safe" "getOwners()(address[])" --rpc-url "$fork_rpc" \
    | tr -d '[]' | tr ',' '\n' | tr -d ' ' | tr 'A-Z' 'a-z' | grep -E '^0x[0-9a-f]{40}$')"
  local approvers=() count=0 owner
  while IFS= read -r owner; do
    [ -n "$owner" ] || continue
    [ "$count" -ge "$threshold" ] && break
    cast rpc --rpc-url "$fork_rpc" anvil_setBalance "$owner" "$balance" >/dev/null
    echo "    approveHash by owner $owner"
    if ! cast send "$sx_safe" "approveHash(bytes32)" "$tx_hash" --from "$owner" --unlocked --rpc-url "$fork_rpc" >/dev/null; then
      echo "FAILED: approveHash by $owner ($sx_label)" >&2; exit 1
    fi
    approvers+=("$owner"); count=$((count + 1))
  done <<< "$owners"
  [ "$count" -ge "$threshold" ] || { echo "Safe $sx_safe has fewer owners ($count) than threshold ($threshold)" >&2; exit 1; }
  # checkNSignatures wants owners strictly ascending → sort approvers; per-approver prevalidated sig r=owner, s=0, v=1.
  local zeros="0000000000000000000000000000000000000000000000000000000000000000"
  local sigs="0x" exec_sender="" r
  while IFS= read -r owner; do
    [ -n "$owner" ] || continue
    r="$(cast abi-encode "f(address)" "$owner")"; r="${r#0x}"
    sigs="${sigs}${r}${zeros}01"
    [ -z "$exec_sender" ] && exec_sender="$owner"
  done < <(printf '%s\n' "${approvers[@]}" | sort)
  echo "    execTransaction ($sx_label, operation=$sx_operation) from $exec_sender"
  if ! cast send "$sx_safe" \
      "execTransaction(address,uint256,bytes,uint8,uint256,uint256,uint256,address,address,bytes)" \
      "$sx_to" "$sx_value" "$sx_data" "$sx_operation" 0 0 0 "$zero_addr" "$zero_addr" "$sigs" \
      --from "$exec_sender" --unlocked --rpc-url "$fork_rpc" >/dev/null; then
    echo "FAILED: execTransaction reverted ($sx_label)" >&2; exit 1
  fi
  echo "    ok: $sx_label executed via Safe execTransaction"
}

# Register ICS27GMP via the customizer's REAL authority path. addIBCApp is gated by ID_CUSTOMIZER_ROLE; on
# mainnet that holder (0x4b46ea82…) is a 2-of-5 Safe, so the production path is a Safe execTransaction CALL —
# NOT the forge single-sender broadcast (`register-ics27-gmp`), which cannot be used as-is. So: if the customizer
# has code (a Safe), drive the real 2-of-5 execTransaction; if it's an EOA (testnet Ledger), keep the
# impersonated single-sender broadcast. This makes the rehearsal cover the exact mainnet step-8 multisig path.
register_ics27() {
  local ics26 ics27 port="gmpport" data got code
  ics26="$(jq -re '.ics26Router.proxy' "$shadow_file")"
  ics27="$(jq -re '.ics27Gmp.proxy' "$shadow_file")"
  [ -n "$ics27" ] && [ "$ics27" != "$zero_addr" ] || { echo "no .ics27Gmp.proxy in $shadow_file" >&2; exit 1; }
  data="$(cast calldata 'addIBCApp(string,address)' "$port" "$ics27")"
  code="$(cast code "$id_customizer" --rpc-url "$fork_rpc")"
  if [ -n "$code" ] && [ "$code" != "0x" ]; then
    echo "    customizer $id_customizer is a Safe → driving addIBCApp via the REAL execTransaction (CALL)"
    safe_exec_tx "$id_customizer" "$ics26" 0 "$data" 0 "register ICS27GMP (addIBCApp, 2-of-N Safe CALL)"
  else
    echo "    customizer $id_customizer is an EOA → single-sender broadcast"
    forge script script/RegisterICS27GMP.sol:RegisterICS27GMP \
      --rpc-url "$fork_rpc" --broadcast --unlocked --sender "$id_customizer" -vvv
    # RegisterICS27GMP broadcasts to a tracked path; restore it to its committed state (fork-only data).
    git checkout -q -- broadcast/RegisterICS27GMP.sol 2>/dev/null || true
    git clean -fdq broadcast/RegisterICS27GMP.sol 2>/dev/null || true
  fi
  # Assert the registration landed (clearer signal than the later VerifyDeployment revert).
  got="$(cast call "$ics26" "getIBCApp(string)(address)" "$port" --rpc-url "$fork_rpc")"
  [ "$(printf '%s' "$got" | tr 'A-Z' 'a-z')" = "$(printf '%s' "$ics27" | tr 'A-Z' 'a-z')" ] \
    || { echo "FAIL: getIBCApp($port)=$got, expected $ics27 — addIBCApp did not land" >&2; exit 1; }
  echo "    ok: getIBCApp($port) == $ics27"
}

# ---------------------------------------------------------------------------
# 2. Schedule every timelocked operation.
# ---------------------------------------------------------------------------
echo "==> Scheduling timelock operations"
# Capture each recipe's calldata into a variable BEFORE calling submit. A standalone assignment makes a recipe
# failure trip `set -e`; `submit "$(recipe_calldata ...)"` would not -- the $(...) exit status is discarded in an
# argument list, so a failed recipe would expand to empty and submit a no-op to the timelock, silently skipping
# a step (the later atomic execute then reverts with a misleading root cause).
data="$(recipe_calldata schedule-v3-ics20transfer-upgrade-params)"
submit "$data" "schedule ICS20Transfer upgrade"
data="$(recipe_calldata schedule-v3-ics26router-upgrade-params)"
submit "$data" "schedule ICS26Router upgrade (predecessor=ICS20)"
data="$(recipe_calldata schedule-escrow-upgrade-params)"
submit "$data" "schedule Escrow beacon upgrade"
data="$(recipe_calldata schedule-ibcerc20-upgrade-params)"
submit "$data" "schedule IBCERC20 beacon upgrade"
while IFS= read -r cid; do
  data="$(recipe_calldata schedule-v3-light-client-migration-params "$cid")"
  submit "$data" "schedule migration $cid"
done < <(sp1_ids)

# Optionally schedule a representative rate-limiter role grant to rehearse the EXTRA_TIMELOCK_OPS folding path.
# Captured into a variable first (capture-then-submit), exactly like the upgrade schedules above.
if [ "$rehearse_rl_grant" = "1" ]; then
  prepare_rate_limiter_grant
  for _i in $(seq 0 $(( ${#rl_schedules[@]} - 1 )) ); do
    submit "${rl_schedules[$_i]}" "schedule rate-limiter grant #$((_i + 1))"
  done
  # Prove none are in effect yet so the post-execute assertion actually proves the fold did the work.
  assert_rate_limiter_grant_absent
fi

# ---------------------------------------------------------------------------
# 3. Wait out the timelock delay.
# ---------------------------------------------------------------------------
min_delay="$(cast call "$timelock" "getMinDelay()(uint256)" --rpc-url "$fork_rpc" | awk '{print $1}')"
echo "==> Advancing fork time past min delay ($min_delay s)"
cast rpc --rpc-url "$fork_rpc" evm_increaseTime "$((min_delay + 5))" >/dev/null
cast rpc --rpc-url "$fork_rpc" evm_mine >/dev/null

# ---------------------------------------------------------------------------
# 4. Prove the ordering guard, then execute in the correct order.
# ---------------------------------------------------------------------------
echo "==> Asserting ICS26Router upgrade cannot execute before ICS20Transfer upgrade"
data="$(recipe_calldata execute-v3-ics26router-upgrade-params)"
submit_expect_revert "$data" "execute ICS26Router before ICS20Transfer"

# The whole upgrade runs as ONE atomic Safe MultiSend execTransaction through the real Safe.
# When rehearsing the fold, hand the grant's execute to the recipe as a raw 0x op via EXTRA_TIMELOCK_OPS -- the
# exact production mechanism: execute-v3-upgrade-multisend appends it, the packer validates the 0x134008d3
# execute selector, and execute_atomic's safeTxHash cross-check then covers the folded bundle too.
if [ "$rehearse_rl_grant" = "1" ]; then
  echo "==> Folding ${#rl_executes[@]} rate-limiter grant execute(s) into the atomic Safe MultiSend via EXTRA_TIMELOCK_OPS"
  export EXTRA_TIMELOCK_OPS="$rl_extra_ops"
fi
echo "==> Executing the v3 upgrade atomically via a single Safe MultiSend execTransaction"
execute_atomic

if [ "$rehearse_rl_grant" = "1" ]; then
  echo "==> Asserting the folded rate-limiter grant landed on-chain"
  assert_rate_limiter_grant_landed
fi

# ---------------------------------------------------------------------------
# 5. Register ICS27 (ID customizer), initialize escrows (permissionless), verify.
# ---------------------------------------------------------------------------
echo "==> Registering ICS27GMP (as ID customizer $id_customizer)"
# On a mainnet fork the customizer is a 2-of-5 Safe → this drives the REAL execTransaction CALL (production
# step 8); on a testnet fork it's an EOA → impersonated single-sender broadcast. See register_ics27.
register_ics27

echo "==> Initializing known escrows"
while IFS= read -r cid; do
  [ -n "$cid" ] || continue
  escrow="$(cast call "$ics20_proxy" "getEscrow(string)(address)" "$cid" --rpc-url "$fork_rpc")"
  if [ "$escrow" = "0x0000000000000000000000000000000000000000" ]; then
    continue
  fi
  echo "    initializeV2 escrow for $cid: $escrow"
  cast send "$escrow" "initializeV2()" --from "$deployer" --unlocked --rpc-url "$fork_rpc" >/dev/null
done < <(jq -r '.light_clients[]?.clientId // empty' "$shadow_file")

echo "==> Verifying upgraded shadow deployment"
forge script script/VerifyDeployment.sol:VerifyDeployment --rpc-url "$fork_rpc" -vvv

echo
echo "Timelock rehearsal succeeded against $shadow_file"
