# RUNBOOK — Post-upgrade AccessManager role testing

Validate, after a v2→v3 upgrade, that **(1)** every role was migrated/configured exactly as
intended, and **(2)** each role can *actually be executed* by its holders while non-holders are
rejected. Part 0 answers (1) statically; Parts 1–3 answer (2) by exercising the gates.

> This is a **testnet** plan. Every address/command below is for Sepolia
> (`testnet` / `11155111`); the tooling reads addresses from the deployment JSON, so the same
> steps apply to mainnet by changing `ENV`/`CHAIN`. Run the whole thing on testnet and sign it
> off **before** the mainnet upgrade, then re-run Part 0 (and the Tier-S simulations) on mainnet
> immediately after cutover.
>
> ⚠️ **Mainnet is materially different and cannot be driven the way testnet was** — 4-of-7 Safe,
> 72-hour timelock delay, real funds. **Read "[Mainnet adaptation](#mainnet-adaptation)" before
> running any Part-2 step on mainnet.**

## Context

- **Auth model.** v3 gates every privileged call through one shared OZ `AccessManager`
  (`0x5617…`). A call is allowed iff `getTargetFunctionRole(target, selector)` is a role the
  caller holds (`hasRole`). `ADMIN_ROLE = 0` is the implicit default for any unset selector and
  is held only by the `TimelockController` (`0x8948…`).
- **Roles** (`IBCRolesLib`): `RELAYER=1`, `PAUSER=2`, `UNPAUSER=3`, `DELEGATE_SENDER=4`,
  `RATE_LIMITER=5`, `ID_CUSTOMIZER=6`, `ERC20_CUSTOMIZER=7`, `ADMIN=0`.
- **Admin path.** AccessManager admin ops (`grantRole`, `revokeRole`, `setTargetFunctionRole`,
  proxy/beacon upgrades, `migrateClient`) are `ADMIN`-gated, i.e. only the timelock can do them.
  The timelock's `PROPOSER`/`EXECUTOR` is the **Safe** (`0x85CF…`, 1-of-2). So every admin test is
  **Safe → Timelock (60 s delay on testnet) → AccessManager**, never a direct EOA call.
