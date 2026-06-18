#!/usr/bin/env bash
set -euo pipefail

# Resolve the four SP1 ICS07 Tendermint program vkeys for a `sp1-programs-*` release by computing them from the
# PUBLISHED release ELF binaries — the exact artifacts the deployed prover loads (its entrypoint wget's them from
# the GitHub release into /usr/local/bin/sp1-programs/<version>/). A vkey is a deterministic function of the ELF
# bytes, so computing over the released ELFs yields exactly the vkeys the prover will use, without a running
# proof-api.
#
# IMPORTANT: this only ever uses the downloaded release binaries. It does NOT rebuild the programs locally and does
# NOT read the repo's committed test fixtures — both can produce different ELF bytes (hence different, wrong vkeys);
# for sp1-programs-v2.0.0-rc.2 the committed fixtures in fact differ from the published release.
#
# Usage:
#   scripts/sp1-vkeys.sh [--version <tag>] [--sibe <path>] [--write <env> <chain> <client_id>...]
#
# Env (used when the matching flag is omitted):
#   SP1_PROGRAMS_VERSION   sp1-programs release tag            (default: v2.0.0-rc.2)
#   SOLIDITY_IBC_EUREKA    path to a solidity-ibc-eureka clone (default: /tmp/solidity-ibc-eureka)
#
# Examples:
#   scripts/sp1-vkeys.sh
#   scripts/sp1-vkeys.sh --write testnet 11155111 hub-testnet-0 ledger-testnet-1
#
# Requires: gh (authenticated), jq, cargo + the SP1 toolchain used to build `operator`.

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
repo="cosmos/solidity-ibc-eureka"
version="${SP1_PROGRAMS_VERSION:-v2.0.0-rc.2}"
sibe="${SOLIDITY_IBC_EUREKA:-/tmp/solidity-ibc-eureka}"
write_env=""
write_chain=""
client_ids=()

while [ "$#" -gt 0 ]; do
  case "$1" in
    --version) version="${2:?--version needs a tag}"; shift 2 ;;
    --sibe) sibe="${2:?--sibe needs a path}"; shift 2 ;;
    --write)
      write_env="${2:?--write needs <env> <chain> <client_id>...}"
      write_chain="${3:?--write needs <env> <chain> <client_id>...}"
      shift 3
      while [ "$#" -gt 0 ]; do client_ids+=("$1"); shift; done
      ;;
    -h | --help) sed -n '3,24p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 1 ;;
  esac
done

command -v gh >/dev/null || { echo "gh not found (needed to download the release ELFs)" >&2; exit 1; }
command -v jq >/dev/null || { echo "jq not found" >&2; exit 1; }
command -v cargo >/dev/null || { echo "cargo not found (needed to compute vkeys from the ELFs)" >&2; exit 1; }
test -d "$sibe/programs/operator" || { echo "no solidity-ibc-eureka checkout at $sibe (set SOLIDITY_IBC_EUREKA or --sibe)" >&2; exit 1; }

# The git/GitHub release tag is `sp1-programs-<v>`; ibc-manifests labels the same set just `<v>`. Accept either.
case "$version" in
  sp1-programs-*) ;;
  *) version="sp1-programs-$version" ;;
esac

elfdir="$(mktemp -d)"
helper="$sibe/programs/operator/src/bin/eurekaops_print_vkeys.rs"
helper_created=0
# Only delete the injected helper if WE created it, so a stale or foreign file at that path is never removed.
cleanup() { rm -rf "$elfdir"; if [ "$helper_created" = 1 ]; then rm -f "$helper"; fi; }
trap cleanup EXIT

echo "==> Downloading sp1-programs $version ELFs from $repo" >&2
gh release download "$version" -R "$repo" --dir "$elfdir" --clobber \
  --pattern 'sp1-ics07-tendermint-update-client' \
  --pattern 'sp1-ics07-tendermint-membership' \
  --pattern 'sp1-ics07-tendermint-uc-and-membership' \
  --pattern 'sp1-ics07-tendermint-misbehaviour'

for f in update-client membership uc-and-membership misbehaviour; do
  test -s "$elfdir/sp1-ics07-tendermint-$f" || { echo "missing release ELF: sp1-ics07-tendermint-$f" >&2; exit 1; }
done

echo "==> Computing vkeys via the upstream prover crate (sp1_sdk mock setup over the released ELFs)" >&2
# Never clobber a pre-existing file at the helper path (a stale copy from a killed run, or any real file).
if [ -e "$helper" ]; then
  echo "refusing to overwrite existing file: $helper" >&2
  echo "(a previous sp1-vkeys run may have been killed before cleanup -- remove it and retry)" >&2
  exit 1
