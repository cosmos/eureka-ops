# Safe signer checklist — v3 upgrade

You sign in the **Safe web UI**: **run one command, confirm the hash matches in three places, sign.** ~2 min each.
- **Governance-Safe signers:** ~8 "schedule" txs now (one signature each), then **one** "execute" ~3 days later.
- **Customizer-Safe signers:** **one** tx — the step-8 `addIBCApp`.

> **If the command prints anything but `PASS`, or a hash doesn't match → DO NOT SIGN.**
> Screenshot it and message **‹coordinator + channel›** so all signers hold.

## Each transaction

1. In the Safe UI, open the pending tx; note its **nonce** (network must be **Ethereum**).
2. Run (paste the **nonce** and that row's **expected hash** from the table). For the **step-7 execute** also add `--expect-subcalls 8`:
   ```bash
   bash ~/signer-verify.sh 1 ‹SAFE_ADDRESS› ‹NONCE› --expect ‹EXPECTED_SAFETXHASH›
   ```
   Governance Safe `0x7B96CD54aA750EF83ca90eA487e0bA321707559a` (every tx except step 8) · Customizer Safe `0x4b46ea82D80825CA5640301f47C035942e6D9A46` (step 8 only)
3. **`REJECT` or any warning → STOP, report.  `PASS` → continue.**
4. Confirm the hash matches in **three** places — the script is the source of truth:
   1. the script's printed **`safeTxHash`**;
   2. the Safe UI → **Advanced details** safeTxHash; and
   3. your **hardware wallet** when you sign — a Ledger shows **DomainHash + MessageHash** (not a single hash), so
      match **both** to the script's `domainHash:` / `messageHash:` lines. Compare whole values, not just the ends.
5. All three agree → **sign in the Safe UI.**  Any mismatch → **reject on the device** and report.

The script independently recomputes the hash, so a tampered UI shows as a mismatch. **Trust a `REJECT`.**

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
| ‹N+6›| gov | `0xb3999B2D…` timelock | CALL | grant rate-limiter — cosmoshub-0 / `0x4b46ea82…` | `0x…` |
| ‹N+7›| gov | `0xb3999B2D…` timelock | CALL | grant rate-limiter — ledger-mainnet-1 / `0x4b46ea82…` | `0x…` |
| ‹X›  | gov | `0x9641d764…` MultiSendCallOnly | **DELEGATECALL** | **atomic upgrade execute (step 7), `--expect-subcalls 8`** | `0x…` |
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
