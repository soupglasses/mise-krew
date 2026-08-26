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
    if [[ -n ${bootstrap_pause_dir:-} ]]; then
        touch "$bootstrap_pause_dir/release" 2>/dev/null || true
    fi
    if [[ -n ${bootstrap_fetch_pid:-} ]]; then
        kill -KILL -- "-$bootstrap_fetch_pid" 2>/dev/null || true
        wait "$bootstrap_fetch_pid" 2>/dev/null || true
    fi
    rm -rf "$test_root"
}
trap cleanup EXIT

remote="$test_root/remote.git"
seed="$test_root/seed"
plugin="$test_root/plugin"
command_log="$test_root/commands.log"
hostile_config="$test_root/hostile.gitconfig"
failed_link_bin="$test_root/failed-link-bin"

git -c core.fsmonitor=false init --bare "$remote" >/dev/null
git -c core.fsmonitor=false init -b master "$seed" >/dev/null
git -C "$seed" -c core.fsmonitor=false config user.name test
git -C "$seed" -c core.fsmonitor=false config user.email test@example.invalid
git -C "$seed" -c core.fsmonitor=false remote add origin "$remote"
mkdir -p "$seed/plugins" "$plugin"
mkdir -p "$failed_link_bin"
ln -s /usr/bin/false "$failed_link_bin/ln"
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
git config --file "$hostile_config" init.defaultObjectFormat sha256
git config --file "$hostile_config" init.defaultRefFormat reftable
git config --file "$hostile_config" pull.rebase true

# A process killed during its private fetch can leave a ref lock behind. That
# candidate must never block another process from publishing a complete clone.
abandoned_registry="$plugin/registry.incomplete.abandoned"
git -c core.fsmonitor=false init --quiet --object-format=sha1 "$abandoned_registry"
mkdir -p "$abandoned_registry/.git/refs/remotes/origin"
touch "$abandoned_registry/.git/refs/remotes/origin/master.lock"

