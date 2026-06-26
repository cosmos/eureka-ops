# Proof-api failure mode: `Program simulation failed` (`/dev/shm` exhaustion)

*Recorded 2026-06-17. Applies to the `relayer-api` / proof-api (`ghcr.io/cosmos/proof-api`),
SP1 `v2.0.0` programs, `sp1-sdk 6.1.0`, network/reserved prover. Fix: [ibc-manifests#91](https://github.com/skip-mev/ibc-manifests/pull/91).*

## TL;DR

The proof-api panics with **`proving failed: Program simulation failed`** when asked to prove for a
**large source chain** (Cosmos Hub, `cosmoshub-4`), while small testnet chains succeed. Real transfers on
that path do not relay.

**Root cause:** the SP1 *native* executor streams its execution trace through a shared-memory ring buffer
in **`/dev/shm`**. Kubernetes defaults `/dev/shm` to **64 MiB**. A single `cosmoshub-4` proof needs
**~63 MiB** of `/dev/shm` — right at the limit — so it overflows under any concurrency, the executor child
process dies, and **sp1-sdk discards the real error** (`map_err(|_| SimulationFailed)`), leaving only the
generic "Program simulation failed". RAM and CPU are *not* the bottleneck — `/dev/shm` is a separate tmpfs.

**Fix:** mount a larger RAM-backed `/dev/shm` (an `emptyDir` with `medium: Memory`, e.g. `2Gi`).

## Symptom

- Per request, the proof-api logs:
  ```
  Handling update client request for Cosmos to Eth...
  requesting proof from network, mode: Groth16
  thread 'tokio-rt-worker' panicked at packages/sp1-ics07-tendermint-prover/src/prover.rs:100:
  proving failed: Program simulation failed
  ```
  (gRPC clients see `RST_STREAM / CANCEL` because the handler task panics.)
- It is **path/size dependent**: `cosmoshub-4 → 1` fails; small testnet sources (`provider`,
  `localnet`, `ledger-testnet-1` → sepolia) pass the same step. `RelayByTx` (recvPacket/membership) for a
  real transfer fails the same way.
- **Misleading signals:** the pod's RAM is nearly idle (e.g. 180 MiB of a 20 GiB limit), CPU has headroom,
  there are **no OOMKills / restarts**, and the failure is *fast*. None of that points at `/dev/shm`.

## Root cause

The deployed image runs the SP1 **native** executor (Linux `x86_64`). For cycle/gas estimation —
which `sp1-sdk` always runs locally *before* sending the proof request to the network — it spawns a child
process and exchanges the execution trace via a **shared-memory ring buffer in `/dev/shm`**:

- `sp1-core-executor-runner-6.1.0/src/native.rs`:
  - `create(...)` → `ShmTraceRing::create(...)` (`.expect("create shm file for traces")`) allocates the
    trace buffer in `/dev/shm`.
  - On child death it returns `ExecutionError::TooMuchMemory()` (on `SIGKILL`) or `…::Other(...)`, and warns
    (line ~217): `"SIGBUS signal is received, there is a chance /dev/shm is full!"`.
- `sp1-sdk-6.1.0/src/network/prover.rs` (`get_execution_limits`, ~line 784):
  ```rust
  self.node.execute(elf, stdin, SP1Context::builder().calculate_gas(true).build())
      .await
      .map_err(|_| Error::SimulationFailed)?;   // <-- discards the real ExecutionError
  ```
  The `map_err(|_| …)` is why the real reason (OOM/SIGBUS/shm-full) never reaches the logs.
- `packages/sp1-ics07-tendermint-prover/src/prover.rs:100` (the eureka wrapper) then `.expect("proving
  failed")`s the `SimulationFailed`, producing the panic.

The trace buffer size scales with the program's work. **`cosmoshub-4`** (mainnet, ~180 validators, ~7.44M
cycles per update-client/membership proof) needs **~63 MiB** of `/dev/shm`. The Kubernetes default of
**64 MiB** is therefore marginal for a *single* proof and is exceeded by **any concurrency** (the long-lived
proof-api shares one prover across many concurrent requests). Small testnet chains have tiny validator sets
→ small traces → they fit.

