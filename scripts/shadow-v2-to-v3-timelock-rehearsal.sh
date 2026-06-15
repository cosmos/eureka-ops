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
#      registers ICS27, initializes escrows, and verifies.
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

usage() {
  sed -n '4,40p' "$0"
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
  if ! cast send "$safe" \
      "execTransaction(address,uint256,bytes,uint8,uint256,uint256,uint256,address,address,bytes)" \
      "$to" 0 "$data" 1 0 0 0 "$zero_addr" "$zero_addr" "$sigs" \
      --from "$exec_sender" --unlocked --rpc-url "$fork_rpc" >/dev/null; then
    echo "FAILED: atomic Safe MultiSend execTransaction reverted" >&2
    exit 1
  fi
  echo "    ok: v3 upgrade executed atomically via Safe MultiSend"
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
echo "==> Executing the v3 upgrade atomically via a single Safe MultiSend execTransaction"
execute_atomic

# ---------------------------------------------------------------------------
# 5. Register ICS27 (ID customizer), initialize escrows (permissionless), verify.
# ---------------------------------------------------------------------------
echo "==> Registering ICS27GMP (as ID customizer $id_customizer)"
forge script script/RegisterICS27GMP.sol:RegisterICS27GMP \
  --rpc-url "$fork_rpc" --broadcast --unlocked --sender "$id_customizer" -vvv
# RegisterICS27GMP broadcasts to a tracked path (.gitignore only excludes ShadowFork* broadcasts). On a fork this
# is fork-only data, so restore that path to its committed state rather than leaving fork addresses for `git add`.
git checkout -q -- broadcast/RegisterICS27GMP.sol 2>/dev/null || true
git clean -fdq broadcast/RegisterICS27GMP.sol 2>/dev/null || true

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
