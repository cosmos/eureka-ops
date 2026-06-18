# Signer instructions — later rounds (NOT for distribution yet)

> **Do not hand these out now.** Signers only ever validate what they sign in the current round. This
> file parks the wording for the two later rounds so it's ready; distribute the relevant section (as its
> own one-round document) when that round opens.
>
> **Setup and the per-transaction procedure (steps 1–5, the ⛔ rule, manual mode) are identical to**
> [`SIGNER-CHECKLIST.md`](SIGNER-CHECKLIST.md) — only the round-specific deltas below differ.

---

## Round 2 — the atomic execute (governance Safe, ~3 days after the schedules)

One transaction on the governance Safe `0x7B96CD54aA750EF83ca90eA487e0bA321707559a`. Unlike the schedules,
it is a **DELEGATECALL** to **MultiSendCallOnly `0x9641d764fc13c8B624c04430C7356C1C7C8102e2`**, and the
verify command **must add `--expect-subcalls 8`** (4 core + 2 migrations + 2 rate-limiter):

```bash
bash ~/signer-verify.sh 1 0x7B96CD54aA750EF83ca90eA487e0bA321707559a <NONCE> --expect <HASH_FROM_TABLE> --expect-subcalls 8
```

- On the Ledger / Advanced details, confirm **`to` = `0x9641d764…`** and **operation = DELEGATECALL** — this
  is the only DELEGATECALL in the whole upgrade.
- **Manual mode:** also append `--expect-subcalls 8`; the `data` is thousands of hex chars, so save it to a
  file and pass `--data "$(cat ~/round2.hex)"`.

| nonce | to | op | action | expected safeTxHash |
| --- | --- | --- | --- | --- |
| 26* | `0x9641d764…` MultiSendCallOnly | **DELEGATECALL** | atomic upgrade execute, `--expect-subcalls 8` | `0x…` ‹coordinator fills at build time› |

\* Lands at nonce **26 only if** all 8 schedules (18–25) have executed and nothing else was queued
meanwhile. The hash is **bound to the live nonce** — the coordinator builds the MultiSend, re-confirms the
on-chain nonce, and fills the `safeTxHash` immediately before this round opens.

---

## Round 3 — customizer registration (customizer Safe `0x4b46ea82…`, after the execute)

> **Customizer-Safe signers — your whole job:** sign **one** tx (`addIBCApp`). Sign *from* the Customizer
> Safe `0x4b46ea82D80825CA5640301f47C035942e6D9A46` (that's the `SAFE_ADDRESS` argument). The tx targets
> ICS26Router `0x3aF134307D5Ee90faa2ba9Cdba14ba66414CF1A7` (that's the `to`, **never** your `SAFE_ADDRESS`).
> Operation **CALL**; do **not** add `--expect-subcalls`. The script's decode must read
> `addIBCApp("gmpport", 0xbebd14A66052d7dc6BDc05e7328E4fEC0a9e3B0e)` — if the port isn't `gmpport`, the app
> isn't that address, the operation isn't CALL, or `to` isn't the ICS26Router → **do not sign**.

```bash
bash ~/signer-verify.sh 1 0x4b46ea82D80825CA5640301f47C035942e6D9A46 <NONCE> --expect <HASH_FROM_TABLE>
```

| nonce | to | op | action | expected safeTxHash |
| --- | --- | --- | --- | --- |
| ‹Y› | `0x3aF13430…` ICS26Router | CALL | addIBCApp gmpport → `0xbebd14A6…` | `0x…` ‹coordinator fills at build time› |

**Inputs are already on-chain** (ICS27GMP proxy deployed = `0xbebd14A66052d7dc6BDc05e7328E4fEC0a9e3B0e`),
so this is fully computable. At the customizer Safe's current nonce **15** the hash would be
`0xb70e5c89388e6ef15b456e49a2735b8afed868b4effecd3e8f264adc455d14a9` — **provisional only**: confirm the
live nonce (Y) the moment this round opens, since any other customizer-Safe tx in between shifts it.
