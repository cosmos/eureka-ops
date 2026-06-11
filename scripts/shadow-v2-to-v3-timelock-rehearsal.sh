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
#      revert; transfer-then-router then succeeds.
#   5. Executes the beacon upgrades and SP1 migrations, registers ICS27, initializes escrows, and verifies.
#
# This validates the timelock schedule/execute/ordering and the recipe-generated calldata end-to-end on the real
# v2 contracts — the part the direct-broadcast rehearsal cannot cover.
#
# Requires an already-running Anvil fork of the (still-v2) chain, started with --auto-impersonate, e.g.
#   just shadow-start-sepolia
#
# Usage: SAFE_ADDRESS=0x... [SP1_CLIENT_IDS=a,b,c] scripts/shadow-v2-to-v3-timelock-rehearsal.sh \
#          <chain-id> <source-env> <shadow-env> <fork-rpc>
#
# Env:
#   SAFE_ADDRESS                 (required) the Safe that holds PROPOSER/EXECUTOR on the timelock; impersonated.
#   SP1_CLIENT_IDS               (optional) comma-separated client ids to also deploy + migrate.
#   SHADOW_FORK_PRESERVE_DEPLOYMENT=1   reuse an already-prepared shadow JSON instead of copying the source.
#   SHADOW_FORK_DEPLOYER         (optional) funded EOA used to broadcast deploys (default: anvil account 0).
#   SHADOW_FORK_BALANCE_WEI      (optional) balance set on impersonated accounts (default: 100 ether).

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

if [ -z "${SAFE_ADDRESS:-}" ]; then
  echo "SAFE_ADDRESS must be set to the Safe that holds PROPOSER/EXECUTOR on the timelock." >&2
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
safe="$SAFE_ADDRESS"

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
  echo "    submit: $label"
  if ! cast send "$timelock" --data "$data" --from "$safe" --unlocked --rpc-url "$fork_rpc" >/dev/null; then
    echo "FAILED to submit: $label" >&2
    exit 1
  fi
}

# Submit timelock calldata expected to revert (used for the ordering assertion).
submit_expect_revert() {
  local data="$1" label="$2"
  if cast send "$timelock" --data "$data" --from "$safe" --unlocked --rpc-url "$fork_rpc" >/dev/null 2>&1; then
    echo "FAIL: $label was expected to revert (predecessor not met) but succeeded" >&2
    exit 1
  fi
  echo "    ok: $label reverted as expected — timelock ordering is enforced"
}

# Iterate SP1 client ids (comma-separated), bash-3.2 safe.
sp1_ids() {
  local IFS=','
  read -ra _ids <<< "$sp1_client_ids"
  for _id in ${_ids[@]+"${_ids[@]}"}; do
    [ -n "$_id" ] && printf '%s\n' "$_id"
  done
}

# ---------------------------------------------------------------------------
# 2. Schedule every timelocked operation.
# ---------------------------------------------------------------------------
echo "==> Scheduling timelock operations"
submit "$(recipe_calldata schedule-v3-ics20transfer-upgrade-params)" "schedule ICS20Transfer upgrade"
submit "$(recipe_calldata schedule-v3-ics26router-upgrade-params)" "schedule ICS26Router upgrade (predecessor=ICS20)"
submit "$(recipe_calldata schedule-escrow-upgrade-params)" "schedule Escrow beacon upgrade"
submit "$(recipe_calldata schedule-ibcerc20-upgrade-params)" "schedule IBCERC20 beacon upgrade"
while IFS= read -r cid; do
  submit "$(recipe_calldata schedule-v3-light-client-migration-params "$cid")" "schedule migration $cid"
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
submit_expect_revert "$(recipe_calldata execute-v3-ics26router-upgrade-params)" "execute ICS26Router before ICS20Transfer"

echo "==> Executing upgrades in order"
submit "$(recipe_calldata execute-v3-ics20transfer-upgrade-params)" "execute ICS20Transfer upgrade"
submit "$(recipe_calldata execute-v3-ics26router-upgrade-params)" "execute ICS26Router upgrade"
submit "$(recipe_calldata execute-escrow-upgrade-params)" "execute Escrow beacon upgrade"
submit "$(recipe_calldata execute-ibcerc20-upgrade-params)" "execute IBCERC20 beacon upgrade"
while IFS= read -r cid; do
  submit "$(recipe_calldata execute-v3-light-client-migration-params "$cid")" "execute migration $cid"
done < <(sp1_ids)

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
