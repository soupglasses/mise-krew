-- lib/registry.lua
-- Git registry wrapper for krew-index operations
--
-- Concurrency model
--
-- This registry is shared by concurrently running mise processes.
--
-- INITIAL CLONE: A clone is built in a unique private directory and published
-- by atomic rename. `registry.initializing` only coalesces downloads; it is not
-- part of registry correctness. Losing a claim may cause duplicate clones but
-- must never expose a partial registry.
--
-- REFRESH: Refreshes may run concurrently. They update only
-- refs/remotes/origin/master, which Git publishes atomically after its objects
-- exist. Transient Git lock conflicts are retried.
--
-- READS: Each operation captures the registry ref once and reads manifests and
-- history from that immutable commit. Never read from a mutable worktree.

local M = {}

-- Configuration
M.REPO_URL = "https://github.com/kubernetes-sigs/krew-index.git"
M.REGISTRY_DIR = "registry"
M.INITIAL_CLONE_CLAIM_DIR = "registry.initializing"
M.REGISTRY_REF = "refs/remotes/origin/master"
M.STAMP_FILE = ".git/mise-krew-last-fetch"
M.CACHE_TTL_SECONDS = 86400 -- 24 hours
M.FETCH_RETRIES = 10
M.FETCH_RETRY_COMMAND = "sleep 0.1"
M.INITIAL_CLONE_STALE_SECONDS = 300
M.INITIAL_CLONE_TIMEOUT_SECONDS = 600
M.INITIAL_CLONE_BACKOFF_MAX_TENTHS = 10
M.INITIAL_CLONE_TOMBSTONE_RETENTION_SECONDS = 86400 -- 24 hours

-- Filesystem and process helpers
-- os.execute returns an exit status on Lua 5.1 and a boolean on Lua 5.2+.
local function shell(command)
    local ok, _, code = os.execute(command)
    if type(ok) == "number" then
        return ok == 0
    end
    return ok == true and (code == nil or code == 0)
end

local function quote(value)
    local escaped = tostring(value):gsub("'", "'\\''")
    return "'" .. escaped .. "'"
end

local function read_file(path)
    local handle = io.open(path, "r")
    if not handle then
        return nil
    end

    local content = handle:read("*all")
    handle:close()
    return content
end

local function write_file(path, content)
    local handle, open_err = io.open(path, "w")
    if not handle then
        return nil, open_err
    end

    local ok, write_err = handle:write(content)
    if not ok then
        handle:close()
        return nil, write_err
    end

    local closed, close_err = handle:close()
    if not closed then
        return nil, close_err
    end

    return true, nil
end

local function unique_token()
    local temp_path = os.tmpname()
    os.remove(temp_path)
    return temp_path:gsub("[^%w]", "") .. tostring(os.time())
end

local function initial_clone_backoff()
    local token = unique_token()
    local checksum = 0
    for i = 1, #token do
        checksum = checksum + token:byte(i)
    end
    local tenths = (checksum % M.INITIAL_CLONE_BACKOFF_MAX_TENTHS) + 1
    local delay = tenths == 10 and "1.0" or "0." .. tostring(tenths)
    shell("sleep " .. delay)
end

-- Git command wrapper
local function git(args, cwd)
    local cmd = require("cmd")
    local command = "git -c core.fsmonitor=false " .. args
    local ok, result
    if cwd then
        ok, result = pcall(cmd.exec, command, { cwd = cwd })
    else
        ok, result = pcall(cmd.exec, command)
    end

    if not ok then
        return nil, "`git " .. args .. "` failed: " .. tostring(result)
    end
    return result or "", nil
end

M.git = git

-- Registry paths and freshness stamp
function M.get_registry_path()
    local file = require("file")
    return file.join_path(RUNTIME.pluginDirPath, M.REGISTRY_DIR)
end

function M.get_stamp_path(registry_path)
    local file = require("file")
    return file.join_path(registry_path or M.get_registry_path(), M.STAMP_FILE)
end

function M.get_initial_clone_claim_path()
    local file = require("file")
    return file.join_path(RUNTIME.pluginDirPath, M.INITIAL_CLONE_CLAIM_DIR)
end

function M.exists()
    local file = require("file")
    local registry_path = M.get_registry_path()
    return file.exists(registry_path) and file.exists(file.join_path(registry_path, ".git"))
end

function M.get_last_fetch()
    local content = read_file(M.get_stamp_path())
    return tonumber(content and content:match("%d+")) or 0
end

function M.mark_fetched(registry_path)
    local stamp_path = M.get_stamp_path(registry_path)
    local temp_path = stamp_path .. ".tmp." .. unique_token()
    local ok, err = write_file(temp_path, tostring(os.time()))
    if not ok then
        return nil, "Failed to record registry fetch time: " .. tostring(err)
    end

    if not os.rename(temp_path, stamp_path) then
        os.remove(temp_path)
        return nil, "Failed to publish registry fetch time: " .. stamp_path
    end
    return true, nil
