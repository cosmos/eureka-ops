# Safe signer checklist — v3 upgrade (execute / cutover round)

How to **validate** the single execute transaction (nonce **26**) on the governance Safe `0x7B96CD54aA750EF83ca90eA487e0bA321707559a` before you approve it. This is the **one atomic transaction that applies the whole v2→v3 cutover** — the schedules you validated earlier (nonces 18–25) only *queued* it. **Run one command — it prints the values this transaction must have — and confirm they match.** Validation runs **offline** (only `cast`): the command reads the published payload from the repo and recomputes every value itself.

> ## ⛔ This transaction validates only if **both** are true
> 1. the command ends with a single `PASS` and `echo $?` prints `0`; **and**
> 2. every value it prints matches what the transaction shows (Safe UI → Advanced details, and the hashes your signing device displays).
>
> Any `REJECT`, a non-zero exit, a `to`/`operation`/`data`/hash that doesn't match, **a sub-call count other than 8**, or **more than one transaction at nonce 26** → it does **not** validate. Don't approve it.

## This round is different from the schedule round — read this first

- It is **one** transaction at **nonce 26**, not eight.
- Its **`operation` is `DELEGATECALL (1)`** and its **`to` is `MultiSendCallOnly` `0x9641d764…8102e2`** — **not** a `CALL` to the timelock. That is expected: this transaction batches **8 timelock `execute(...)` calls** (the 4 upgrades + 2 client migrations + 2 rate-limiter grants you already scheduled) into one atomic cutover. The validator enforces both: it **rejects** a `DELEGATECALL` to anything other than MultiSendCallOnly, and **rejects unless there are exactly 8** sub-calls, each a timelock `execute()`.
- This is the **irreversible** step — it applies the upgrade. (The schedules were cancellable; this is the commit.)

## Validate the transaction

1. In the Safe, open the pending transaction and confirm it is **nonce 26** (network **Ethereum**, Safe address matches). If it isn't nonce 26 → **stop**. Pinned: [queue](https://app.safe.global/transactions/queue?safe=eth:0x7B96CD54aA750EF83ca90eA487e0bA321707559a).
2. From the repo root, run — **note the required flag**:
   ```bash
   bash scripts/signer-verify.sh 26 --expect-subcalls 8
   ```
   It reads the published payload from the repo, recomputes the hashes **offline**, decodes all 8 sub-calls, and prints exactly what the transaction must contain.
3. **`PASS` + exit `0`?** → continue. Anything else → **stop**.
4. **Confirm the transaction matches the card:**
   - Safe UI → **Advanced details**: `to` (`0x9641d764…`), `operation` (**DelegateCall**), `data`, and `safeTxHash` equal the card's.
   - Your signing device displays a **Domain hash + Message hash** (not the safeTxHash) — both equal the card's `domainHash:` / `messageHash:`.

   Compare whole 64-character values, not just the ends. Your device will show `To = MultiSendCallOnly` and a long data blob — that is correct for a batched execute; the on-device Domain/Message hashes are what bind it.
5. **Everything matches → it's the expected transaction.** Any mismatch → it isn't; don't approve it.

The script recomputes the hash from the payload in the repo and checks it against the published `safeTxHash`, and it walks every sub-call — so a tampered payload, a wrong `to`/`operation`, or a missing/extra sub-call prints `REJECT`. **Trust a `REJECT`.**

## ✋ Sign only — do **not** Execute

Approve (sign) the transaction and stop there. **The coordinator executes it**, and only after the timelock delay elapses. Do not click **Execute** yourself. Signing now is fine and expected; the cutover is applied later, by the coordinator.

## Table  *(the only nonce to approve this round)*

| nonce | to | op | action | expected safeTxHash |
| --- | --- | --- | --- | --- |
| 26 | `0x9641d764…8102e2` MultiSendCallOnly | DELEGATECALL | atomic execute — 8 timelock `execute(...)`: 4 upgrades + 2 migrations + 2 rate-limiter grants | `0xe999dee7ac3a0a003383efb2fa45c9b8105ef8c21ab8322dcd9371173f0a637a` |

## Setup (once)

- **Check out the repo** on the branch the coordinator gives you, then run from its root:
  ```bash
  git clone git@github.com:cosmos/eureka-ops.git && cd eureka-ops && git checkout operations/2026-06-18-upgrade-v2-to-v3
  ```
  Checking out that branch is how you trust the script + table — git verifies the file contents, so there's nothing to download or sha256 separately.
- **Install Foundry (for `cast`):** `curl -L https://foundry.paradigm.xyz | bash`, then open a new terminal, run `foundryup`, and check `cast --version`. `cast` is the only tool the validator needs.

If the script can't find the table (you're running it outside the repo), point it at the file: `bash scripts/signer-verify.sh 26 --expect-subcalls 8 --table runbooks/operations/2026-06-18-upgrade-v2-to-v3/COORDINATOR-HASH-TABLE.md`.

---
*This validates the single execute transaction only (nonce 26). The 8 schedule transactions (18–25) have their own checklist: [`SIGNER-CHECKLIST.md`](SIGNER-CHECKLIST.md). Authoritative hash + payload: [`COORDINATOR-HASH-TABLE.md`](COORDINATOR-HASH-TABLE.md).*
