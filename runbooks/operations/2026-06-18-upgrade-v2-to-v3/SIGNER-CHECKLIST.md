# Safe signer checklist — v3 upgrade (schedule round)

You're signing the **8 scheduling transactions, nonces 18–25**, on the governance Safe
`0x7B96CD54aA750EF83ca90eA487e0bA321707559a` — **one signature each, in any order.** For each:
**run one command → it prints the values to expect → confirm your Safe UI + Ledger match them → sign.**
The command runs **offline** (only `cast`, no network); nothing is signed until you approve on the Ledger.

> ## ⛔ Do NOT sign unless **both** are true
> 1. the command ends with a single `PASS` and `echo $?` prints `0`; **and**
> 2. your Safe UI + Ledger match the printed card **exactly**.
>
> Any `REJECT`, a non-zero exit, a `to`/`operation`/`data`/hash in the UI or on the Ledger that doesn't
> match the card, or **more than one transaction at the nonce** → **don't sign.** Screenshot it, report
> over the trusted channel, and wait for an all-clear before any signer signs.

## Each transaction

1. **Open the Safe** (pinned link → confirm it says **Ethereum** and the address matches):
   [queue](https://app.safe.global/transactions/queue?safe=eth:0x7B96CD54aA750EF83ca90eA487e0bA321707559a).
   Note the **nonce**. If it isn't one of the rows below (18–25) → **stop & report**.
2. **Generate the expected card** — just the nonce:
   ```bash
   bash ~/signer-verify.sh <NONCE>
   ```
   The script reads that nonce's published payload from `COORDINATOR-HASH-TABLE.md` (keep it in the same
   folder), recomputes the hashes **offline**, and prints exactly what you should see. No network, no hash
   to paste.
3. **`PASS` + exit `0`?** → continue. Anything else → **stop & report** (see the box above).
4. **Confirm your Safe UI + Ledger match the card.** Open the pending tx → **Advanced details** and check
   `to` / `operation` / `data` / `safeTxHash` equal the card's. When you click **Sign**, your **Ledger**
   shows a **Domain hash + Message hash** (not the safeTxHash) — confirm both equal the card's
   `domainHash:` / `messageHash:`. Compare whole 64-character values, not just the ends.
5. **All match → sign.** Any mismatch → **reject on the device** and report. (Clicking *Sign* only brings up
   the hashes; rejecting on the Ledger signs nothing — safe to inspect.)

Every tx this round is a **CALL to the timelock** `0xb3999B2D…`. The script recomputes each hash from the
published payload and checks it against the published `safeTxHash`, so a tampered payload prints `REJECT`
— **trust a `REJECT`.**

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

The card also prints reference lines (`operationId` / `new impl` / `multicall`) — informational, already
bound by the `safeTxHash`; you don't need to chase them.

## Setup (once, then ignore)

- **Get both files** from the trusted channel and **keep them in the same folder** (`~/`):
  `signer-verify.sh` and `COORDINATOR-HASH-TABLE.md`. Get them as **files** (don't paste into an editor —
  that changes the bytes), then verify both digests — all 64 chars, mismatch → don't use it:
  ```bash
  sha256sum ~/signer-verify.sh ~/COORDINATOR-HASH-TABLE.md     # macOS: shasum -a 256
  ```
  ```
  b3f66119bb7481acfb28e9fb6cb13a8fa073c71543ca5d5f800f79472f7fb302  signer-verify.sh
  59bcf738e7035edf2ce4117fb3544e0fac53bfd1a4fb7f425b518f93a15efab9  COORDINATOR-HASH-TABLE.md
  ```
  Cross-check both digests (and a couple of table hashes) against a **second source** (signed git tag /
  another owner) — the table now drives the verification, so its integrity matters as much as the script's.
- **Foundry (for `cast`):** `curl -L https://foundry.paradigm.xyz | bash`, then **open a new terminal**
  (or `source ~/.bashrc`), run `foundryup`, check `cast --version`. `cast` is the only tool needed — no
  `jq`, no network.
- **Ledger:** enable **Blind signing** (older firmware: "Allow contract data") and update the app, or it
  can't show the hashes. Confirm your address is a Safe owner (Safe UI → Settings → Owners).
- **Windows:** do everything in **WSL/Ubuntu** (`wsl --install`). Browser downloads land at
  `/mnt/c/Users/<you>/Downloads/` → `cp … ~/`; check `file ~/signer-verify.sh` says `ASCII text` (not CRLF).

## If the script can't find the table

Point it at the file (keep them together to avoid this): `bash ~/signer-verify.sh <NONCE> --table ~/COORDINATOR-HASH-TABLE.md`.
Deeper fallback — paste your nonce's row fields **from the table** (never the Safe UI):
```bash
bash ~/signer-verify.sh --to <TO> --operation <0|1> --data <0xDATA> --nonce <NONCE> --expect <SAFETXHASH>
```

---
*This round is the 8 schedules only. The atomic **execute** (~3 days later) and the **customizer**
registration are separate rounds with their own instructions — nothing to do for them now.*
*Coordinator: authoritative per-nonce hashes + payloads in [`COORDINATOR-HASH-TABLE.md`](COORDINATOR-HASH-TABLE.md).*
