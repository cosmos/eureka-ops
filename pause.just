# Emergency pause / unpause of ICS20Transfer for the environment + chain configured in .eureka-env.
#
# Both broadcast a single transaction from the local wallet (PRIVATE_KEY or --ledger via SENDER), so the
# signer must already hold PAUSER_ROLE (pause) or UNPAUSER_ROLE (unpause) on the AccessManager. Pausing is a
# direct AccessManager-gated call rather than a timelocked operation, so it takes effect immediately.

[group('ops')]
[doc('Emergency-pauses ICS20Transfer on the configured environment+chain (signer must hold PAUSER_ROLE)')]
ops-pause-transfers: (ops-script "PauseTransfers" _broadcast_flags)

[group('ops')]
[doc('Unpauses ICS20Transfer on the configured environment+chain (signer must hold UNPAUSER_ROLE)')]
ops-unpause-transfers: (ops-script "UnpauseTransfers" _broadcast_flags)
