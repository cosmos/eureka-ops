#!/usr/bin/env python3
"""Discover every live v2 role holder and reconcile against the v3 migration JSON.

Pre-cutover counterpart to validate-v3-roles.py. The v2 contracts use per-contract
OZ AccessControl (non-enumerable), so the only ground truth for "who can do what" is
the RoleGranted/RoleRevoked event history. This tool, for each live v2 contract
(ICS26Router, ICS20Transfer, each Escrow):

  1. self-discovers the named role hashes by calling the role-constant getters,
  2. pulls the full RoleGranted/RoleRevoked history (Etherscan logs API),
  3. reconstructs the CURRENT holder set per role and confirms each with hasRole,
  4. maps each v2 role to its v3 role + deployment-JSON key, and reconciles:
       - v2 holder NOT in the JSON  -> WOULD BE DROPPED by the migration (action needed)
       - JSON entry not a live v2 holder -> granted anyway (intended addition?)
       - RATE_LIMITER -> not auto-migrated; must be re-granted (runbook step 10)
       - TOKEN_OPERATOR / unidentified roles -> no v3 equivalent (confirm intended)

It changes nothing on chain. Run it before the mainnet round to build/triage the
exact grant set.

Usage:
    ETH_RPC=<rpc> ETHERSCAN_API_KEY=<key> python3 scripts/discover-v2-roles.py [env=mainnet] [chain=1]
"""
import json, os, subprocess, sys, urllib.request, urllib.parse

ENV   = sys.argv[1] if len(sys.argv) > 1 else "mainnet"
CHAIN = sys.argv[2] if len(sys.argv) > 2 else "1"
RPC   = os.environ.get("ETH_RPC") or os.environ.get("FOUNDRY_ETH_RPC_URL")
KEY   = os.environ.get("ETHERSCAN_API_KEY")
if not RPC: sys.exit("set ETH_RPC")
if not KEY: sys.exit("set ETHERSCAN_API_KEY")

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DEPLOY = json.load(open(f"{ROOT}/deployments/{ENV}/{CHAIN}.json"))
ICS26 = DEPLOY["ics26Router"]["proxy"]
ICS20 = DEPLOY["ics20Transfer"]["proxy"]
ROLES = DEPLOY["accessManagerRoles"]

RG = "0x2f8788117e7eff1d82e926ec794901d17c78024a50270940304540a733656f0d"  # RoleGranted(bytes32,address,address)
RR = "0xf6391f5c32d9c69d2a47ea670b442974b53935d1edc7fd64eb21e047a839171b"  # RoleRevoked(bytes32,address,address)

# v2 role name -> (v3 role id or None, deployment-JSON key or None, note)
ROLE_MAP = {
    "DEFAULT_ADMIN_ROLE":       (0,    "admin",            "v3 admin = TimelockController (not migrated as holders)"),
    "RELAYER_ROLE":             (1,    "relayers",         ""),
    "PAUSER_ROLE":              (2,    "pausers",          ""),
    "UNPAUSER_ROLE":            (3,    "unpausers",        ""),
    "DELEGATE_SENDER_ROLE":     (4,    "delegateSenders",  ""),
    "RATE_LIMITER_ROLE":        (5,    None,               "NOT in JSON; re-grant via runbook step 10"),
    "PORT_CUSTOMIZER_ROLE":     (6,    "idCustomizers",    "merged into v3 ID_CUSTOMIZER"),
    "CLIENT_ID_CUSTOMIZER_ROLE":(6,    "idCustomizers",    "merged into v3 ID_CUSTOMIZER"),
    "ERC20_CUSTOMIZER_ROLE":    (7,    "erc20Customizers", ""),
    "TOKEN_OPERATOR_ROLE":      (None, None,               "NO v3 equivalent — capability dropped"),
    "LIGHT_CLIENT_MIGRATOR_ROLE":(None,None,               "NO v3 role — migrateClient is ADMIN-gated in v3"),
}
CANDIDATES = list(ROLE_MAP) + ["ID_CUSTOMIZER_ROLE"]

def cast(*a):
    return subprocess.run(["cast", *a, "--rpc-url", RPC], capture_output=True, text=True).stdout.strip()