## How to diagnose / confirm

```bash
POD=<relayer-api pod>

# 1. /dev/shm size — 64M default is the smoking gun
kubectl -n ibc exec $POD -- df -h /dev/shm        # -> "shm 64.0M ... /dev/shm"

# 2. Watch /dev/shm fill while firing the failing path
kubectl -n ibc exec $POD -- sh -c \
  'p=0; for i in $(seq 1 80); do u=$(df -k /dev/shm|awk "NR==2{print \$3}"); [ "$u" -gt "$p" ]&&p=$u; sleep .5; done; echo "peak ${p}KB/65536KB"' &
# ... fire a cosmoshub-4 UpdateClient/RelayByTx at the proof-api ...
# Observed: peaks at ~62000-63880 KB of 65536 KB, then "Program simulation failed".

# 3. The real (swallowed) error string lives in the executor, not the proof-api:
#    sp1-core-executor-runner .../native.rs: "SIGBUS ... /dev/shm is full!"
```

Confirming it is **not** the prover/programs/inputs: run the operator binary *inside the same pod* in
isolation (`/usr/local/bin/operator fixtures update-client --private-cluster ...`). It succeeds — a single
execution *just* fits 64 MiB — proving the stack is sound and the failure is `/dev/shm` capacity under load.

## Measured evidence

| `/dev/shm` | scenario | `/dev/shm` peak | result |
| --- | --- | --- | --- |
| 64 MiB | 1× cosmoshub-4 | 63.9 MiB / 64 MiB | **fail** (`Program simulation failed`) |
| 64 MiB | 3× concurrent cosmoshub-4 | ~62 MiB / 64 MiB | **all fail**, 0 reach the cluster |
| 2 GiB | 2× concurrent (in-pod operator) | **94 MiB** | both **succeed** (reach cluster) |
| 2 GiB | 3× concurrent (deployed proof-api) | — | **3 `Created request`, 0 `simulation failed`** |

## The fix

Back `/dev/shm` with a larger RAM-backed volume — [ibc-manifests#91](https://github.com/skip-mev/ibc-manifests/pull/91)
(`relayer-api/templates/relayer/rollout.yaml`, commit `cb8040b`):

```yaml
spec:
  template:
    spec:
      volumes:
        - name: dshm
          emptyDir:
            medium: Memory
            sizeLimit: {{ .Values.relayer.rollout.dshmSize | default "2Gi" }}
      containers:
        - name: relayer-api
          volumeMounts:
            - name: dshm
              mountPath: /dev/shm
```

Notes:
- A `medium: Memory` emptyDir is a tmpfs counted against the **container memory limit** (already 10–20 GiB),
  so 2 GiB is well within budget. Tune via `relayer.rollout.dshmSize`.
- It is in the **shared template**, so prod gets it too.
- Resizing `/dev/shm` requires a pod restart (the value is fixed at mount time).

## Why it was hard to find

1. The real error is **thrown away** by sp1-sdk (`map_err(|_| SimulationFailed)`) — only a generic string
   surfaces.
2. The obvious resources look fine: **RAM idle, CPU spare, no OOMKills** — because `/dev/shm` is a separate
   tmpfs that doesn't show up as container memory pressure.
3. It is **size/concurrency dependent**, so it looks chain-specific ("mainnet fails, testnet works") rather
   than like a capacity limit.

## Follow-ups (not blockers)

- **Upstream (SP1):** `get_execution_limits` should not `map_err(|_| SimulationFailed)` — propagating /
  logging the underlying `ExecutionError` (`TooMuchMemory`, SIGBUS/shm-full) would make this self-evident.
  Worth filing.
- **Entrypoint robustness:** the relayer entrypoint `wget`s the four ELFs from GitHub on every start and can
  stall under rapid restarts; a retry/backoff (or baking the ELFs into the image) would harden startup.
- **Capacity planning:** if more / larger source chains are added, scale `dshmSize` accordingly (budget
  roughly ≥ ~64 MiB × expected concurrent proofs of the largest chain).
