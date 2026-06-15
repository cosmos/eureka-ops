# SP1 light-client tooling. The underlying scripts read the deployment under deployments/{{environment}}/{{chain}}.json
# and the configured ETH_RPC from .eureka-env; pass extra flags through (e.g. --version, --write, --rpc).

[group('sp1')]
[doc('Compute the SP1 program vkeys for a release (default sp1-programs-v2.0.0-rc.2) from the PUBLISHED release ELFs and optionally write them into a deployment JSON. e.g. `just sp1-vkeys --write {{environment}} {{chain}} <client_id>...`. See scripts/sp1-vkeys.sh.')]
sp1-vkeys *args:
    #!/bin/bash
    set -euo pipefail
    bash scripts/sp1-vkeys.sh {{args}}

[group('sp1')]
[doc('Check that every SP1 light client `.verifier` in deployments/{{environment}}/{{chain}}.json is the correct SP1 verifier gateway for its zk algorithm, and (if ETH_RPC is set) that the gateway routes v6.1.0 proofs to the real verifier. See scripts/check-sp1-verifier.sh.')]
check-sp1-verifier *args:
    #!/bin/bash
    set -euo pipefail
    bash scripts/check-sp1-verifier.sh {{args}}
