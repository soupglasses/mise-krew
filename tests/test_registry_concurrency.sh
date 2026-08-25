#!/usr/bin/env bash

set -euo pipefail

repo_root=$(cd "$(dirname "$0")/.." && pwd)
test_root=$(mktemp -d "${TMPDIR:-/tmp}/mise-krew-concurrency.XXXXXX")

cleanup() {
    if [[ -n ${pause_dir:-} ]]; then
        touch "$pause_dir/release" 2>/dev/null || true
    fi
    if [[ -n ${stale_fetch_pid:-} ]]; then
        kill "$stale_fetch_pid" 2>/dev/null || true
        wait "$stale_fetch_pid" 2>/dev/null || true
    fi
    rm -rf "$test_root"
}
trap cleanup EXIT

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

# Retired claims suppress delayed ABA races, but must not accumulate forever.
mkdir "$plugin/registry.initializing.retired.oldclaim"
printf 'oldclaim' >"$plugin/registry.initializing.retired.oldclaim/owner"
printf '0' >"$plugin/registry.initializing.retired.oldclaim/started_at"
mkdir "$plugin/registry.initializing.retired.recentclaim"
printf 'recentclaim' >"$plugin/registry.initializing.retired.recentclaim/owner"
date +%s >"$plugin/registry.initializing.retired.recentclaim/started_at"
mkdir "$plugin/registry.initializing.retired.unexpectedclaim"
printf 'unexpectedclaim' >"$plugin/registry.initializing.retired.unexpectedclaim/owner"
printf '0' >"$plugin/registry.initializing.retired.unexpectedclaim/started_at"
printf 'preserve me' >"$plugin/registry.initializing.retired.unexpectedclaim/unexpected"

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
if [[ -e "$plugin/registry.initializing.retired.deadworker" || -e "$plugin/registry.initializing.retired.oldclaim" ]]; then
    echo "expired initialization tombstones were not removed" >&2
    exit 1
fi
if [[ ! -e "$plugin/registry.initializing.retired.recentclaim" ]]; then
    echo "recent initialization tombstone was removed" >&2
    exit 1
fi
if [[ ! -e "$plugin/registry.initializing.retired.unexpectedclaim/unexpected" ]]; then
    echo "unexpected initialization tombstone contents were removed" >&2
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

# An older fetch can finish after a newer one. Pause its index-pack after it has
# negotiated the current remote tip, advance and fetch the remote in another
# process, then let the older fetch try to publish its stale result.
git -C "$plugin/registry" -c core.fsmonitor=false remote set-url origin "file://$remote"
printf 'metadata:\n  name: demo\nspec:\n  version: v3.0.0\n' >"$seed/plugins/demo.yaml"
git -C "$seed" -c core.fsmonitor=false add plugins/demo.yaml
git -C "$seed" -c commit.gpgsign=false -c core.fsmonitor=false commit -m 'stale fetch candidate' >/dev/null
git -C "$seed" -c core.fsmonitor=false push origin master >/dev/null 2>&1

pause_dir="$test_root/fetch-pause"
paused_git_exec="$test_root/git-core"
mkdir "$pause_dir" "$paused_git_exec"
git_exec_path=$(git --exec-path)
for git_helper in "$git_exec_path"/*; do
    ln -s "$git_helper" "$paused_git_exec/$(basename "$git_helper")"
done
ln -sf "$repo_root/tests/pause_index_pack.sh" "$paused_git_exec/git"

(
    cd "$repo_root"
    GIT_CONFIG_GLOBAL="$hostile_config" \
        GIT_CONFIG_COUNT=1 \
        GIT_CONFIG_KEY_0=fetch.unpackLimit \
        GIT_CONFIG_VALUE_0=1 \
        GIT_EXEC_PATH="$paused_git_exec" \
        MISE_KREW_GIT_EXEC_PATH="$git_exec_path" \
        MISE_KREW_PAUSE_DIR="$pause_dir" \
        lua tests/registry_worker.lua "$plugin" "$remote" "$command_log"
) >"$test_root/stale-fetch.log" 2>&1 &
stale_fetch_pid=$!

for _ in {1..500}; do
    if [[ -e "$pause_dir/ready" ]]; then
        break
    fi
    if ! kill -0 "$stale_fetch_pid" 2>/dev/null; then
        wait "$stale_fetch_pid" || true
        cat "$test_root/stale-fetch.log"
        echo "stale fetch exited before reaching the publication barrier" >&2
        exit 1
    fi
    sleep 0.01
done
if [[ ! -e "$pause_dir/ready" ]]; then
    kill "$stale_fetch_pid" 2>/dev/null || true
    wait "$stale_fetch_pid" || true
    cat "$test_root/stale-fetch.log"
    echo "timed out waiting for stale fetch publication barrier" >&2
    exit 1
fi

printf 'metadata:\n  name: demo\nspec:\n  version: v4.0.0\n' >"$seed/plugins/demo.yaml"
git -C "$seed" -c core.fsmonitor=false add plugins/demo.yaml
git -C "$seed" -c commit.gpgsign=false -c core.fsmonitor=false commit -m 'new fetch candidate' >/dev/null
git -C "$seed" -c core.fsmonitor=false push origin master >/dev/null 2>&1

(
    cd "$repo_root"
    GIT_CONFIG_GLOBAL="$hostile_config" lua tests/registry_worker.lua "$plugin" "$remote" "$command_log"
) >"$test_root/new-fetch.log" 2>&1

touch "$pause_dir/release"
if ! wait "$stale_fetch_pid"; then
    cat "$test_root/stale-fetch.log"
    exit 1
fi
stale_fetch_pid=

expected=$(git -C "$seed" -c core.fsmonitor=false rev-parse HEAD)
actual=$(git -C "$plugin/registry" -c core.fsmonitor=false rev-parse refs/remotes/origin/master)
if [[ "$actual" != "$expected" ]]; then
    echo "an older fetch rolled the registry ref backward" >&2
    exit 1
fi

if [[ -e "$plugin/registry/plugins/demo.yaml" ]]; then
    echo "registry worktree was unexpectedly checked out" >&2
    exit 1
fi

echo "Registry optimistic parallelism test passed"
