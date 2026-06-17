#!/usr/bin/env python3
"""Independent on-chain validation of the v3 AccessManager role wiring.

Reads everything it asserts from the deployment JSON + chain state — it trusts no
deploy-time broadcast artifact — so it is a faithful post-upgrade (and pre-mainnet
dry-run) check that the migration landed every role exactly as configured.

It verifies four things:

  A. Target function roles  — every protocol (target, selector) is gated by the role
     the contracts expect. The (target, selector)->role TABLE below is a hand-encoded
     4-byte-selector constant, manually verified against IBCRolesLib + the v3 deploy
     wiring (DeployAccessManagerWithRoles + the local script/helpers/V3UpgradeSelectors.sol
     backfill for migrateClient/upgradeAccountTo) for v3.0.1 — re-check it on a version bump.
  B. Role membership        — reconstructed from RoleGranted/RoleRevoked events, so it
     catches BOTH missing configured holders AND unexpected/stray holders (e.g. a
     bootstrap that failed to renounce ADMIN), and confirms every holder's execution
     delay is 0. Expected membership is read from `.accessManagerRoles` in the JSON.
  C. authority() wiring     — the proxies and every known escrow point authority() at
     the AccessManager.
  D. RATE_LIMITER note      — reports whether each escrow's setRateLimit is wired to
     RATE_LIMITER yet (upstream TODO #559: it is only wired by the grant recipe).

Usage:
    ETH_RPC=<rpc> python3 scripts/validate-v3-roles.py [env=testnet] [chain=11155111]

Env:
    ETH_RPC     required RPC url (falls back to the .eureka-env value if exported)
    FROM_BLOCK  event scan start block; auto-read from the AccessManager deploy
                broadcast if present, else 0 (override for non-default deploys).
"""
import json, os, subprocess, sys

ENV   = sys.argv[1] if len(sys.argv) > 1 else "testnet"
CHAIN = sys.argv[2] if len(sys.argv) > 2 else "11155111"
RPC   = os.environ.get("ETH_RPC") or os.environ.get("FOUNDRY_ETH_RPC_URL")
if not RPC:
    sys.exit("set ETH_RPC")

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DEPLOY = json.load(open(f"{ROOT}/deployments/{ENV}/{CHAIN}.json"))

AM    = DEPLOY["accessManager"]
if int(AM, 16) == 0:
    sys.exit(f"accessManager is the zero address in deployments/{ENV}/{CHAIN}.json — "
             f"the v3 AccessManager is not deployed yet; run this only after cutover.")
ICS26 = DEPLOY["ics26Router"]["proxy"]
ICS20 = DEPLOY["ics20Transfer"]["proxy"]
ICS27 = DEPLOY["ics27Gmp"]["proxy"]
ROLES = DEPLOY["accessManagerRoles"]

ROLE_NAMES = {0:"ADMIN",1:"RELAYER",2:"PAUSER",3:"UNPAUSER",4:"DELEGATE_SENDER",
              5:"RATE_LIMITER",6:"ID_CUSTOMIZER",7:"ERC20_CUSTOMIZER"}

# (target, role) -> {selector: human name}. HAND-ENCODED 4-byte selectors, cross-checked against
# IBCRolesLib + the v3 deploy wiring (see module docstring). Keep in sync on a SOL version bump.
TARGET_ROLES = [
    (ICS26, 6, {"0x5f516889":"addIBCApp(string,address)", "0x1ec43e23":"addClient(string,(string,bytes[]),address)"}),
    (ICS26, 1, {"0x5ebd10ca":"recvPacket", "0xb98c330a":"timeoutPacket", "0x1bca011a":"ackPacket", "0x6fbf8079":"updateClient"}),
    (ICS26, 0, {"0x4f1ef286":"upgradeToAndCall", "0xcce0b265":"migrateClient"}),
    (ICS20, 2, {"0x8456cb59":"pause"}),
    (ICS20, 3, {"0x3f4ba83a":"unpause"}),
    (ICS20, 7, {"0xa1d28f57":"setCustomERC20"}),
    (ICS20, 4, {"0xb29c715d":"sendTransferWithSender"}),
    (ICS20, 0, {"0xaaa2c343":"upgradeEscrowTo", "0x06ab20bc":"upgradeIBCERC20To", "0x4f1ef286":"upgradeToAndCall"}),
    (ICS27, 2, {"0x8456cb59":"pause"}),
    (ICS27, 3, {"0x3f4ba83a":"unpause"}),
    (ICS27, 0, {"0x4f1ef286":"upgradeToAndCall", "0xdd7345e3":"upgradeAccountTo"}),
]
SET_RATE_LIMIT_SEL = "0xd34a3fd9"