end

function M.is_stale()
    return (os.time() - M.get_last_fetch()) >= M.CACHE_TTL_SECONDS
end

-- Initial clone coordination
-- Publish a fully initialized clone claim atomically. The claim only coalesces
-- downloads; correctness still comes from private clones and atomic publication.
local function try_claim_initial_clone()
    local init_path = M.get_initial_clone_claim_path()
    local token = unique_token()
    local candidate_path = init_path .. ".candidate." .. token
    if not shell("mkdir " .. quote(candidate_path) .. " 2>/dev/null") then
        return nil
    end

    local owner_ok = write_file(candidate_path .. "/owner", token)
    local stamp_ok = write_file(candidate_path .. "/started_at", tostring(os.time()))
    if not owner_ok or not stamp_ok or not os.rename(candidate_path, init_path) then
        shell("rm -rf " .. quote(candidate_path))
        return nil
    end
    return token
end

local function initial_clone_claim_age(claim_path)
    local content = read_file((claim_path or M.get_initial_clone_claim_path()) .. "/started_at")
    local started_at = tonumber(content and content:match("%d+"))
    return started_at and (os.time() - started_at) or nil
end

local function retire_initial_clone_claim(expected_owner)
    local init_path = M.get_initial_clone_claim_path()
    if not expected_owner:match("^[%w]+$") or read_file(init_path .. "/owner") ~= expected_owner then
        return false
    end

    -- All waiters for this owner target the same non-empty directory. The first
    -- rename wins; retaining that tombstone prevents a delayed waiter from
    -- renaming a successor claim after the ownership check above (an ABA race).
    local retired_path = init_path .. ".retired." .. expected_owner
    if not os.rename(init_path, retired_path) then
        return false
    end
    return true
end

