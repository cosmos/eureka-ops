# Safe signer checklist — v3 upgrade (schedule round)

You're signing the **8 scheduling transactions, nonces 18–25**, on the governance Safe
`0x7B96CD54aA750EF83ca90eA487e0bA321707559a` — **one signature each, in any order.** For each:
**run one command → match the hash to the table and your Ledger → sign.** Nothing is signed until you
approve on the Ledger.

> ## ⛔ Do NOT sign unless the command ends with a single `PASS` **and** `echo $?` prints `0`.
> Any `REJECT` or `STOP`, more than one tx at the nonce, a non-zero exit, or a hash that doesn't match →
> **don't sign** (a `STOP` next to a `PASS` still means stop). Screenshot it, report over the trusted
> channel, and wait for an all-clear before any signer signs.

## Each transaction

1. **Open the Safe** (pinned link → confirm it says **Ethereum** and the address matches):
   [queue](https://app.safe.global/transactions/queue?safe=eth:0x7B96CD54aA750EF83ca90eA487e0bA321707559a).
   Note the **nonce**. If it isn't one of the rows below (18–25) → **stop & report**.
2. **Verify** — paste the nonce and that row's hash **from the table**:
   ```bash
   bash ~/signer-verify.sh 1 0x7B96CD54aA750EF83ca90eA487e0bA321707559a <NONCE> --expect <HASH_FROM_TABLE>
   ```
   `1` = mainnet (leave it). Always pass `--expect`, taken **from the table — never from the Safe UI**.
   *"Can't reach the Safe service"* → add `SAFE_API_KEY=<key>`, or use manual mode (bottom).
3. **`PASS` + exit `0`?** → continue. Anything else → **stop & report** (see the box above).
4. **Match the hash** in two independent places: the script's `safeTxHash` == the **Safe UI → Advanced
   details** hash; and on your **Ledger**, the **Domain hash + Message hash** == the script's
   `domainHash:` / `messageHash:` lines (the Ledger shows those two, *not* the safeTxHash). Compare all 64 chars.
5. **Both match → sign.** Mismatch → **reject on the device** and report. (Clicking *Sign* only brings up the
   hashes; rejecting on the Ledger signs nothing — safe to inspect.)

Every tx this round is a **CALL to the timelock** `0xb3999B2D…`. The script recomputes the hash from the
payload and compares it to the **table** value you supply, so a tampered UI shows as a `REJECT` — **trust a
`REJECT`.**

## Table  *(one row = one nonce; never sign a nonce not listed here)*

| nonce | to | op | action | expected safeTxHash |
| --- | --- | --- | --- | --- |
| 18 | `0xb3999B2D…` timelock | CALL | schedule ICS20Transfer upgrade | `0x0fde583fd53e0befd17de9441c964d1d65199327054a2b31088326fab253f2df` |
| 19 | `0xb3999B2D…` timelock | CALL | schedule ICS26Router upgrade | `0x431e686b5bbd6670fe90ff5a07c6af0f51ace9a999dd3a3f8341530b8129bb27` |
| 20 | `0xb3999B2D…` timelock | CALL | schedule Escrow upgrade | `0x89042ea55322d08457009db3cb34e42bc048863f7fcfec93add5e436411dccac` |
| 21 | `0xb3999B2D…` timelock | CALL | schedule IBCERC20 upgrade | `0x48642c35f6572b6538b0954c6eacf3df9e98a72c0ce41898c6696c92fdf8bc63` |
| 22 | `0xb3999B2D…` timelock | CALL | schedule migrate cosmoshub-0 | `0x01fdcf1f39e4d02979ad9806c7def549089966dbb7651204eb9429f3d4cb35aa` |
| 23 | `0xb3999B2D…` timelock | CALL | schedule migrate ledger-mainnet-1 | `0x898b498f66e4a57e8969c7e9f137bad23ecb4e9fbed6b6da6c99757c1290502e` |
| 24 | `0xb3999B2D…` timelock | CALL | schedule grant rate-limiter (role 5) → `0x4b46ea82…` on cosmoshub-0 escrow `0x0fA75C2c…` | `0x2a0bca9f92e06eab69c72333e9285f443f6a6359372746d634bbd9aef3ca6c58` |
| 25 | `0xb3999B2D…` timelock | CALL | schedule grant rate-limiter (role 5) → `0x4b46ea82…` on ledger-mainnet-1 escrow `0xC76944B0…` | `0x1335e17eb41acdcbb4b7981323896581f9caa175ee05bd9f24b74fa8674eb8c7` |

Ignore the script's extra `operationId` / `new impl` / `multicall` lines — they're already baked into the
hash you check. (For nonces 24/25 the script stops decoding at `multicall` and won't show role 5 or the
escrow — that's expected.)

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
bash ~/signer-verify.sh 1 0x7B96CD54aA750EF83ca90eA487e0bA321707559a --to <TO> --operation <0|1> --data <0xDATA> --nonce <NONCE> --expect <HASH_FROM_TABLE>
```
`--expect` still comes **from the table, never the UI** (the UI's own hash always "matches" — it proves
nothing). The Ledger Domain + Message hash check (step 4) is **required** here.

---
*This round is the 8 schedules only. The atomic **execute** (~3 days later) and the **customizer**
registration are separate rounds with their own instructions — nothing to do for them now.*
*Coordinator: generation/distribution in [`CUTOVER-RUNSHEET.md`](CUTOVER-RUNSHEET.md); authoritative
per-nonce hashes in [`COORDINATOR-HASH-TABLE.md`](COORDINATOR-HASH-TABLE.md).*
