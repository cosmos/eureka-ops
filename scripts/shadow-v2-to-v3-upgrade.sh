#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: scripts/shadow-v2-to-v3-upgrade.sh <chain-id> <source-env> <shadow-env> <fork-rpc>

Runs the v2-to-v3 upgrade sequence against an already-running Anvil shadow fork.
The shadow environment must start with "shadow-" so real deployment files are not overwritten.
USAGE
}

if [ "$#" -ne 4 ]; then
  usage
  exit 1
fi

chain_id="$1"
source_env="$2"
shadow_env="$3"
fork_rpc="$4"

export ETH_RPC="$fork_rpc"
export FOUNDRY_ETH_RPC_URL="$fork_rpc"

if [[ "$shadow_env" != shadow-* ]]; then
  echo "shadow-env must start with 'shadow-' (got '$shadow_env')" >&2
  exit 1
fi

root="$(git rev-parse --show-toplevel)"
source_file="$root/deployments/$source_env/$chain_id.json"
shadow_dir="$root/deployments/$shadow_env"
shadow_file="$shadow_dir/$chain_id.json"

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

admin="$(jq -re '(.accessManagerRoles.admin // .ics26Router.timelockAdmin)' "$shadow_file")"
deployer="${SHADOW_FORK_DEPLOYER:-0xf39fd6e51aad88f6f4ce6ab8827279cfffb92266}"
balance="${SHADOW_FORK_BALANCE_WEI:-0x56BC75E2D63100000}"

cast rpc --rpc-url "$fork_rpc" anvil_setBalance "$deployer" "$balance" >/dev/null
cast rpc --rpc-url "$fork_rpc" anvil_setBalance "$admin" "$balance" >/dev/null

(
  cd "$root"
  export DEPLOYMENT_ENV="$shadow_env"
  export EUREKA_ENVIRONMENT="$shadow_env"
  export EUREKA_CHAIN="$chain_id"
  export ETH_RPC="$fork_rpc"
  export FOUNDRY_ETH_RPC_URL="$fork_rpc"

  forge script script/ShadowForkV2ToV3Upgrade.sol:ShadowForkV2ToV3Upgrade \
    --rpc-url "$fork_rpc" \
    --broadcast \
    --unlocked \
    --sender "$deployer" \
    -vvvv
)

echo
echo "Shadow deployment updated at: $shadow_file"
