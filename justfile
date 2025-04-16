import 'consts.just'
import 'safe.just'
import 'deploy.just'
import 'upgrade.just'

set dotenv-load
set dotenv-filename := ".eureka-env"

default:
    just --list

[group('operations')]
[doc('Creates a new operation doc')]
new-operation operation environment chain:
    #!/bin/bash
    set -euo pipefail

    if ! test -f runbooks/{{operation}}.md; then
        echo "{{operation}} is not a valid operation"; exit 1;
    fi

    operation_name="{{ datetime('%Y-%m-%d') }}-{{operation}}"
    dir="runbooks/operations/$operation_name"
    git checkout main
    
    # git pull origin main
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
