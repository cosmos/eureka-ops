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
new-operation operation environment chain base=`git branch --show-current`:
    #!/bin/bash
    set -euo pipefail

    if ! test -f runbooks/{{operation}}.md; then
        echo "{{operation}} is not a valid operation"; exit 1;
    fi

    operation_name="{{ datetime('%Y-%m-%d') }}-{{operation}}"
    dir="runbooks/operations/$operation_name"
    # Cut the operation from `base`, which defaults to the branch you're on. Operations are normally run from
    # main, but during a transition the tooling/runbook may live on a not-yet-merged branch (e.g. the v3
    # upgrade can't merge to main until mainnet is upgraded) -- run new-operation from that branch and it cuts
    # from there. The `runbooks/{{operation}}.md` check above already guarantees the runbook exists on `base`.
    git checkout {{base}}

    # git pull origin {{base}}
    git checkout -b operations/$operation_name

    mkdir $dir
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