def etherscan_logs(addr, topic0, topic1=None):
    out, page = [], 1
    while True:
        params = {"chainid": CHAIN, "module": "logs", "action": "getLogs",
            "address": addr, "topic0": topic0, "fromBlock": 0, "toBlock": "latest",
            "page": page, "offset": 1000, "apikey": KEY}
        if topic1:
            params["topic1"] = topic1; params["topic0_1_opr"] = "and"
        q = urllib.parse.urlencode(params)
        with urllib.request.urlopen(f"https://api.etherscan.io/v2/api?{q}", timeout=60) as r:
            d = json.load(r)
        res = d.get("result")
        if not isinstance(res, list) or not res: break
        out += res
        if len(res) < 1000: break
        page += 1
    return out

# per-client v2 roles are keccak(abi.encodePacked("LIGHT_CLIENT_MIGRATOR_ROLE_", clientId)), granted
# inside addClient/migrateClient. Label them by precomputing the hash for every derivable clientId
# (JSON clients + client-0..nextSeq), and fall back to decoding the grant tx's first string arg.
CLIENT_OP_SELS = {"0x1ec43e23": "addClient", "0xe3cb36a0": "addClient", "0xcce0b265": "migrateClient"}
def _keccak(s):
    return subprocess.run(["cast", "keccak", s], capture_output=True, text=True).stdout.strip().lower()
def _decode_first_string(inp):
    data = inp[10:]
    try:
        off = int(data[:64], 16) * 2
        slen = int(data[off:off+64], 16)
        return bytes.fromhex(data[off+64:off+64+slen*2]).decode()
    except Exception:
        return None
_seq = int(cast("call", ICS26, "getNextClientSeq()(uint256)") or "0")
_client_ids = [c["clientId"] for c in (DEPLOY.get("light_clients") or {}).values()] + [f"client-{i}" for i in range(_seq)]
MIGRATOR = {_keccak("LIGHT_CLIENT_MIGRATOR_ROLE_" + c): c for c in _client_ids}
def classify_unknown(addr, role_hash):
    if role_hash in MIGRATOR:
        return ("LIGHT_CLIENT_MIGRATOR_ROLE", MIGRATOR[role_hash])
    lg = etherscan_logs(addr, RG, role_hash)
    if not lg:
        return (None, None)
    inp = cast("tx", lg[0]["transactionHash"], "input")
    if inp[:10] in CLIENT_OP_SELS:
        cid = "auto-id" if inp[:10] == "0xe3cb36a0" else _decode_first_string(inp)
        return ("LIGHT_CLIENT_MIGRATOR_ROLE", cid or "?")
    return (None, None)

def discover_named_roles(addr):
    """hash -> name, by calling each candidate role-constant getter on the contract."""
    m = {"0x" + "00"*32: "DEFAULT_ADMIN_ROLE"}
    for name in CANDIDATES:
        h = cast("call", addr, f"{name}()(bytes32)")
        if h and h.startswith("0x") and len(h) == 66:
            m[h.lower()] = name
    return m

def current_holders(addr):
    """role hash -> set(current holders), reconstructed from grant/revoke events."""
    ev = []
    for lg in etherscan_logs(addr, RG):
        ev.append((int(lg["blockNumber"],16), int(lg["logIndex"],16), "g",
                   lg["topics"][1].lower(), "0x"+lg["topics"][2][-40:].lower()))
    for lg in etherscan_logs(addr, RR):
        ev.append((int(lg["blockNumber"],16), int(lg["logIndex"],16), "r",
                   lg["topics"][1].lower(), "0x"+lg["topics"][2][-40:].lower()))
    ev.sort()
    m = {}
    for _b,_i,kind,role,acct in ev:
        m.setdefault(role, set())
        m[role].add(acct) if kind == "g" else m[role].discard(acct)
    return m

def has_role(addr, role_hash, acct):
    return cast("call", addr, "hasRole(bytes32,address)(bool)", role_hash, acct) == "true"

# aggregate v2 holders by JSON key (idCustomizers gets PORT_ + CLIENT_ID_)
agg = {}        # json_key -> set(holders)
rate_limiters = {}   # escrow label -> set
dropped = []         # (contract, role name/hash, holders)
unknown = []         # (contract, role hash, holders)

