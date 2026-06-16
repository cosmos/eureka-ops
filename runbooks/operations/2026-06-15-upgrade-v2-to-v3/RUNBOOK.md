# Operation: solidity-ibc-eureka v2 → v3 upgrade (incl. SP1 v6.1)

> This folder was seeded with a point-in-time copy of the procedure by `just new-operation`. That
> copy went stale: the canonical runbook was substantially revised **during** this operation
> (single-round `EXTRA_TIMELOCK_OPS` folding of the rate-limiter re-grant into the atomic step-7
> execute, the `propose-schedule`/decode/`safeTxHash` verification workflow, the
> `discover-v2-roles.py` pre-cutover grant discovery, and step 13 role validation). To avoid a
> reader following a stale procedure, this file now defers to the single source of truth.

## Procedure — follow this, not a copy

➡️ **[`../../upgrade-v2-to-v3.md`](../../upgrade-v2-to-v3.md)** — the canonical, current step-by-step
(context, shadow-fork rehearsal, steps 1–13). It is kept up to date; always follow it directly.

➡️ **[`../../post-upgrade-role-testing.md`](../../post-upgrade-role-testing.md)** — post-cutover role
validation & testing (read its *Mainnet adaptation* section before running anything on mainnet).

## Operation record

➡️ **[`RECORD.md`](RECORD.md)** — the durable record for this operation: testnet execution record
(addresses, tx hashes, Safe nonces, SP1 v6.1 details), the confirmed mainnet pre-upgrade state, the
authoritative mainnet pre-cutover grant set & token audit, notable findings, and the mainnet
execution-record placeholder to fill at cutover.