- **Rate-limiter caveat (upstream TODO #559).** Escrows' `setRateLimit` is **not** wired to
  `RATE_LIMITER` at deploy — it currently maps to `ADMIN(0)`. The grant recipe
  (`timelock-grant-rate-limiter-role`) wires `setTargetFunctionRole(escrow, setRateLimit, 5)`
  *and* grants role 5 in one timelock op. So role 5 cannot be exercised at all until that op runs
  (Part 2.3). Part 0 reports the current wiring.

## Addresses (testnet)

| Thing | Address |
|---|---|
| AccessManager | `0x56172716671657a4DF912d3665603C294DAaE10f` |
| ICS26Router (proxy) | `0x3fcBB8b5d85FB5F77603e11536b5E90FeE37e6c0` |
| ICS20Transfer (proxy) | `0x3a4e076D1c5EBfC813993c497Bb284598121b515` |
| ICS27GMP (proxy) | `0x94f2aCB923081204b171E804E83183d457DBBB72` |
| TimelockController (ADMIN) | `0x8948ca6bB5E2F50A235DB3eFf7c125188c6AD14b` |
| Proposer/Executor Safe | `0x85CF98533e3275450a0d61D9BC236225947C5882` |
| Escrow hub-testnet-0 | `0x8Fb1B17156EcaBBAA0280c4180c0263069965a77` |
| Escrow ledger-testnet-1 | `0x6C2CF3aDAF0ab7fa0cEc019B31FfD3e58A6B636A` |
| Sample role holders | RELAYER `0xBbA433BE…`; PAUSER/UNPAUSER/ID/ERC20 customizer `0x64259f72…`; DELEGATE_SENDER `0x46914a36…` |
| Known non-holder (negatives) | `0x000000000000000000000000000000000000dEaD` |

```bash
export ETH_RPC=https://ethereum-sepolia-rpc.publicnode.com
AM=0x56172716671657a4DF912d3665603C294DAaE10f
ICS26=0x3fcBB8b5d85FB5F77603e11536b5E90FeE37e6c0
ICS20=0x3a4e076D1c5EBfC813993c497Bb284598121b515
ICS27=0x94f2aCB923081204b171E804E83183d457DBBB72
NOBODY=0x000000000000000000000000000000000000dEaD
```

## Test tiers

| Tier | What | Mutates chain? | When |
|---|---|---|---|
| **S — Simulation** | `eth_call` the gated fn from a **holder** (must pass the gate) and from a **non-holder** (must revert `AccessManagedUnauthorized` `0x068ca9d8`). Proves wiring end-to-end. | No | Anytime — run for **every** role. |
| **P — Proven in prod** | Role already executed a real on-chain tx during/after the upgrade — cite the hash. | (already did) | Evidence only. |
| **L — Live round-trip** | Actually perform the action and **revert it**. Proves real execution authority. | Yes (reversible) | Maintenance window. |
| **F — Fork only** | Upgrade-class actions (`upgradeToAndCall`, beacon upgrades, `migrateClient`, `upgradeAccountTo`). Destructive/irreversible — **never live-test on a production deployment**; rehearse on a shadow fork. | n/a | Shadow fork. |

The gate test in one helper — passes the gate ⇢ revert is *not* `0x068ca9d8`:

```bash
# gatecheck <from> <target> <sig> [args...]  -> prints PASS-GATE / BLOCKED / REVERT-PAST-GATE
gatecheck() { local from=$1 to=$2 sig=$3; shift 3
  out=$(cast call "$to" "$sig" "$@" --from "$from" --rpc-url "$ETH_RPC" 2>&1) && { echo "PASS-GATE (returned ok)"; return; }
  case "$out" in
    *068ca9d8*|*AccessManagedUnauthorized*) echo "BLOCKED by AccessManager (0x068ca9d8)";;
    *) echo "REVERT-PAST-GATE (gate passed; later revert): $(echo "$out" | tail -1)";;
  esac; }
```

---

## Part 0 — static role inventory (answers "were they migrated correctly?")

One command; trusts no deploy artifact (reconstructs membership from `RoleGranted`/`RoleRevoked`
events, so it catches missing **and** stray holders, and confirms every holder's execution delay
is 0):

```bash
ETH_RPC=$ETH_RPC python3 scripts/validate-v3-roles.py testnet 11155111
```

Asserts: **A** every `(target, selector)` → expected role; **B** each role's members equal the
deployment JSON exactly (incl. `ADMIN == {timelock}`, which also proves the bootstrap renounced
and no EOA is a stray admin); **C** all proxies + escrows `authority() == AccessManager`; **D**
reports escrow `setRateLimit` wiring (expected: still `ADMIN(0)` until Part 2.3 runs).

✅ Current testnet result: **32/32 pass, 0 failed** (last run 2026-06-16). Re-run after any role
change and immediately post-mainnet-cutover. The pass **total scales with the resolved escrow
count** (each escrow adds an `authority()` and a `setRateLimit` line), so judge the run by **`0
failed`**, not an absolute total: testnet has 2 escrows (→ 32); **mainnet has 3 escrows**
(`cosmoshub-0`, `ledger-mainnet-1`, `client-4`) → expect **~33 passed / 0 failed**. `client-4`'s
*escrow* is still upgraded and validated even though its *light client* is dropped from the SP1 v6.1
migration (the escrow beacon upgrade flips all escrow proxies regardless) — so all 3 still appear.

> **After step 10 on mainnet, role `RATE_LIMITER(5)` is NOT empty** (testnet had zero holders,
> which is why role 5 stayed empty there). Populate `.accessManagerRoles.rateLimiters` in
> `deployments/mainnet/1.json` with the re-granted holders so Part B matches exactly; otherwise the
> tool flags the live role-5 holders as `UNEXPECTED` and exits non-zero. See
> [`runbooks/operations/2026-06-15-upgrade-v2-to-v3/RECORD.md`](operations/2026-06-15-upgrade-v2-to-v3/RECORD.md)
> for the snapshot.

> **Mainnet prerequisites for `validate-v3-roles.py`:** the script exits early while
> `accessManager == 0x0`, and Parts A/C also read `ics27Gmp.proxy` — so first write the deployed
> **AccessManager** and **`ics27Gmp.proxy`** (+ implementation/accountImplementation) into
> `deployments/mainnet/1.json`, and pass **`FROM_BLOCK=<AccessManager deploy block>`** explicitly
> (the local `broadcast/DeployV3AccessManager.sol/1/` artifact won't exist on a signer's machine; a
> from-block of `0` is rejected for range by public RPCs).

---

## Part 1 — simulation matrix (Tier S, non-destructive — the core check)

For each role: one positive (`--from` a holder ⇒ passes the gate) and one negative (`--from
$NOBODY` ⇒ `0x068ca9d8`). None of these mutate state.

### RELAYER (1) — ICS26Router `recvPacket` / `updateClient` / …
```bash
gatecheck 0xBbA433BE673Bb680c6fC1C252339b9B48830F32e $ICS26 "updateClient(string,bytes)" hub-testnet-0 0x   # holder ⇒ REVERT-PAST-GATE (empty proof)
gatecheck $NOBODY                                    $ICS26 "updateClient(string,bytes)" hub-testnet-0 0x   # ⇒ BLOCKED
```
Stronger functional proof exists — see Part-P (a real `recvPacket` already verified a v6.1 proof
on-chain). Note the SP1 client *also* enforces its own relayer check
(`AccessControlUnauthorizedAccount` `0xe2517d3f`) one layer below the AccessManager gate.

### PAUSER (2) / UNPAUSER (3) — cleanest demonstration (`eth_call` returns ok, no mutation)
```bash
cast call $ICS20 "pause()"   --from 0x64259f722A0868CCf58A935C61A292cEA9dF035a --rpc-url $ETH_RPC   # ⇒ 0x (allowed)
gatecheck $NOBODY $ICS20 "pause()"                                                                  # ⇒ BLOCKED
cast call $ICS20 "unpause()" --from 0x64259f722A0868CCf58A935C61A292cEA9dF035a --rpc-url $ETH_RPC   # ⇒ ExpectedPause 0x8dfc202b = gate passed, not paused
gatecheck $NOBODY $ICS20 "unpause()"                                                                # ⇒ BLOCKED
```
Repeat against `$ICS27` (same selectors, same holders).

### ID_CUSTOMIZER (6) — ICS26Router `addIBCApp`
```bash
gatecheck 0x64259f722A0868CCf58A935C61A292cEA9dF035a $ICS26 "addIBCApp(string,address)" testport 0x000...0001  # ⇒ PASS/REVERT-PAST-GATE
gatecheck $NOBODY                                    $ICS26 "addIBCApp(string,address)" testport 0x000...0001  # ⇒ BLOCKED
```

### ERC20_CUSTOMIZER (7) — ICS20Transfer `setCustomERC20`
```bash
gatecheck 0x64259f722A0868CCf58A935C61A292cEA9dF035a $ICS20 "setCustomERC20(string,address)" testdenom 0x000...0001  # ⇒ past gate
gatecheck $NOBODY                                    $ICS20 "setCustomERC20(string,address)" testdenom 0x000...0001  # ⇒ BLOCKED
```

### DELEGATE_SENDER (4) — ICS20Transfer `sendTransferWithSender` (holder is a contract)
```bash
# minimal MsgSendTransfer tuple; holder passes the gate then reverts in transfer logic
gatecheck 0x46914a36365EC16600D81880903f3e95dcea3e5D $ICS20 \
  "sendTransferWithSender((address,uint256,string,string,string,uint64,string),address)" \
  "(0x0000000000000000000000000000000000000000,0,denom,cosmos1,memo,0,client)" 0x46914a36365EC16600D81880903f3e95dcea3e5D   # ⇒ REVERT-PAST-GATE
gatecheck $NOBODY $ICS20 "sendTransferWithSender(...)" ...   # ⇒ BLOCKED
```

### RATE_LIMITER (5) — special
`setRateLimit` is **not callable by anyone but the timelock yet** (maps to `ADMIN(0)`; zero role-5
holders). The simulation therefore shows `BLOCKED` from every EOA — which is correct. Real
execution of role 5 requires enabling it first (Part 2.3).

### ADMIN (0) — timelock-only
AccessManager admin fns (`grantRole`, etc.) revert from any EOA. Real execution = a timelock op
(Part 2.2). A simulation that the timelock *would* be allowed:
```bash
cast call $AM "grantRole(uint64,address,uint32)" 2 $NOBODY 0 --from 0x8948ca6bB5E2F50A235DB3eFf7c125188c6AD14b --rpc-url $ETH_RPC   # ⇒ 0x (allowed for timelock)
cast call $AM "grantRole(uint64,address,uint32)" 2 $NOBODY 0 --from $NOBODY --rpc-url $ETH_RPC                                       # ⇒ reverts
```

**Tier-S exit criteria:** every role shows a holder passing the gate and `$NOBODY` blocked
(role 5 / admin as noted above).

---

## Part P — already proven in production (no action needed, cite as evidence)

| Role | Real tx | Proof |
|---|---|---|
| RELAYER (1) | relayer `0xBbA433BE…` `multicall([recvPacket])` (`0x15ca938e…`) | a v6.1 SP1 uc-and-membership proof verified on-chain; hub-testnet-0 client advanced 17,756,866 → 17,762,883 |
| ID_CUSTOMIZER (6) | `addIBCApp("gmpport", 0x94f2…)` from `0x64259f72…` (`0xa2db63b2…`) | step-8 ICS27 registration succeeded |

These two roles are therefore confirmed executable *for real*, not just in simulation.

---

## Part 2 — live reversible execution tests (Tier L, maintenance window)

Do these in a window where brief disruption is acceptable. Each is a round-trip that restores the
prior state. Re-run `validate-v3-roles.py` after each to confirm clean restoration.

### 2.1 PAUSER → UNPAUSER round-trip (the emergency lever — worth doing for real)
Pausing halts ICS20 transfers, so keep the window tight. Set `.eureka-env` signer to a PAUSER
holder, then:
```bash
just ops-pause-transfers       # signer holds PAUSER_ROLE; takes effect immediately
cast call $ICS20 "paused()(bool)" --rpc-url $ETH_RPC       # expect true
# (optional) confirm a transfer now reverts EnforcedPause 0xd93c0665
just ops-unpause-transfers     # signer holds UNPAUSER_ROLE
cast call $ICS20 "paused()(bool)" --rpc-url $ETH_RPC       # expect false
```
**Why for real:** pause is the incident-response kill switch — you want proof it fires *before* you
need it. Fully reversible.

### 2.2 ADMIN grant → revoke round-trip (exercises Safe → Timelock → AccessManager)
Grant a throwaway role to `$NOBODY` and revoke it. Uses the real governance recipes:
```bash
# schedule a grantRole(PAUSER, $NOBODY) timelock op and propose it to the Safe
just timelock-grant-role schedule        # prints timelock calldata + safeTxHash; or: just propose-schedule …
#   → sign+execute the Safe tx (1-of-2), wait 60 s, then execute the timelock op
just verify-execute-grant-role <nonce>   # asserts hasRole(PAUSER,$NOBODY)=true afterwards
# now revoke to restore state
just timelock-revoke-role schedule       # grantee $NOBODY ; sign+execute via Safe, wait 60 s, execute
just verify-execute-revoke-role <nonce>  # asserts hasRole=false
```
Proves: the Safe can drive the timelock, the timelock holds `ADMIN`, and the AccessManager honors
it. After revoke, `validate-v3-roles.py` must again show exact-match membership.

### 2.3 RATE_LIMITER (5) full enablement → use → teardown
The only role that needs wiring before it can be exercised. The grant recipe atomically wires
`setTargetFunctionRole(escrow, setRateLimit, 5)` **and** `grantRole(5, grantee)`:
```bash
# pick a test grantee + escrow; RL_GRANT_ADDRESS / RL_GRANT_CLIENT_ID feed the recipe
just timelock-grant-rate-limiter-role schedule   # propose to Safe; sign+execute; wait 60 s; execute
just verify-execute-grant-rate-limiter-role <nonce>
# now the grantee can actually set a limit:
cast send $ESCROW "setRateLimit(address,uint256)" <token> <limit> --from <grantee> ...   # ⇒ success
# teardown: revoke role 5 (and, if desired, a follow-up op to reset the target role to ADMIN)
```
This path is already covered on a fork by
`REHEARSE_RATE_LIMITER_GRANT=1 scripts/shadow-v2-to-v3-timelock-rehearsal.sh`; Part 2.3 is the live
testnet confirmation of the same fold.

---

## Part 3 — upgrade-class actions (Tier F — fork only, do NOT live-test)

`ADMIN`-gated upgrade selectors — `upgradeToAndCall` (ICS26/ICS20/ICS27), `upgradeEscrowTo`,
`upgradeIBCERC20To`, `upgradeAccountTo`, `migrateClient` — are irreversible and change live code.
**Do not** exercise them against a production deployment just to test the gate. Their executability
is proven by:

1. The v2→v3 upgrade itself (the ICS20/ICS26 `upgradeToAndCall` + escrow/ibcERC20 beacon upgrades
   already executed via the timelock — see
   [`runbooks/operations/2026-06-15-upgrade-v2-to-v3/RECORD.md`](operations/2026-06-15-upgrade-v2-to-v3/RECORD.md)).
2. The SP1 `migrateClient` ops that landed during the upgrade.
3. The shadow-fork rehearsal (`just shadow-v2-to-v3-sepolia-with-sp1`), which runs the whole admin
   upgrade path end-to-end against a fork.

For a *fresh* gate check without touching prod, run a Tier-S simulation: `eth_call` an
`upgradeToAndCall` from `$NOBODY` ⇒ `0x068ca9d8`, and from the timelock ⇒ passes the gate.

---

## Negative-test reference (revert selectors)

| Selector | Error | Meaning |
|---|---|---|
| `0x068ca9d8` | `AccessManagedUnauthorized(address)` | AccessManager gate rejected the caller — **the role check we are testing**. |
| `0xe2517d3f` | `AccessControlUnauthorizedAccount(address,bytes32)` | OZ AccessControl rejection from the SP1 light client's own relayer check (one layer below the manager). |
| `0xd93c0665` | `EnforcedPause()` | Action blocked because contract is paused (gate already passed). |
| `0x8dfc202b` | `ExpectedPause()` | `unpause()` reached logic while not paused (gate already passed). |

A `REVERT-PAST-GATE` with any selector **other than** `0x068ca9d8` is a **passing** positive gate
test — the AccessManager allowed the caller and the call failed later for an unrelated reason.

## Sign-off checklist

- [ ] Part 0 `validate-v3-roles.py` → all pass (A target roles, B exact membership, C authority, D rate-limit note).
- [ ] Part 1 Tier-S: every role shows holder-passes + `$NOBODY`-blocked.
- [ ] Part P: RELAYER + ID_CUSTOMIZER prod txs cited.
- [ ] Part 2.1: pause/unpause round-trip executed and restored.
- [ ] Part 2.2: admin grant/revoke round-trip via Safe→Timelock executed and restored.
- [ ] Part 2.3: rate-limiter enable → setRateLimit → teardown executed and restored.
- [ ] Part 3: upgrade-class confirmed via the upgrade itself + fork rehearsal (not live-tested).
- [ ] Final `validate-v3-roles.py` re-run → membership back to the configured baseline.

## Testnet execution record — 2026-06-16 (Sepolia, all green)

Driven autonomously via **Safe (1-of-2, threshold 1, hot-key owner `0x15C1…`) → TimelockController
(60 s delay) → AccessManager**, using direct `execTransaction` (the cutover mechanism), each Safe
tx eth-call dry-run before broadcast. Safe nonces 45→56 (6 schedules + 6 executes) plus the direct
role-holder action txs. Every test restored its state; no residue.

- **Part 0** — `validate-v3-roles.py` → **32/32** (and re-run after Part 2 → **32/32**, baseline restored).
- **Part 1 (Tier S)** — gate simulation matrix for all 8 roles, both directions → **21/21** (holder passes the gate; `0xdEaD` blocked by `0x068ca9d8`, AccessManager self-admin by `0xf07e038f`).
- **Part P** — RELAYER (`recvPacket` `0x15ca938e…`) + ID_CUSTOMIZER (`addIBCApp` `0xa2db63b2…`) already proven in prod.
- **2.2 ADMIN** — grant→revoke `PAUSER` to `0xdEaD`: `hasRole(2,dead)` false → **true** → **false**; both timelock ops `isOperationDone`.
- **2.1 PAUSER/UNPAUSER** — temp-granted both to the hot key, **`pause()` → `paused()==true`**, **`unpause()` → `paused()==false`**, then revoked both.
- **2.3 RATE_LIMITER** — wired `setRateLimit`→role 5 + granted role 5 to the hot key; hot key **`setRateLimit(dummy,1e6)` → `getRateLimit==1e6`**; reset to 0; teardown restored target→`ADMIN(0)` + revoked role 5.
- **Part 3** — not live-tested (upgrade-class); proven by the v2→v3 upgrade itself + `shadow-v2-to-v3-*` fork rehearsals.

**Conclusion: all 8 roles confirmed *executable* (6 by real on-chain action, ADMIN + RATE_LIMITER
via timelock ops here), all non-holders confirmed *rejected*, and the deployment is back to its
exact configured baseline.**

## Mainnet adaptation

The testnet run was driven end-to-end by one process because the Sepolia governance is a **1-of-2
Safe whose owner is a hot key** and the **timelock delay is 60 s**. **Neither holds on mainnet.**
Confirmed mainnet on-chain state (chain 1) as of 2026-06-16, *pre-upgrade*:

| Aspect | Testnet (Sepolia) | **Mainnet (chain 1)** |
|---|---|---|
| AccessManager | deployed | **not deployed yet** (`accessManager == 0x000…0`); role testing is **post-cutover only** |
| Governance Safe | 1-of-2, hot-key owner | **`0x7B96CD54…` — 4-of-7** (7 hardware-wallet owners) |
| Timelock | `0x8948…`, delay **60 s** | **`0xb3999B2D…`, delay 259 200 s = 72 h (3 days)**; Safe is PROPOSER+EXECUTOR |
| Driving | autonomous (`/tmp/gov.sh`) | **impossible autonomously** — every Safe tx needs **4 signatures**; every timelock op needs a **3-day wait** |
| Funds / traffic | testnet, low | **real funds, real users** — a pause halts real transfers |
| Role holders | see testnet table | different sets (5 pausers, unpauser = the Safe, 2 delegate senders, 4 relayers, 1 id/erc20 customizer, 3 light clients) |

### What this changes

1. **Preconditions.** `validate-v3-roles.py mainnet 1` only works **after** the v3 AccessManager is
   deployed and written into `deployments/mainnet/1.json`. Until then it exits (accessManager is
   zero). Set `FROM_BLOCK` to the AccessManager deploy block (the script auto-reads it from
   `broadcast/DeployV3AccessManager.sol/1/run-latest.json` once that exists) — a from-block of 0
   over a public mainnet RPC will be rejected for range.
2. **`/tmp/gov.sh` does not apply.** It re-signs a 1-of-1 Safe with a local key. Mainnet Part-2 ops
   go through the **production recipes + the Safe UI / transaction service** with the real 4-of-7
   signer set: `just timelock-grant-role`/`timelock-revoke-role`/`timelock-grant-rate-limiter-role`
   → `just propose-schedule …` (or `safe-propose`) → collect 4 sigs → execute → **wait 72 h** →
   `just verify-execute-*`. The inner AccessManager calldata is byte-identical to what the testnet
   rehearsal used (same `grantRole`/`revokeRole`/`setTargetFunctionRole`/`multicall` shapes), so the
   testnet run **is** the mechanism rehearsal.
3. **Calendar, not minutes.** Because setup and teardown are independent ops (distinct salts, no
   predecessor), **schedule both in the same Safe session**, wait the single 72 h window, then in one
   later session: execute setup → do the direct action → execute teardown. Budget per test:
   1 schedule ceremony + 3 days + 1 execute ceremony. Batch all chosen tests' ops into the two
   ceremonies to amortize the wait to a single 72 h window total.

### Discovering the complete grant set (pre-cutover)

The bootstrap only grants what's in `deployments/<env>/<chain>.json` `accessManagerRoles`. That JSON is
hand-maintained, and the v2 role model is **richer than it** (per-client roles, a token operator, etc.),
so before the round, enumerate the *actual* live v2 holders and reconcile:

```bash
ETH_RPC=<rpc> ETHERSCAN_API_KEY=<key> python3 scripts/discover-v2-roles.py mainnet 1
```

`discover-v2-roles.py` reads each live v2 contract's `RoleGranted`/`RoleRevoked` history (Etherscan
logs API — no 50k-block cap), reconstructs the current holder set per role, confirms with `hasRole`,
self-discovers role names via the on-chain getters (and classifies per-client
`LIGHT_CLIENT_MIGRATOR_ROLE`s by their grant tx), then reconciles against the JSON + v3 role model.