CONTRACTS = [("ICS26Router", ICS26), ("ICS20Transfer", ICS20)]
escrows = {}
for cid in (DEPLOY.get("light_clients") or {}).values():
    e = cast("call", ICS20, "getEscrow(string)(address)", cid["clientId"])
    if e and int(e,16) != 0:
        escrows[cid["clientId"]] = e
        CONTRACTS.append((f"escrow:{cid['clientId']}", e))

print(f"Discovering live v2 roles on {ENV}/{CHAIN} ...\n")
for label, addr in CONTRACTS:
    names = discover_named_roles(addr)
    holders = current_holders(addr)
    print(f"=== {label}  {addr} ===")
    if not holders:
        print("  (no role events)"); continue
    for role_hash, accts in sorted(holders.items()):
        accts = {a for a in accts if has_role(addr, role_hash, a)}   # confirm on-chain
        if not accts: continue
        name = names.get(role_hash)
        if name is None:
            kind, cid = classify_unknown(addr, role_hash)
            if kind == "LIGHT_CLIENT_MIGRATOR_ROLE":
                print(f"  {kind} (clientId {cid!r})  v3=NONE  holders={sorted(accts)}  [per-client; migrateClient is ADMIN-gated in v3]")
                dropped.append((label, f"{kind}[{cid}]", sorted(accts)))
            else:
                print(f"  ⚠ UNIDENTIFIED role {role_hash}  holders={sorted(accts)}")
                unknown.append((label, role_hash, sorted(accts)))
            continue
        v3, jkey, note = ROLE_MAP.get(name, (None, None, ""))
        tag = f"v3={v3}" if v3 is not None else "v3=NONE"
        print(f"  {name:<26} {tag:<8} holders={sorted(accts)}" + (f"  [{note}]" if note else ""))
        if name == "RATE_LIMITER_ROLE":
            rate_limiters[label] = accts
        elif name == "TOKEN_OPERATOR_ROLE" or v3 is None:
            dropped.append((label, name, sorted(accts)))
        elif jkey:
            agg.setdefault(jkey, set()).update(accts)
    print()

# ---- reconcile aggregated v2 holders vs the JSON ----
print("="*70)
print("RECONCILIATION  (live v2 holders  vs  deployments/%s/%s.json)\n" % (ENV, CHAIN))
issues = 0
for jkey in ["relayers","pausers","unpausers","delegateSenders","idCustomizers","erc20Customizers"]:
    v2 = agg.get(jkey, set())
    js = {a.lower() for a in ROLES.get(jkey, [])}
    miss = v2 - js      # live v2 holder absent from JSON -> dropped by migration
    extra = js - v2     # in JSON but not a live v2 holder
    if not miss and not extra:
        print(f"  OK    {jkey}: {len(js)} entr(y/ies) match live v2 holders")
    else:
        if miss:  print(f"  ‼ {jkey}: in v2 but MISSING from JSON (WILL BE DROPPED): {sorted(miss)}"); issues += 1
        if extra: print(f"  •  {jkey}: in JSON but not a live v2 holder (granted anyway): {sorted(extra)}")

print(f"\n  admin (DEFAULT_ADMIN_ROLE): JSON admin = {ROLES.get('admin')}  (v3 = timelock; v2 admins above are informational)")
if rate_limiters:
    print("\n  ‼ RATE_LIMITER_ROLE holders to RE-GRANT (runbook step 10 — not auto-migrated):")
    for lbl, accts in rate_limiters.items(): print(f"      {lbl}: {sorted(accts)}")
else:
    print("\n  RATE_LIMITER_ROLE: no live holders on any escrow (step 10 is a no-op)")
if dropped:
    print("\n  • v2 roles with NO v3 equivalent (capability dropped — confirm intended):")
    for lbl, name, accts in dropped: print(f"      {lbl} {name}: {sorted(accts)}")
if unknown:
    print("\n  ⚠ UNIDENTIFIED v2 role hashes still held (identify before cutover):")
    for lbl, h, accts in unknown: print(f"      {lbl} {h}: {sorted(accts)}")

print(f"\n{'='*70}\n{'REVIEW NEEDED' if (issues or unknown) else 'JSON matches live v2 holders for all migrated roles'}"
      f"  ({issues} mismatch group(s), {len(unknown)} unidentified role(s))")
