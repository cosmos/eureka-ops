import 'consts.just'
import 'safe.just'
import 'deploy.just'
import 'upgrade.just'
import 'shadow.just'
import 'pause.just'
import 'sp1.just'

set dotenv-load
set dotenv-filename := ".eureka-env"

default:
    just --list

[group('operations')]
[doc('Creates a new operation doc')]
new-operation operation environment chain base="main":
    #!/bin/bash
    set -euo pipefail

    if ! test -f runbooks/{{operation}}.md; then
        echo "{{operation}} is not a valid operation"; exit 1;
    fi

    operation_name="{{ datetime('%Y-%m-%d') }}-{{operation}}"
    dir="runbooks/operations/$operation_name"
    # Operations are normally cut from main, but during a transition the tooling/runbook may live on a
    # not-yet-merged branch (e.g. the v3 upgrade can't merge to main until mainnet is upgraded). Pass that
    # branch as `base` to cut the operation from it instead.
    git checkout {{base}}

    # git pull origin {{base}}
    git checkout -b operations/$operation_name

    mkdir $dir
    # NOTE: this seeds the operation folder with a POINT-IN-TIME snapshot of the procedure. If the
    # canonical runbooks/{{operation}}.md is revised during a long-running operation, this copy goes
    # stale — keep the canonical file authoritative and have $dir/RUNBOOK.md defer to it (see
    # runbooks/operations/2026-06-15-upgrade-v2-to-v3/RUNBOOK.md for the pattern).
    cp runbooks/{{operation}}.md $dir/RUNBOOK.md
    git add $dir/RUNBOOK.md

    git commit -m "chore: start operation $operation_name"
    git push origin operations/$operation_name
    bun install

    echo "Remember to update .eureka-env with the correct environment and chain"

[group('operations')]
join-operation branch:
    git fetch
    git checkout {{branch}}

[group('operations')]
update-operation:
    git fetch
    git pull origin $(git rev-parse --abbrev-ref HEAD)
