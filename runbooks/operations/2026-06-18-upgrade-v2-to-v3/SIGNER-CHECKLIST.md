# Safe signer checklist — v3 upgrade (schedule round)

How to **validate** the 8 scheduling transactions (nonces **18–25**) on the governance Safe `0x7B96CD54aA750EF83ca90eA487e0bA321707559a` before you approve them. For each: **run one command — it prints the values that transaction must have — and confirm they match.** Validation runs **offline** (only `cast`): the command reads the published payload from the repo and recomputes every value itself.

> ## ⛔ A transaction validates only if **both** are true
> 1. the command ends with a single `PASS` and `echo $?` prints `0`; **and**
> 2. every value it prints matches what the transaction shows (Safe UI → Advanced details, and the hashes your signing device displays).
>
> Any `REJECT`, a non-zero exit, a `to`/`operation`/`data`/hash that doesn't match, or **more than one transaction at the nonce** → it does **not** validate. Don't approve it.

## Validate each transaction

1. In the Safe, open the pending transaction and note its **nonce** (confirm the network is **Ethereum** and the Safe address matches). If the nonce isn't one of the rows below (18–25) → **stop**. Pinned: [queue](https://app.safe.global/transactions/queue?safe=eth:0x7B96CD54aA750EF83ca90eA487e0bA321707559a).
2. From the repo root, run:
   ```bash
   bash scripts/signer-verify.sh <NONCE>
   ```
   It finds this operation's `COORDINATOR-HASH-TABLE.md` in the repo, recomputes the hashes **offline**, and prints exactly what that transaction must contain.
3. **`PASS` + exit `0`?** → continue. Anything else → **stop**.
4. **Confirm the transaction matches the card:**
   - Safe UI → **Advanced details**: `to` / `operation` / `data` / `safeTxHash` equal the card's.
   - Your signing device displays a **Domain hash + Message hash** (not the safeTxHash) — both equal the card's `domainHash:` / `messageHash:`.

   Compare whole 64-character values, not just the ends.
5. **Everything matches → it's the expected transaction.** Any mismatch → it isn't; don't approve it.

Every tx this round is a **CALL to the timelock** `0xb3999B2D…`. The script recomputes each hash from the payload in the repo and checks it against the published `safeTxHash`, so a tampered payload prints `REJECT` — **trust a `REJECT`.** The card also prints reference lines (`operationId` / `new impl` / `multicall`) — informational, already bound by the `safeTxHash`; you don't need to chase them.

## Table  *(one row = one nonce; never approve a nonce not listed here)*

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

## Setup (once)

- **Check out the repo** on the branch the coordinator gives you, then run from its root:
  ```bash
  git clone git@github.com:cosmos/eureka-ops.git && cd eureka-ops && git checkout operations/2026-06-18-upgrade-v2-to-v3
  ```
  Checking out that branch is how you trust the script + table — git verifies the file contents, so there's nothing to download or sha256 separately.
- **Install Foundry (for `cast`):** `curl -L https://foundry.paradigm.xyz | bash`, then open a new terminal, run `foundryup`, and check `cast --version`. `cast` is the only tool the validator needs.

If the script can't find the table (you're running it outside the repo), point it at the file: `bash scripts/signer-verify.sh <NONCE> --table runbooks/operations/2026-06-18-upgrade-v2-to-v3/COORDINATOR-HASH-TABLE.md`.

---
*This validates the 8 schedule transactions only (nonces 18–25). Authoritative per-nonce hashes + payloads: [`COORDINATOR-HASH-TABLE.md`](COORDINATOR-HASH-TABLE.md).*