fi
cp "$root/scripts/sp1-vkeys/print_vkeys.rs" "$helper"
helper_created=1
vkeys_json="$(cd "$sibe" && cargo run --quiet --bin eurekaops_print_vkeys -- \
  "$elfdir/sp1-ics07-tendermint-update-client" \
  "$elfdir/sp1-ics07-tendermint-membership" \
  "$elfdir/sp1-ics07-tendermint-uc-and-membership" \
  "$elfdir/sp1-ics07-tendermint-misbehaviour")"

echo "$vkeys_json" | jq .

if [ -n "$write_env" ]; then
  file="$root/deployments/$write_env/$write_chain.json"
  test -f "$file" || { echo "deployment file not found: $file" >&2; exit 1; }
  [ "${#client_ids[@]}" -gt 0 ] || { echo "--write needs at least one client id" >&2; exit 1; }

  uc="$(jq -r .updateClientVkey <<<"$vkeys_json")"
  mem="$(jq -r .membershipVkey <<<"$vkeys_json")"
  ucm="$(jq -r .ucAndMembershipVkey <<<"$vkeys_json")"
  mis="$(jq -r .misbehaviourVkey <<<"$vkeys_json")"

  # Mainnet guard: the v6.1 vkeys for this upgrade are FIXED and KNOWN — validated on testnet and recorded in
  # the operation RECORD (sp1-programs v2.0.0, cut at the v2.0.0-rc.2 commit). Assert the computed set matches
  # the expected constants before writing to a mainnet (chain 1) deployment, so a wrong ELF/version/toolchain
  # can't silently write bad vkeys (every migrated client's proofs would then revert at cutover). An intentional
  # future mainnet vkey change must opt out with ALLOW_VKEY_MISMATCH=1.
  if [ "$write_chain" = "1" ]; then
    exp_uc="0x00d38536f65ab10e7eff0895b1b9f7cf12f89691631742bb487fe090027e0e6d"
    exp_mem="0x000bd8ec43ea65b85c87eb57ace44692c3292ff297e01f29542b9fb476ed3e4f"
    exp_ucm="0x009fe47dbd3934f92417fbe4f17e79fe89417d61a724f66fadbc361b475dc091"
    exp_mis="0x0010008da4267c2e85d02616e853379e3c937c03a271b5b005f479cff09ccfcb"
    mismatch=0
    [ "$(printf '%s' "$uc"  | tr 'A-Z' 'a-z')" = "$exp_uc"  ] || { echo "MAINNET VKEY MISMATCH updateClient:    got $uc  expected $exp_uc"  >&2; mismatch=1; }
    [ "$(printf '%s' "$mem" | tr 'A-Z' 'a-z')" = "$exp_mem" ] || { echo "MAINNET VKEY MISMATCH membership:      got $mem expected $exp_mem" >&2; mismatch=1; }
    [ "$(printf '%s' "$ucm" | tr 'A-Z' 'a-z')" = "$exp_ucm" ] || { echo "MAINNET VKEY MISMATCH ucAndMembership: got $ucm expected $exp_ucm" >&2; mismatch=1; }
    [ "$(printf '%s' "$mis" | tr 'A-Z' 'a-z')" = "$exp_mis" ] || { echo "MAINNET VKEY MISMATCH misbehaviour:    got $mis expected $exp_mis" >&2; mismatch=1; }
    if [ "$mismatch" = 1 ]; then
      echo "Refusing to write mainnet vkeys that don't match the validated v6.1 set (sp1-programs v2.0.0)." >&2
      echo "Check --version and the SP1 toolchain. Override only if this is an intentional change: ALLOW_VKEY_MISMATCH=1." >&2
      [ "${ALLOW_VKEY_MISMATCH:-}" = "1" ] || exit 1
    fi
  fi

  for cid in "${client_ids[@]}"; do
    tmp="$(mktemp)"
    jq --arg cid "$cid" --arg uc "$uc" --arg mem "$mem" --arg ucm "$ucm" --arg mis "$mis" '
      (.light_clients | to_entries | map(select(.value.clientId == $cid)) | .[0].key) as $k
      | if $k == null then error("client id not found in deployment: " + $cid) else . end
      | .light_clients[$k].updateClientVkey = $uc
      | .light_clients[$k].membershipVkey = $mem
      | .light_clients[$k].ucAndMembershipVkey = $ucm
      | .light_clients[$k].misbehaviourVkey = $mis
    ' "$file" >"$tmp" && mv "$tmp" "$file"
    echo "==> wrote $version vkeys for $cid into $file" >&2
  done
fi
