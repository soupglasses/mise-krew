#!/usr/bin/env bash

set -euo pipefail

repo_root=$(cd "$(dirname "$0")/.." && pwd)
test_root=$(mktemp -d "${TMPDIR:-/tmp}/mise-krew-concurrency.XXXXXX")
trap 'rm -rf "$test_root"' EXIT

remote="$test_root/remote.git"
seed="$test_root/seed"
plugin="$test_root/plugin"
command_log="$test_root/commands.log"
hostile_config="$test_root/hostile.gitconfig"

git -c core.fsmonitor=false init --bare "$remote" >/dev/null
git -c core.fsmonitor=false init -b master "$seed" >/dev/null
git -C "$seed" -c core.fsmonitor=false config user.name test
git -C "$seed" -c core.fsmonitor=false config user.email test@example.invalid
git -C "$seed" -c core.fsmonitor=false remote add origin "$remote"
mkdir -p "$seed/plugins" "$plugin"
printf 'metadata:\n  name: demo\nspec:\n  version: v1.0.0\n' >"$seed/plugins/demo.yaml"
git -C "$seed" -c core.fsmonitor=false add plugins/demo.yaml
git -C "$seed" -c commit.gpgsign=false -c core.fsmonitor=false commit -m initial >/dev/null
git -C "$seed" -c core.fsmonitor=false push -u origin master >/dev/null 2>&1
git -C "$remote" symbolic-ref HEAD refs/heads/master

# These settings broke the previous checkout/pull design or can make Git touch
# shared auxiliary state. Plugin behavior must override them without discarding
# useful user transport settings such as credentials and proxies.
git config --file "$hostile_config" clone.defaultRemoteName not-origin
git config --file "$hostile_config" core.fsmonitor true
git config --file "$hostile_config" fetch.writeCommitGraph true
git config --file "$hostile_config" fetch.recurseSubmodules on-demand
git config --file "$hostile_config" maintenance.auto true
git config --file "$hostile_config" pull.rebase true

# An abandoned coalescing claim must not block initialization or cause every
# waiter to clone. Candidates are fully populated before publication, so this
# is the only stale state a killed initializer can expose.
mkdir "$plugin/registry.initializing"
printf 'deadworker' >"$plugin/registry.initializing/owner"
printf '0' >"$plugin/registry.initializing/started_at"

run_workers() {
    local phase=$1
    local pids=()
    local logs=()
    local i

    for i in {1..16}; do
        logs+=("$test_root/$phase-$i.log")
        (
            cd "$repo_root"
            GIT_CONFIG_GLOBAL="$hostile_config" lua tests/registry_worker.lua "$plugin" "$remote" "$command_log"
        ) >"$test_root/$phase-$i.log" 2>&1 &
        pids+=("$!")
    done

    for i in "${!pids[@]}"; do
        if ! wait "${pids[$i]}"; then
            cat "${logs[$i]}"
            return 1
        fi
    done
}

run_workers bootstrap

clone_count=$(grep -c ' clone .*registry\.incomplete\.' "$command_log")
if [[ "$clone_count" -ne 1 ]]; then
    echo "expected one bootstrap clone, saw $clone_count" >&2
    exit 1
fi
if [[ -e "$plugin/registry.initializing" ]]; then
    echo "initialization claim was not retired" >&2
    exit 1
fi

printf 'metadata:\n  name: demo\nspec:\n  version: v2.0.0\n' >"$seed/plugins/demo.yaml"
git -C "$seed" -c core.fsmonitor=false add plugins/demo.yaml
git -C "$seed" -c commit.gpgsign=false -c core.fsmonitor=false commit -m update >/dev/null
git -C "$seed" -c core.fsmonitor=false push origin master >/dev/null 2>&1

run_workers refresh

expected=$(git -C "$seed" -c core.fsmonitor=false rev-parse HEAD)
actual=$(git -C "$plugin/registry" -c core.fsmonitor=false rev-parse refs/remotes/origin/master)
[[ "$actual" == "$expected" ]]
git -C "$plugin/registry" -c core.fsmonitor=false fsck --strict >/dev/null

if [[ -e "$plugin/registry/plugins/demo.yaml" ]]; then
    echo "registry worktree was unexpectedly checked out" >&2
    exit 1
fi

echo "Registry optimistic parallelism test passed"