run_workers() {
    local phase=$1
    local pids=()
    local logs=()
    local i

    for i in {1..16}; do
        logs+=("$test_root/$phase-$i.log")
        (
            cd "$repo_root"
            GIT_CONFIG_GLOBAL="$hostile_config" GIT_DEFAULT_HASH=sha256 \
                lua tests/registry_worker.lua "$plugin" "$remote" "$command_log"
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

bootstrap_fetch_count=$(grep -c ' fetch .*refs/mise-krew/candidates/' "$command_log")
if [[ "$bootstrap_fetch_count" -ne 1 ]]; then
    echo "expected one bootstrap fetch, saw $bootstrap_fetch_count" >&2
    exit 1
fi
if git -C "$plugin/registry" -c core.fsmonitor=false config --get-all remote.origin.fetch >/dev/null; then
    echo "bootstrap repository unexpectedly has a default fetch refspec" >&2
    exit 1
fi
if [[ $(git -C "$plugin/registry" -c core.fsmonitor=false config --get extensions.refStorage || true) == reftable ]]; then
    echo "bootstrap repository inherited the hostile reftable default" >&2
    exit 1
fi
if [[ $(git -C "$plugin/registry" -c core.fsmonitor=false rev-parse --show-object-format) != sha1 ]]; then
    echo "bootstrap repository inherited the hostile SHA-256 default" >&2
    exit 1
fi
if grep -Eq -- '--object-format|--atomic|--no-write-fetch-head|--no-auto-maintenance' "$command_log"; then
    echo "bootstrap used a Git option unavailable on older supported clients" >&2
    exit 1
fi
if git -C "$plugin/registry" -c core.fsmonitor=false for-each-ref --format='%(refname)' refs/mise-krew | grep -q .; then
    echo "completed bootstrap left internal refs behind" >&2
    exit 1
fi

expected=$(git -C "$seed" -c core.fsmonitor=false rev-parse HEAD)
actual=$(git -C "$plugin/registry" -c core.fsmonitor=false rev-parse refs/remotes/origin/master)
if [[ "$actual" != "$expected" ]]; then
    echo "bootstrap did not publish the remote tip" >&2
    exit 1
fi
git -C "$plugin/registry" -c core.fsmonitor=false fsck --strict >/dev/null

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
        GIT_DEFAULT_HASH=sha256 \
        GIT_CONFIG_COUNT=1 \
        GIT_CONFIG_KEY_0=fetch.unpackLimit \
        GIT_CONFIG_VALUE_0=1 \
        GIT_EXEC_PATH="$paused_git_exec" \
        MISE_KREW_GIT_EXEC_PATH="$git_exec_path" \
        MISE_KREW_PAUSE_DIR="$pause_dir" \
        lua tests/registry_worker.lua "$plugin" "$remote"
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
    GIT_CONFIG_GLOBAL="$hostile_config" GIT_DEFAULT_HASH=sha256 \
        lua tests/registry_worker.lua "$plugin" "$remote"
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

# Kill the first initializer after it has published the empty repository but
# while its candidate fetch is receiving objects. Waiters must replace its
# expired advisory lease, perform exactly one recovery fetch, and publish a
# repository that remains valid despite partial state from the killed fetch.
bootstrap_plugin="$test_root/bootstrap-crash-plugin"
bootstrap_log="$test_root/bootstrap-crash-commands.log"
bootstrap_pause_dir="$test_root/bootstrap-fetch-pause"
bootstrap_git_exec="$test_root/bootstrap-git-core"
mkdir -p "$bootstrap_plugin" "$bootstrap_pause_dir" "$bootstrap_git_exec"
for git_helper in "$git_exec_path"/*; do
    ln -s "$git_helper" "$bootstrap_git_exec/$(basename "$git_helper")"
done
ln -sf "$repo_root/tests/pause_index_pack.sh" "$bootstrap_git_exec/git"

# Bash job control gives the background initializer its own process group on
# both Linux and macOS. Killing that group also terminates Git and the paused
# index-pack helper without depending on util-linux `setsid`.
set -m
(
    exec env \
        GIT_CONFIG_GLOBAL="$hostile_config" \
        GIT_DEFAULT_HASH=sha256 \
        GIT_CONFIG_COUNT=1 \
        GIT_CONFIG_KEY_0=fetch.unpackLimit \
        GIT_CONFIG_VALUE_0=1 \
        GIT_EXEC_PATH="$bootstrap_git_exec" \
        MISE_KREW_GIT_EXEC_PATH="$git_exec_path" \
        MISE_KREW_PAUSE_DIR="$bootstrap_pause_dir" \
        MISE_KREW_BOOTSTRAP_LEASE_SECONDS=1 \
        MISE_KREW_BOOTSTRAP_TIMEOUT_SECONDS=5 \
        lua "$repo_root/tests/registry_worker.lua" "$bootstrap_plugin" "$remote" "$bootstrap_log"
) >"$test_root/bootstrap-killed.log" 2>&1 &
bootstrap_fetch_pid=$!
set +m

for _ in {1..500}; do
    if [[ -e "$bootstrap_pause_dir/ready" ]]; then
        break
    fi
    if ! kill -0 "$bootstrap_fetch_pid" 2>/dev/null; then
        wait "$bootstrap_fetch_pid" || true
        cat "$test_root/bootstrap-killed.log"
        echo "bootstrap initializer exited before reaching the fetch barrier" >&2
        exit 1
    fi
    sleep 0.01
done
if [[ ! -e "$bootstrap_pause_dir/ready" ]]; then
    kill -KILL -- "-$bootstrap_fetch_pid" 2>/dev/null || true
    wait "$bootstrap_fetch_pid" 2>/dev/null || true
    bootstrap_fetch_pid=
    cat "$test_root/bootstrap-killed.log"
    echo "timed out waiting for bootstrap fetch barrier" >&2
    exit 1
fi
if git -C "$bootstrap_plugin/registry" -c core.fsmonitor=false rev-parse --verify \
    refs/remotes/origin/master >/dev/null 2>&1; then
    echo "empty bootstrap repository became ready before its candidate fetch completed" >&2
    exit 1
fi

kill -KILL -- "-$bootstrap_fetch_pid"
wait "$bootstrap_fetch_pid" 2>/dev/null || true
bootstrap_fetch_pid=
mkdir -p "$bootstrap_plugin/registry/.git/refs/mise-krew/candidates"
touch "$bootstrap_plugin/registry/.git/refs/mise-krew/candidates/abandoned.lock"
# Lease recovery must retire a lock stranded by SIGKILL rather than creating a
# new unreachable lease object on every polling iteration.
touch "$bootstrap_plugin/registry/.git/refs/mise-krew/bootstrap.lock"
# A SIGKILL at the old update-ref publication boundary could also strand this
# fixed lock. Bootstrap publication must not depend on acquiring or deleting it.
mkdir -p "$bootstrap_plugin/registry/.git/refs/remotes/origin"
touch "$bootstrap_plugin/registry/.git/refs/remotes/origin/master.lock"

recovery_pids=()
recovery_logs=()
for i in {1..16}; do
    recovery_logs+=("$test_root/bootstrap-recovery-$i.log")
    (
        cd "$repo_root"
        PATH="$failed_link_bin:$PATH" \
            GIT_CONFIG_GLOBAL="$hostile_config" \
            GIT_DEFAULT_HASH=sha256 \
            MISE_KREW_BOOTSTRAP_LEASE_SECONDS=1 \
            MISE_KREW_BOOTSTRAP_TIMEOUT_SECONDS=5 \
            lua tests/registry_worker.lua "$bootstrap_plugin" "$remote" "$bootstrap_log"
    ) >"$test_root/bootstrap-recovery-$i.log" 2>&1 &
    recovery_pids+=("$!")
done
for i in "${!recovery_pids[@]}"; do
    if ! wait "${recovery_pids[$i]}"; then
        cat "${recovery_logs[$i]}"
        exit 1
    fi
done

bootstrap_fetch_count=$(grep -c ' fetch .*refs/mise-krew/candidates/' "$bootstrap_log")
if [[ "$bootstrap_fetch_count" -ne 2 ]]; then
    echo "expected one killed and one recovery bootstrap fetch, saw $bootstrap_fetch_count" >&2
    exit 1
fi
lease_object_count=$(grep -c ' hash-object -w ' "$bootstrap_log")
if [[ "$lease_object_count" -gt 17 ]]; then
    echo "bootstrap recovery created $lease_object_count lease objects for 16 waiters" >&2
    exit 1
fi
bootstrap_fallback_count=$(grep -c " update-ref 'refs/remotes/origin/master'" "$bootstrap_log")
if [[ "$bootstrap_fallback_count" -ne 1 ]]; then
    echo "expected one Git CAS publication during hard-link-free recovery, saw $bootstrap_fallback_count" >&2
    exit 1
fi
expected=$(git -C "$seed" -c core.fsmonitor=false rev-parse HEAD)
actual=$(git -C "$bootstrap_plugin/registry" -c core.fsmonitor=false rev-parse refs/remotes/origin/master)
if [[ "$actual" != "$expected" ]]; then
    echo "bootstrap recovery did not publish the remote tip" >&2
    exit 1
fi
if [[ -e "$bootstrap_plugin/registry/.git/refs/mise-krew/bootstrap.lock" || \
    -e "$bootstrap_plugin/registry/.git/refs/remotes/origin/master.lock" ]]; then
    echo "bootstrap recovery left a stale ref lock behind" >&2
    exit 1
fi
git -C "$bootstrap_plugin/registry" -c core.fsmonitor=false fsck --strict >/dev/null

# A recovered repository must still refresh normally after the cache TTL. This
# catches a canonical lock that bootstrap bypassed without retiring.
printf 'metadata:\n  name: demo\nspec:\n  version: v5.0.0\n' >"$seed/plugins/demo.yaml"
git -C "$seed" -c core.fsmonitor=false add plugins/demo.yaml
git -C "$seed" -c commit.gpgsign=false -c core.fsmonitor=false commit -m 'post-recovery refresh' >/dev/null
git -C "$seed" -c core.fsmonitor=false push origin master >/dev/null 2>&1
(
    cd "$repo_root"
    GIT_CONFIG_GLOBAL="$hostile_config" GIT_DEFAULT_HASH=sha256 \
        lua tests/registry_worker.lua "$bootstrap_plugin" "$remote" "$bootstrap_log"
) >"$test_root/bootstrap-refresh.log" 2>&1
expected=$(git -C "$seed" -c core.fsmonitor=false rev-parse HEAD)
actual=$(git -C "$bootstrap_plugin/registry" -c core.fsmonitor=false rev-parse refs/remotes/origin/master)
if [[ "$actual" != "$expected" ]]; then
    cat "$test_root/bootstrap-refresh.log"
    echo "recovered registry could not refresh" >&2
    exit 1
fi

# Filesystems without hard-link support, and hosts without a working `ln`, must
# fall back to Git's atomic create-only ref update without repeating the fetch.
no_link_plugin="$test_root/no-link-plugin"
no_link_log="$test_root/no-link-commands.log"
failed_publish_plugin="$test_root/failed-publish-plugin"
failed_publish_log="$test_root/failed-publish-commands.log"
mkdir -p "$no_link_plugin" "$failed_publish_plugin"
(
    cd "$repo_root"
    PATH="$failed_link_bin:$PATH" \
        GIT_CONFIG_GLOBAL="$hostile_config" \
        GIT_DEFAULT_HASH=sha256 \
        lua tests/registry_worker.lua "$no_link_plugin" "$remote" "$no_link_log"
) >"$test_root/no-link.log" 2>&1
expected=$(git -C "$seed" -c core.fsmonitor=false rev-parse HEAD)
actual=$(git -C "$no_link_plugin/registry" -c core.fsmonitor=false rev-parse refs/remotes/origin/master)
if [[ "$actual" != "$expected" ]]; then
    cat "$test_root/no-link.log"
    echo "Git CAS fallback did not publish the remote tip" >&2
    exit 1
fi
if [[ $(grep -c " update-ref 'refs/remotes/origin/master'" "$no_link_log") -ne 1 ]]; then
    echo "bootstrap did not use exactly one Git CAS publication fallback" >&2
    exit 1
fi
if [[ $(grep -c ' fetch .*refs/mise-krew/candidates/' "$no_link_log") -ne 1 ]]; then
    echo "hard-link fallback repeated the bootstrap fetch" >&2
    exit 1
fi

# If both publication mechanisms fail, release the exact lease generation.
# Otherwise the next initializer waits five minutes for a publisher that has
# already returned an error.
if (
    cd "$repo_root"
    PATH="$failed_link_bin:$PATH" \
        GIT_CONFIG_GLOBAL="$hostile_config" \
        GIT_DEFAULT_HASH=sha256 \
        MISE_KREW_FAIL_CANONICAL_UPDATE=1 \
        lua tests/registry_worker.lua "$failed_publish_plugin" "$remote" "$failed_publish_log"
) >"$test_root/failed-publish.log" 2>&1; then
    echo "bootstrap unexpectedly succeeded when both publication mechanisms failed" >&2
    exit 1
fi
if git -C "$failed_publish_plugin/registry" -c core.fsmonitor=false rev-parse --verify \
    refs/mise-krew/bootstrap >/dev/null 2>&1; then
    echo "failed bootstrap publication left its lease installed" >&2
    exit 1
fi
(
    cd "$repo_root"
    GIT_CONFIG_GLOBAL="$hostile_config" GIT_DEFAULT_HASH=sha256 \
        lua tests/registry_worker.lua "$failed_publish_plugin" "$remote" "$failed_publish_log"
) >"$test_root/failed-publish-recovery.log" 2>&1
expected=$(git -C "$seed" -c core.fsmonitor=false rev-parse HEAD)
actual=$(git -C "$failed_publish_plugin/registry" -c core.fsmonitor=false rev-parse refs/remotes/origin/master)
if [[ "$actual" != "$expected" ]]; then
    cat "$test_root/failed-publish-recovery.log"
    echo "registry did not recover immediately after failed publication" >&2
    exit 1
fi

echo "Registry optimistic parallelism test passed"