**Mainnet result (2026-06-16, pre-upgrade):**

| v2 role(s) | live holders | v3 disposition |
|---|---|---|
| RELAYER, PAUSER, UNPAUSER, DELEGATE_SENDER, PORT+CLIENT_ID_CUSTOMIZER, ERC20_CUSTOMIZER | **match the JSON exactly** | auto-granted by the bootstrap from the JSON — no action |
| **RATE_LIMITER** (escrows `cosmoshub-0`, `ledger-mainnet-1`) | `0x4b46ea82…`, `0x64259f72…` (client-4 escrow: none) | **not in the JSON → re-grant in step 10** |
| TOKEN_OPERATOR (ICS20) | `0x4b46ea82…`, timelock | **no v3 role** — it managed who may relabel IBCERC20 metadata (`grant/revokeMetadataCustomizerRole` → `setMetadata`). v3 removes mutable IBCERC20 metadata entirely; the replacement is `setCustomERC20` under **`ERC20_CUSTOMIZER`** (migrated), so `0x4b46ea82…` keeps the comparable power. Only the *in-place relabel of an auto-token* is gone. |
| LIGHT_CLIENT_MIGRATOR (×11 per-client: client-0..4, hub-testnet-0..3, cosmoshub-0, ledger-mainnet-1) | deployer + timelock | **no v3 role** (migrateClient is ADMIN-gated) — dropped; governance-held only |
| DEFAULT_ADMIN (ICS26 + ICS20) | timelock `0xb3999B2D…` | becomes v3 `ADMIN` (the timelock) |

