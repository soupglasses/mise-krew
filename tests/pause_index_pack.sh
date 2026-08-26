#!/usr/bin/env bash

set -euo pipefail

pause_dir=${MISE_KREW_PAUSE_DIR:?}
git_exec_path=${MISE_KREW_GIT_EXEC_PATH:?}

case ${1:-} in
    index-pack | unpack-objects)
        if mkdir "$pause_dir/claimed" 2>/dev/null; then
            touch "$pause_dir/ready"
            while [[ ! -e "$pause_dir/release" ]]; do
                sleep 0.01
            done
        fi
        ;;
esac

exec "$git_exec_path/git" "$@"