# RATE_LIMITER(5) + rateLimitedEscrows read TOP-LEVEL (must be: the deploy rewrites .accessManagerRoles at
# step 2, dropping anything nested there). Empty pre-step-10 (testnet) / pre-staged on mainnet so a missed
# grant hard-fails. cfg(): top-level, then the legacy nested location, else empty.
def cfg(key):
    return DEPLOY.get(key) or ROLES.get(key) or []

ROLE_JSON_KEY = {1:"relayers", 2:"pausers", 3:"unpausers", 4:"delegateSenders",
                 6:"idCustomizers", 7:"erc20Customizers"}   # 5 handled separately via cfg()
EXPECTED = {0: {ROLES["admin"].lower()}, 5: {a.lower() for a in cfg("rateLimiters")}}
for rid, key in ROLE_JSON_KEY.items():
    EXPECTED[rid] = {a.lower() for a in ROLES.get(key, [])}

# event scan start block
FROM_BLOCK = os.environ.get("FROM_BLOCK")
if not FROM_BLOCK:
    bc = f"{ROOT}/broadcast/DeployV3AccessManager.sol/{CHAIN}/run-latest.json"
    try:
        rcpts = json.load(open(bc)).get("receipts", [])
        FROM_BLOCK = str(min(int(r["blockNumber"], 16) for r in rcpts))
    except Exception:
        FROM_BLOCK = "0"

passes, fails = [], []
def ok(m):  passes.append(m); print(f"  \033[32mPASS\033[0m  {m}")
def bad(m): fails.append(m);  print(f"  \033[31mFAIL\033[0m  {m}")

def cast(*a):
    return subprocess.run(["cast", *a, "--rpc-url", RPC], capture_output=True, text=True, check=True).stdout.strip()

def has_role(role, acct):
    p = cast("call", AM, "hasRole(uint64,address)(bool,uint32)", str(role), acct).split()
    return p[0] == "true", int(p[1])

print(f"\nValidating {ENV}/{CHAIN}  AccessManager={AM}  (events from block {FROM_BLOCK})")

# A. target function roles
print("\n=== A. Target function roles ===")
for target, role, sels in TARGET_ROLES:
    for sel, name in sels.items():
        got = int(cast("call", AM, "getTargetFunctionRole(address,bytes4)(uint64)", target, sel))
        label = f"{target[:10]}.. {name:<42} -> {ROLE_NAMES[role]}({role})"
        ok(label) if got == role else bad(f"{label}  but on-chain={ROLE_NAMES.get(got,'?')}({got})")

# B. membership from events
print("\n=== B. Role membership (RoleGranted/RoleRevoked reconstruction) ===")
def logs(sig):
    raw = subprocess.run(["cast","logs",sig,"--address",AM,"--from-block",FROM_BLOCK,
                          "--to-block","latest","--rpc-url",RPC,"--json"],
                         capture_output=True, text=True, check=True).stdout
    return json.loads(raw)
ev = []
for lg in logs("RoleGranted(uint64 indexed,address indexed,uint32,uint48,bool)"):
    ev.append((int(lg["blockNumber"],16), int(lg["logIndex"],16), "g",
               int(lg["topics"][1],16), "0x"+lg["topics"][2][-40:].lower(), int(lg["data"][2:66],16)))