Takeaways for the round: the 6 bootstrap-migrated roles are complete; the **only grant not covered by
the JSON is `RATE_LIMITER`** (2 accounts × 2 escrows) — fold it into the step-6/7 timelock round (or
do step 10 after). The token-operator and per-client migrator capabilities are intentionally gone in
v3 (token-operator's intent — controlling a denom's ERC20 — is covered by `setCustomERC20` /
`ERC20_CUSTOMIZER`; what's removed is mutating an auto-deployed IBCERC20's metadata in place, and
per-client migration is now ADMIN-gated); confirm that's acceptable. Re-run this tool right before
cutover in case holders change.

**IBCERC20 metadata (informational — no action needed).** Metadata customization *was* used in v2:
5 of the 13 auto-deployed tokens carry custom name/symbol/decimals (`cosmoshub-0/uatom` → "Cosmos Hub
ATOM", plus SEDA, Nillion, and two hub-testnet ATOMs). It survives the v2→v3 IBCERC20 beacon upgrade
unchanged — identical storage layout (same `IBCERC20_STORAGE_SLOT` + struct) and the per-denom proxies
are never re-initialized — so v3 just freezes it (no more `setMetadata`). One enumeration caveat if you
ever audit the token set: `setCustomERC20` (the `ERC20_CUSTOMIZER` path) registers external tokens with
*no event*, so the registered-denom set is larger than the `IBCERC20ContractCreated` logs imply — on
mainnet (2026-06-16) it's 13 beacon tokens + 6 external = 19. Enumerate via both paths; a couple of the
externals are plain mintable tokens (they don't expose `ics20()`) whose mint/burn is keyed to the
unchanged ICS20 proxy address, so the upgrade doesn't touch them.

### Recommended mainnet scope (run post-cutover)

- **Always, immediately after cutover (read-only, safe, automatable):**
  - **Part 0** — `ETH_RPC=<mainnet> python3 scripts/validate-v3-roles.py mainnet 1` (with `FROM_BLOCK`).
  - **Part 1 (Tier S)** — the gate-simulation matrix, swapping in the mainnet addresses/holders. No
    keys, no mutation; this alone proves every role authorizes the right holder and rejects others.
  - **Part P** — cite the real relayer + ICS27-registration txs from the mainnet cutover.
- **Part 2 (mutating) — only with sign-off, via the 4-of-7 + 72 h path:**
  - **2.2 ADMIN grant→revoke** to a throwaway address — **recommended**; lowest risk, highest value
    (proves the live governance stack end-to-end).
  - **2.3 RATE_LIMITER** — acceptable using a **provably inert dummy token** (an address that is not a
    real escrowed denom), set then zeroed; note the target-role wiring is changed for the duration.
  - **2.1 real pause/unpause** — **high disruption** (halts real transfers). Prefer the Part-1
    simulation; do a real round-trip **only** in a pre-announced maintenance window. The mainnet
    unpauser is the Safe itself, so unpause is a 4-of-7 action.
- **Part 3 (upgrade-class)** — never live-test; covered by the mainnet upgrade itself + the
  `shadow-v2-to-v3-mainnet-*` fork rehearsals.

### Mainnet addresses (from `deployments/mainnet/1.json`, pre-upgrade)

| Thing | Address |
|---|---|
| ICS26Router (proxy) | `0x3aF134307D5Ee90faa2ba9Cdba14ba66414CF1A7` |
| ICS20Transfer (proxy) | `0xa348CfE719B63151F228e3C30EB424BA5a983012` |
| AccessManager | **TBD** (deployed at cutover) |
| TimelockController (ADMIN) | `0xb3999B2D30dD8c9faEcE5A8a503fAe42b8b1b614` (delay 72 h) |
| Governance Safe (4-of-7) | `0x7B96CD54aA750EF83ca90eA487e0bA321707559a` |
| Light clients | `cosmoshub-0`, `ledger-mainnet-1`, `client-4` (→ 3 escrows) |
| ID/ERC20 customizer | `0x4b46ea82D80825CA5640301f47C035942e6D9A46` |

These come straight from the deployment JSON; `validate-v3-roles.py` and the Part-1 matrix read them
from there, so the only manual edits for mainnet are the RPC, the sample holders in the Tier-S
commands, and `FROM_BLOCK`.
