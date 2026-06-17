# Safe signer checklist — v3 upgrade

You sign in the **Safe web UI**. Your whole job per transaction: **run one command, check the hash matches
in 3 places, sign.** ~2 min each. You'll do this twice — a batch of "schedule" txs now, one "execute" ~3 days later.

> **If the command prints anything but `PASS`, or a hash doesn't match → DO NOT SIGN.**
> Screenshot it and message **‹coordinator + channel›** so all signers hold.

## Each transaction

1. In the Safe UI, open the pending tx; note its **nonce** (network must be **Ethereum**).
2. Run this — paste the **nonce** and that row's **expected hash** from the table below:
   ```bash
   bash ~/signer-verify.sh 1 ‹SAFE_ADDRESS› ‹NONCE› --expect ‹EXPECTED_SAFETXHASH›
   ```
   Governance Safe `0x7B96CD54aA750EF83ca90eA487e0bA321707559a` · Customizer Safe (step 8) `0x4b46ea82D80825CA5640301f47C035942e6D9A46`
3. **`REJECT` or any warning → stop, report.  `PASS` → continue.**
4. Confirm the **safeTxHash** the script printed is identical in **both** places:
   - the Safe UI → **Advanced details**, and
   - your **hardware wallet** screen when you start signing (a Ledger shows **DomainHash + MessageHash** — match
     both; the script prints those too). Compare the **whole** value.
5. All three match → **sign in the Safe UI.**  Any mismatch → **reject on the device** and report.

That's the whole job. The script independently recomputes the hash and decodes what the tx does, so a tampered
UI shows up as "UI hash ≠ script hash." **Trust a `REJECT`.**

## One-time setup

- **Windows:** do everything inside **WSL (Ubuntu)**.
- Install Foundry, **open a NEW terminal**, then run `foundryup` and check `cast --version` prints a version.
  ```bash
  curl -L https://foundry.paradigm.xyz | bash      # then open a new terminal and run: foundryup
  ```
- Get `signer-verify.sh` from **‹coordinator's trusted channel›** and verify it:
  `shasum -a 256 ~/signer-verify.sh` must equal **‹SHA256›**. Mismatch → don't use it.
- `jq` is optional (only for the nonce shortcut; otherwise use manual mode below — needs just `cast`).

## Expected-values table  *(your reference — one row = one nonce; reject any pending nonce not listed)*

| nonce | Safe | to | op | action | expected safeTxHash |
| --- | --- | --- | --- | --- | --- |
| ‹N›  | gov | `0xb3999B2D…` timelock | CALL | schedule ICS20Transfer upgrade | `0x…` |
| ‹N+1›| gov | `0xb3999B2D…` timelock | CALL | schedule ICS26Router upgrade | `0x…` |
| ‹N+2›| gov | `0xb3999B2D…` timelock | CALL | schedule Escrow upgrade | `0x…` |
| ‹N+3›| gov | `0xb3999B2D…` timelock | CALL | schedule IBCERC20 upgrade | `0x…` |
| ‹N+4›| gov | `0xb3999B2D…` timelock | CALL | schedule migrate cosmoshub-0 | `0x…` |
| ‹N+5›| gov | `0xb3999B2D…` timelock | CALL | schedule migrate ledger-mainnet-1 | `0x…` |
| ‹N+6…9›| gov | `0xb3999B2D…` timelock | CALL | grant rate-limiter (one row per holder×escrow) | `0x…` |
| ‹X›  | gov | `0x9641d764…` MultiSendCallOnly | **DELEGATECALL** | **atomic upgrade execute (step 7)** | `0x…` |
| ‹Y›  | cust | `0x3aF13430…` ICS26Router | CALL | addIBCApp gmpport (step 8) | `0x…` |

The **step-7 execute is the only DelegateCall** (and only to `0x9641d764…`); every other tx is a **CALL**.
The script REJECTs anything else — you don't have to memorise it.

## If the script can't reach the Safe service (manual mode)

In the Safe UI → **Advanced details**, copy `to`, `Operation`, and the raw `data (Hex)` exactly (with the `0x`):
```bash
bash ~/signer-verify.sh 1 ‹SAFE_ADDRESS› --to ‹TO› --operation ‹0|1› --data ‹0xDATA› --nonce ‹NONCE› --expect ‹HASH›
```

---
*Coordinator — how to generate, double-check, and distribute the table + script is in [`CUTOVER-RUNSHEET.md`](CUTOVER-RUNSHEET.md).*