for lg in logs("RoleRevoked(uint64 indexed,address indexed)"):
    ev.append((int(lg["blockNumber"],16), int(lg["logIndex"],16), "r",
               int(lg["topics"][1],16), "0x"+lg["topics"][2][-40:].lower(), 0))
ev.sort()
members = {}   # role -> {acct: execution_delay}, applying grants/revokes in chain order
for _blk, _idx, kind, role, acct, delay in ev:
    members.setdefault(role, {})
    if kind == "g":
        members[role][acct] = delay
    else:
        members[role].pop(acct, None)
for role in sorted(ROLE_NAMES):
    onchain = members.get(role, {})
    exp, got = EXPECTED.get(role, set()), set(onchain)
    name = ROLE_NAMES[role]
    if exp == got:
        ok(f"{name}({role}): {len(exp)} holder(s) match exactly")
    else:
        if exp-got: bad(f"{name}({role}): MISSING {sorted(exp-got)}")
        if got-exp: bad(f"{name}({role}): UNEXPECTED {sorted(got-exp)}")
    for a in onchain:
        m, d = has_role(role, a)
        if not m: bad(f"{name}({role}) {a}: event=granted but hasRole=false")
        elif d:   bad(f"{name}({role}) {a}: execution delay {d} != 0")

# C. authority wiring (+ resolve escrows for D)
print("\n=== C. authority() == AccessManager ===")
escrows = {}
for cid in (DEPLOY.get("light_clients") or {}).values():
    e = cast("call", ICS20, "getEscrow(string)(address)", cid["clientId"])
    if int(e, 16) != 0: escrows[cid["clientId"]] = e
targets = [("ICS26Router",ICS26),("ICS20Transfer",ICS20),("ICS27GMP",ICS27)] + \
          [(f"escrow {k}", v) for k, v in escrows.items()]
for label, addr in targets:
    a = cast("call", addr, "authority()(address)")
    ok(f"{label} authority == AccessManager") if a.lower()==AM.lower() else bad(f"{label} authority={a}")

# D. rate-limiter target wiring. CONDITIONAL gate: escrows listed in `.accessManagerRoles.rateLimitedEscrows`
# MUST have setRateLimit wired to RATE_LIMITER(5) — a hard FAIL otherwise. This is the per-escrow wiring check
# that role-5 *membership* (section B) does NOT cover: RATE_LIMITER is manager-wide, so granting the role to
# every holder leaves membership complete even if an intended escrow was never wired. Escrows NOT in the list
# stay informational, so the by-design pre-grant state (TODO #559: escrows unwired until granted; testnet has
# an empty list) is unchanged and still passes.
RATE_LIMITED = {c.strip() for c in cfg("rateLimitedEscrows") if c.strip()}
print("\n=== D. Escrow setRateLimit gating ===")
for cid, e in escrows.items():
    r = int(cast("call", AM, "getTargetFunctionRole(address,bytes4)(uint64)", e, SET_RATE_LIMIT_SEL))
    if cid in RATE_LIMITED:
        label = f"escrow {cid}: setRateLimit -> RATE_LIMITER(5) (required by rateLimitedEscrows)"
        ok(label) if r == 5 else bad(f"escrow {cid}: setRateLimit -> {ROLE_NAMES.get(r,'?')}({r}), expected RATE_LIMITER(5) — NOT wired")
    else:
        note = "RATE_LIMITER(5) — wired" if r == 5 else f"{ROLE_NAMES.get(r,'?')}({r}) — not wired (informational)"
        print(f"  INFO  escrow {cid}: setRateLimit -> {note}")

print(f"\n{'='*60}\nSUMMARY: {len(passes)} passed, {len(fails)} failed")
if fails:
    print("\nFAILURES:"); [print("  - "+f) for f in fails]
    sys.exit(1)
print("ALL CHECKS PASSED")