local function retired_initial_clone_claims()
    local cmd = require("cmd")
    local claim_path = M.get_initial_clone_claim_path()
    local retired_prefix = claim_path .. ".retired."
    local pattern = M.INITIAL_CLONE_CLAIM_DIR .. ".retired.*"
    local command = table.concat({
        "find",
        quote(RUNTIME.pluginDirPath),
        "! -path",
        quote(RUNTIME.pluginDirPath),
        "-prune -type d -name",
        quote(pattern),
        "-print",
    }, " ")
    local ok, output = pcall(cmd.exec, command)
    if not ok then
        return {}
    end

    local paths = {}
    for path in output:gmatch("[^\r\n]+") do
        local owner = path:sub(#retired_prefix + 1)
        if path == retired_prefix .. owner and owner:match("^[%w]+$") then
            table.insert(paths, path)
        end
    end
    return paths
end

local function cleanup_retired_initial_clone_claims()
    local file = require("file")
    for _, retired_path in ipairs(retired_initial_clone_claims()) do
        local age = initial_clone_claim_age(retired_path)
        if age and age >= M.INITIAL_CLONE_TOMBSTONE_RETENTION_SECONDS then
            -- Tombstones close the ABA window for delayed waiters. After 24 hours,
            -- accepting a theoretical duplicate clone is preferable to leaking them forever.
            os.remove(retired_path .. "/owner")
            os.remove(retired_path .. "/started_at")
            local removed, remove_err = os.remove(retired_path)
            if not removed and file.exists(retired_path) then
                require("log").warn(
                    "Failed to remove expired registry initialization tombstone "
                        .. retired_path
                        .. ": "
                        .. tostring(remove_err)
                        .. ". It may contain unexpected files; leaving it in place."
                )
            end
        end
    end
end

-- Private clone and atomic publication
local function clone_and_publish(claim_owner)
    local registry_path = M.get_registry_path()
    local temp_path = registry_path .. ".incomplete." .. unique_token()
    local clone_args = string.format(
        "clone --quiet --no-checkout --no-recurse-submodules --single-branch --branch master --origin origin --no-tags %s %s",
        quote(M.REPO_URL),
        quote(temp_path)
    )

    local _, clone_err = git(clone_args)
    if clone_err then
        shell("rm -rf " .. quote(temp_path))
        retire_initial_clone_claim(claim_owner)
        return nil, "Failed to clone registry: " .. clone_err
    end

    local marked, mark_err = M.mark_fetched(temp_path)
    if not marked then
        shell("rm -rf " .. quote(temp_path))
        retire_initial_clone_claim(claim_owner)
        return nil, mark_err
    end

    if os.rename(temp_path, registry_path) then
        retire_initial_clone_claim(claim_owner)
        cleanup_retired_initial_clone_claims()
        return true, nil
    end

    shell("rm -rf " .. quote(temp_path))
    if M.exists() then
        retire_initial_clone_claim(claim_owner)
        cleanup_retired_initial_clone_claims()
        return true, nil
    end
    retire_initial_clone_claim(claim_owner)
    return nil, "Failed to publish registry clone: " .. registry_path
end

-- Normally exactly one caller clones while the others wait. If that caller is
-- killed, one waiter retires its old claim and becomes the next initializer.
function M.initialize_registry()
    local deadline = os.time() + M.INITIAL_CLONE_TIMEOUT_SECONDS
    while not M.exists() do
        -- Have I been sleeping too long? A suspended waiter must not wake up
        -- after its deadline and mutate a much newer initialization claim.
        if os.time() >= deadline then
            return nil, "Timed out waiting to initialize registry at " .. M.get_registry_path()
        end

        local claim_owner = try_claim_initial_clone()
        if claim_owner then
            return clone_and_publish(claim_owner)
        end

        -- Read the identity first so an old timestamp can only retire the claim
        -- it belonged to, never a fresh successor published between these reads.
        local owner = read_file(M.get_initial_clone_claim_path() .. "/owner")
        local age = initial_clone_claim_age()
        if owner and age and age >= M.INITIAL_CLONE_STALE_SECONDS then
            retire_initial_clone_claim(owner)
        end

        if not M.exists() then
            initial_clone_backoff()
        end
    end
    return true, nil
end

-- Concurrent refresh
-- Fetch only the ref the plugin reads. Git publishes refs atomically after all
-- referenced objects are present; bounded retries handle competing fetches.
function M.refresh()
    local fetch_args = table.concat({
        "fetch",
        "--quiet",
        "--atomic",
        "--no-tags",
        "--no-recurse-submodules",
        "--no-write-fetch-head",
        "--no-write-commit-graph",
        "--no-auto-maintenance",
        "origin",
        "+refs/heads/master:" .. M.REGISTRY_REF,
    }, " ")

    local fetch_err
    for attempt = 1, M.FETCH_RETRIES do
        local _, err = git(fetch_args, M.get_registry_path())
        if not err then
            local marked, mark_err = M.mark_fetched()
            if not marked then
                return nil, mark_err
            end
            return true, nil
        end

        fetch_err = err
        if attempt < M.FETCH_RETRIES then
            shell(M.FETCH_RETRY_COMMAND)
        end
    end

    return nil, "Failed to refresh registry: " .. tostring(fetch_err)
end

-- Public orchestration
function M.ensure_fresh()
    if not M.exists() then
        return M.initialize_registry()
    end
    if M.is_stale() then
        return M.refresh()
    end
    return true, nil
end

-- Immutable snapshot reads
function M.get_head()
    local result, err = git("rev-parse --verify " .. quote(M.REGISTRY_REF .. "^{commit}"), M.get_registry_path())
    if err then
        return nil, "Failed to get registry head: " .. err
    end

    result = result:gsub("%s+$", "")
    if result == "" or not result:match("^[0-9a-fA-F]+$") then
        return nil, "Failed to get registry head"
    end
    return result, nil
end

-- The revision is captured by the caller so a concurrent fetch cannot change
-- the history halfway through building a version index.
function M.get_file_history(plugin_name, revision)
    revision = revision or M.get_head()
    if not revision then
        return nil, "Failed to get registry head"
    end

    local plugin_path = "plugins/" .. plugin_name .. ".yaml"
    local args =
        string.format("--no-pager log --format=%%H --no-show-signature %s -- %s", quote(revision), quote(plugin_path))
    local result, err = git(args, M.get_registry_path())
    if err then
        return nil, "Failed to read krew index history for " .. plugin_name .. ": " .. err
    end
    if result == "" then
        return nil, "Plugin not found in krew index: " .. plugin_name
    end

    local lines = {}
    for line in result:gmatch("[^\r\n]+") do
        line = line:match("^%s*(.-)%s*$")
        if #line == 40 and line:match("^[0-9a-fA-F]+$") then
            table.insert(lines, line)
        end
    end

    local i = 0
    return function()
        i = i + 1
        return lines[i]
    end
end

function M.get_manifest_at_commit(plugin_name, commit_hash)
    local plugin_path = "plugins/" .. plugin_name .. ".yaml"
    local result, err = git("show " .. quote(commit_hash .. ":" .. plugin_path), M.get_registry_path())
    if err then
        return nil, "Failed to get manifest at commit " .. commit_hash .. ": " .. err
    end
    return result, nil
end

function M.get_current_manifest(plugin_name)
    local head, head_err = M.get_head()
    if not head then
        return nil, head_err
    end
    return M.get_manifest_at_commit(plugin_name, head)
end

function M.plugin_exists(plugin_name)
    local head = M.get_head()
    if not head then
        return false
    end

    local plugin_path = "plugins/" .. plugin_name .. ".yaml"
    local _, err = git("cat-file -e " .. quote(head .. ":" .. plugin_path), M.get_registry_path())
    return err == nil
end

return M
