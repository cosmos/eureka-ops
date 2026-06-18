# Safe signer checklist — v3 upgrade

For every transaction: **run one command → match the hash to the table and your Ledger → sign.** Nothing
is signed until you approve on the Ledger.

- **Governance signers** (Safe `0x7B96CD54aA750EF83ca90eA487e0bA321707559a`): sign **each** of nonces
  **18–25** (any order), then **one** execute (nonce 26) ~3 days later.
- **Customizer signers** (Safe `0x4b46ea82D80825CA5640301f47C035942e6D9A46`): sign **one** tx, **last** —
  see the box before *Each transaction*.

> ## ⛔ Do NOT sign unless the command ends with a single `PASS` **and** `echo $?` prints `0`.
> Any `REJECT` or `STOP`, more than one tx at the nonce, a non-zero exit, or a hash that doesn't match →
> **don't sign** (a `STOP` next to a `PASS` still means stop). Screenshot it, report over the trusted
> channel, and wait for an all-clear before any signer signs.

> **Customizer signers — your whole job:** sign **one** tx (`addIBCApp`), **last**, after the governance
> execute has landed. Sign *from* Safe `0x4b46ea82…`; it targets ICS26Router
> `0x3aF134307D5Ee90faa2ba9Cdba14ba66414CF1A7` (that's the `to`, **never** your `SAFE_ADDRESS`);
> operation **CALL**, no `--expect-subcalls`. Your row is a placeholder until the coordinator posts a real
> nonce + hash — until then sign nothing. Rows 18–26 aren't yours.

## Each transaction

1. **Open your Safe** (pinned link → confirm it says **Ethereum**, address matches): gov
   [queue](https://app.safe.global/transactions/queue?safe=eth:0x7B96CD54aA750EF83ca90eA487e0bA321707559a) ·
   cust [queue](https://app.safe.global/transactions/queue?safe=eth:0x4b46ea82D80825CA5640301f47C035942e6D9A46).
   Note the **nonce**. If it isn't a table row with a real `0x…` hash (not a `‹…›` placeholder) → **stop & report**.
2. **Verify** — paste the nonce and that row's hash **from the table** (for nonce 26 add `--expect-subcalls 8`):
   ```bash
   bash ~/signer-verify.sh 1 <YOUR_SAFE> <NONCE> --expect <HASH_FROM_TABLE>
   ```
   `1` = mainnet (leave it). `<YOUR_SAFE>` is the Safe you sign *from*, not the `to`. Always pass `--expect`,
   taken **from the table — never from the Safe UI**. *"Can't reach the Safe service"* → add `SAFE_API_KEY=<key>`,
   or use manual mode (bottom).
3. **`PASS` + exit `0`?** → continue. Anything else → **stop & report** (see the box above).
4. **Match the hash** in two independent places: the script's `safeTxHash` == the **Safe UI → Advanced
   details** hash; and on your **Ledger**, the **Domain hash + Message hash** == the script's
   `domainHash:` / `messageHash:` lines (the Ledger shows those two, *not* the safeTxHash). Compare all 64 chars.
5. **Both match → sign.** Mismatch → **reject on the device** and report. (Clicking *Sign* only brings up the
   hashes; rejecting on the Ledger signs nothing — safe to inspect.)

## Table  *(one row = one nonce; never sign a nonce not listed here with a real `0x…` hash — a `‹…›` placeholder means "wait for the coordinator")*

| nonce | Safe | to | op | action | expected safeTxHash |
| --- | --- | --- | --- | --- | --- |
| 18 | gov | `0xb3999B2D…` timelock | CALL | schedule ICS20Transfer upgrade | `0x0fde583fd53e0befd17de9441c964d1d65199327054a2b31088326fab253f2df` |
| 19 | gov | `0xb3999B2D…` timelock | CALL | schedule ICS26Router upgrade | `0x431e686b5bbd6670fe90ff5a07c6af0f51ace9a999dd3a3f8341530b8129bb27` |
| 20 | gov | `0xb3999B2D…` timelock | CALL | schedule Escrow upgrade | `0x89042ea55322d08457009db3cb34e42bc048863f7fcfec93add5e436411dccac` |
| 21 | gov | `0xb3999B2D…` timelock | CALL | schedule IBCERC20 upgrade | `0x48642c35f6572b6538b0954c6eacf3df9e98a72c0ce41898c6696c92fdf8bc63` |
| 22 | gov | `0xb3999B2D…` timelock | CALL | schedule migrate cosmoshub-0 | `0x01fdcf1f39e4d02979ad9806c7def549089966dbb7651204eb9429f3d4cb35aa` |
| 23 | gov | `0xb3999B2D…` timelock | CALL | schedule migrate ledger-mainnet-1 | `0x898b498f66e4a57e8969c7e9f137bad23ecb4e9fbed6b6da6c99757c1290502e` |
| 24 | gov | `0xb3999B2D…` timelock | CALL | schedule grant rate-limiter (role 5) → `0x4b46ea82…` on cosmoshub-0 escrow `0x0fA75C2c…` | `0x2a0bca9f92e06eab69c72333e9285f443f6a6359372746d634bbd9aef3ca6c58` |
| 25 | gov | `0xb3999B2D…` timelock | CALL | schedule grant rate-limiter (role 5) → `0x4b46ea82…` on ledger-mainnet-1 escrow `0xC76944B0…` | `0x1335e17eb41acdcbb4b7981323896581f9caa175ee05bd9f24b74fa8674eb8c7` |
| 26* | gov | `0x9641d764…` MultiSendCallOnly | **DELEGATECALL** | **atomic execute (step 7), `--expect-subcalls 8`** | `0x…` ‹fill at Phase C› |
| ‹Y› | cust | `0x3aF13430…` ICS26Router | CALL | addIBCApp gmpport (step 8) | `0x…` ‹fill at Phase D› |

\* Nonce 26 lands only if 18–25 all executed and nothing else was queued; the coordinator confirms the live
nonce + fills the hash at Phase C. Ignore the script's extra `operationId` / `new impl` / `multicall` lines —
they're already baked into the hash you check.

## Setup (once, then ignore)

- **Foundry:** `curl -L https://foundry.paradigm.xyz | bash`, then **open a new terminal** (or `source ~/.bashrc`),
  run `foundryup`, check `cast --version`. Also install **`jq` + `curl`** (mac `brew install jq`; Ubuntu/WSL
  `sudo apt-get install -y jq curl`).
- **Get `signer-verify.sh`** from the trusted channel as a **file** (don't paste it into an editor — that
  changes the bytes), then `sha256sum ~/signer-verify.sh` (mac: `shasum -a 256`) must equal — all 64 chars —
  `7158537ec891c61159dba2aae180331b35266c9cdc4de13b797e48123b5f5bb0`. Mismatch → don't use it. Cross-check
  this digest (and a couple of table hashes) against a **second source** (signed git tag / another owner).
- **Ledger:** enable **Blind signing** (older firmware: "Allow contract data") and update the app, or it
  can't show the hashes. Confirm your address is a Safe owner (Safe UI → Settings → Owners).
- **Windows:** do everything in **WSL/Ubuntu** (`wsl --install`). A browser download sits at
  `/mnt/c/Users/<you>/Downloads/` → `cp … ~/`; check `file ~/signer-verify.sh` says `ASCII text` (not CRLF).
  Paste long values in **Windows Terminal** with **Ctrl+Shift+V**, no trailing space. If fetch fails oddly,
  check `date` is correct (`sudo hwclock -s`).

## Manual mode (only if the Safe service is unreachable)

Copy `to`, `Operation`, `data (0x…)` from the Safe UI → Advanced details:
```bash
bash ~/signer-verify.sh 1 <YOUR_SAFE> --to <TO> --operation <0|1> --data <0xDATA> --nonce <NONCE> --expect <HASH_FROM_TABLE>
```
`--expect` still comes **from the table, never the UI** (the UI's own hash always "matches" — it proves
nothing). The Ledger Domain+Message check (step 4) is **required** here. For nonce 26 also add
`--expect-subcalls 8`; for its huge `data`, save it to a file and pass `--data "$(cat ~/step7.hex)"`.

---
*Coordinator: generation/distribution in [`CUTOVER-RUNSHEET.md`](CUTOVER-RUNSHEET.md); authoritative
per-nonce hashes in [`COORDINATOR-HASH-TABLE.md`](COORDINATOR-HASH-TABLE.md).*
