## RUNBOOK - pausing transfers

### Roles

| Role         | Person |
|--------------|--------|
| Facilitator  |        |
| Communicator |        |

### Runbook

1. As soon as a signer or facilitator notices an issue, they should run `just ops-pause-transfers` with the target environment and chain set in `.eureka-env` (`EUREKA_ENVIRONMENT`, `EUREKA_CHAIN`, `ETH_RPC`). The signer must hold `PAUSER_ROLE` on the AccessManager; the call broadcasts immediately and is not timelocked.
2. The signer or facilitator who paused the protocol shoud page the security council and protocol maintainers AS SOON AS POSSIBLE, raising a possible security incident.
3. The facilitators and/or protocol maintainers will start a warroom to triage the security incident and consider further patches or a prolonged pause period to safeguard against possible value loss.
4. Once the incident is resolved and it is safe to resume, an `UNPAUSER_ROLE` holder runs `just ops-unpause-transfers` (same `.eureka-env` configuration).