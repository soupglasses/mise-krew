-- lib/registry.lua
-- Git registry wrapper for krew-index operations
--
-- Concurrency model
--
-- This registry is shared by concurrently running mise processes.
--
-- INITIALIZATION: An empty repository is published by atomic rename. Its
-- bootstrap lease coalesces the expensive first fetch but is not part of
-- correctness. The lease winner fetches into a unique candidate ref and uses
-- atomic create-if-absent to publish the registry ref. A killed or stale winner can
-- therefore be replaced without exposing partial history or rolling back a
-- newer winner.
--
-- REFRESH: Refreshes may run concurrently. They update only
-- refs/remotes/origin/master, which Git publishes atomically after its objects
-- exist. Git rejects a stale ref transaction when another fetch publishes
-- first; transient compare-and-swap and lock conflicts are retried.
--
-- READS: Each operation captures the registry ref once and reads manifests and
-- history from that immutable commit. Never read from a mutable worktree.

local M = {}

-- Configuration
M.REPO_URL = "https://github.com/kubernetes-sigs/krew-index.git"
M.REGISTRY_DIR = "registry"
M.REGISTRY_REF = "refs/remotes/origin/master"
M.BOOTSTRAP_LEASE_REF = "refs/mise-krew/bootstrap"
M.BOOTSTRAP_CANDIDATE_PREFIX = "refs/mise-krew/candidates/"
M.OBJECT_FORMAT = "sha1"
M.STAMP_FILE = ".git/mise-krew-last-fetch"
M.CACHE_TTL_SECONDS = 86400 -- 24 hours
M.FETCH_RETRIES = 10
M.FETCH_RETRY_COMMAND = "sleep 0.1"
M.BOOTSTRAP_LEASE_SECONDS = 300
M.BOOTSTRAP_TIMEOUT_SECONDS = 600
M.BOOTSTRAP_WAIT_COMMAND = "sleep 0.1"
M.BOOTSTRAP_CONTENDED_WAIT_COMMAND = "sleep 1"

local ZERO_OID = string.rep("0", 40)

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

local function loose_ref_path(registry_path, ref)
    local file = require("file")
    return file.join_path(registry_path, ".git", ref)
end

local function loose_ref_oid(registry_path, ref)
    local content = read_file(loose_ref_path(registry_path, ref))
    local oid = content and content:match("^([0-9a-fA-F]+)%s*$")
    if oid and #oid == 40 then
        return oid
    end
    return nil
end

function M.exists()
    local file = require("file")
    local registry_path = M.get_registry_path()
    if not file.exists(registry_path) or not file.exists(file.join_path(registry_path, ".git")) then
        return false
    end

    local _, err = git("rev-parse --verify --quiet " .. quote(M.REGISTRY_REF .. "^{commit}"), registry_path)
    return err == nil
end

local function repository_exists()
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

local function create_private_repository()
    local registry_path = M.get_registry_path()
    local temp_path = registry_path .. ".incomplete." .. unique_token()
    local init_args = table.concat({
        "-c init.defaultRefFormat=files",
        "init",
        "--quiet",
        "--object-format=" .. M.OBJECT_FORMAT,
        quote(temp_path),
    }, " ")
    local _, init_err = git(init_args)
    if init_err then
        shell("rm -rf " .. quote(temp_path))
        return nil, "Failed to initialize registry: " .. init_err
    end

    local ref_format = git("config --get extensions.refStorage", temp_path)
    ref_format = ref_format and ref_format:gsub("%s+$", "") or "files"
    if ref_format ~= "" and ref_format ~= "files" then
        shell("rm -rf " .. quote(temp_path))
        return nil, "Registry requires Git's files ref format, got: " .. ref_format
    end

    -- Configure only the URL. `git remote add` also installs a default fetch
    -- refspec that can update the canonical ref while fetching a candidate.
    local _, remote_err = git("config remote.origin.url " .. quote(M.REPO_URL), temp_path)
    if remote_err then
        shell("rm -rf " .. quote(temp_path))
        return nil, "Failed to configure registry remote: " .. remote_err
    end

    return temp_path, nil
end

local function create_bootstrap_lease(registry_path, expected_oid)
    local token = unique_token()
    local lease_path = M.get_stamp_path(registry_path) .. ".lease." .. token
    local written, write_err = write_file(lease_path, token .. "\n" .. tostring(os.time()) .. "\n")
    if not written then
        return nil, "Failed to create registry bootstrap lease: " .. tostring(write_err)
    end

    local lease_oid, hash_err = git("hash-object -w " .. quote(lease_path), registry_path)
    os.remove(lease_path)
    if hash_err then
        return nil, "Failed to store registry bootstrap lease: " .. hash_err
    end
    lease_oid = lease_oid:gsub("%s+$", "")

    local _, update_err = git(
        "update-ref "
            .. quote(M.BOOTSTRAP_LEASE_REF)
            .. " "
            .. quote(lease_oid)
            .. " "
            .. quote(expected_oid or ZERO_OID),
        registry_path
    )
    if update_err then
        return nil, update_err
    end
    return { token = token, oid = lease_oid, started_at = os.time() }, nil
end

local function get_bootstrap_lease(registry_path, cached_lease)
    local oid = loose_ref_oid(registry_path, M.BOOTSTRAP_LEASE_REF)
    if not oid then
        return nil
    end
    if cached_lease and cached_lease.oid == oid then
        return cached_lease
    end

    local content = git("cat-file blob " .. quote(oid), registry_path)
    local token, started_at
    if content then
        token, started_at = content:match("^([%w]+)\n(%d+)")
    end
    return { token = token, oid = oid, started_at = tonumber(started_at) or 0 }
end

local function fetch_ref(registry_path, destination_ref)
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
        "+refs/heads/master:" .. destination_ref,
    }, " ")

    local fetch_err
    for attempt = 1, M.FETCH_RETRIES do
        local _, err = git(fetch_args, registry_path)
        if not err then
            return true, nil
        end

        fetch_err = err
        if attempt < M.FETCH_RETRIES then
            shell(M.FETCH_RETRY_COMMAND)
        end
    end

    return nil, "Failed to refresh registry: " .. tostring(fetch_err)
end

-- Fetch only the ref the plugin reads. Git publishes refs atomically after all
-- referenced objects are present and rejects an update if the ref changed since
-- the fetch began. Bounded retries handle competing fetches, while the forced
-- refspec still permits an intentional upstream force-push.
local function fetch_repository(registry_path)
    local fetched, fetch_err = fetch_ref(registry_path, M.REGISTRY_REF)
    if not fetched then
        return nil, fetch_err
    end

    local marked, mark_err = M.mark_fetched(registry_path)
    if not marked then
        return nil, mark_err
    end
    return true, nil
end

local function delete_ref(registry_path, ref, expected_oid)
    local args = "update-ref -d " .. quote(ref)
    if expected_oid then
        args = args .. " " .. quote(expected_oid)
    end
    git(args, registry_path)
end

local function retire_ref_lock(registry_path, ref, token)
    local file = require("file")
    local lock_path = loose_ref_path(registry_path, ref) .. ".lock"
    if not file.exists(lock_path) then
        return true, nil
    end

    local retired_path = lock_path .. ".retired." .. token
    if not os.rename(lock_path, retired_path) then
        return nil, "Failed to retire stale registry lock: " .. lock_path
    end
    os.remove(retired_path)
    return true, nil
end

local function publish_initial_ref(registry_path, candidate_oid, token)
    local ref_path = loose_ref_path(registry_path, M.REGISTRY_REF)
    local ref_dir = ref_path:match("^(.*)/[^/]+$")
    local candidate_path = ref_path .. ".candidate." .. token

    if M.exists() then
        return false, nil
    end

    if not ref_dir or not shell("mkdir -p " .. quote(ref_dir)) then
        return nil, "Failed to create registry ref directory: " .. tostring(ref_dir)
    end
    local written, write_err = write_file(candidate_path, candidate_oid .. "\n")
    if not written then
        return nil, "Failed to prepare registry ref: " .. tostring(write_err)
    end

    -- A previous bootstrap implementation may have been killed while updating
    -- this ref. The lease timeout establishes that its fixed lock is abandoned;
    -- retire it before making the repository ready so later refreshes can use
    -- normal Git ref transactions.
    local retired, retire_err = retire_ref_lock(registry_path, M.REGISTRY_REF, token)
    if not retired then
        os.remove(candidate_path)
        return nil, retire_err
    end

    -- link(2) creates the loose ref only when it does not already exist. This
    -- bootstrap-only create has no fixed lockfile of its own for SIGKILL to
    -- strand in the already-published empty repository.
    local published = shell("ln " .. quote(candidate_path) .. " " .. quote(ref_path) .. " 2>/dev/null")
    os.remove(candidate_path)
    if published then
        return true, nil
    end
    if M.exists() then
        return false, nil
    end
    return nil, "Failed to publish initial registry ref: " .. ref_path
end

local function publish_bootstrap_candidate(registry_path, lease)
    local candidate_ref = M.BOOTSTRAP_CANDIDATE_PREFIX .. lease.token
    local fetched, fetch_err = fetch_ref(registry_path, candidate_ref)
    if not fetched then
        delete_ref(registry_path, M.BOOTSTRAP_LEASE_REF, lease.oid)
        return nil, fetch_err
    end

    local candidate_oid, candidate_err =
        git("rev-parse --verify " .. quote(candidate_ref .. "^{commit}"), registry_path)
    if candidate_err then
        delete_ref(registry_path, candidate_ref)
        delete_ref(registry_path, M.BOOTSTRAP_LEASE_REF, lease.oid)
        return nil, "Failed to resolve registry bootstrap candidate: " .. candidate_err
    end
    candidate_oid = candidate_oid:gsub("%s+$", "")

    -- Publish freshness before readiness. An absent canonical ref keeps this
    -- stamp invisible on failure, while a successful ref create cannot expose
    -- a ready-but-apparently-stale repository to a new caller.
    local marked, mark_err = M.mark_fetched(registry_path)
    if not marked then
        delete_ref(registry_path, candidate_ref, candidate_oid)
        delete_ref(registry_path, M.BOOTSTRAP_LEASE_REF, lease.oid)
        return nil, mark_err
    end

    local published, publish_err = publish_initial_ref(registry_path, candidate_oid, lease.token)
    delete_ref(registry_path, candidate_ref, candidate_oid)

    if not published then
        -- Publication failure makes this lease useless. Delete only the lease
        -- generation we owned so waiters can recover immediately without
        -- disturbing a successor that may already have replaced it.
        delete_ref(registry_path, M.BOOTSTRAP_LEASE_REF, lease.oid)
        if M.exists() then
            -- A concurrently published candidate may have observed an older
            -- remote tip. Refresh once more rather than assuming either
            -- candidate is newer across a possible upstream force-push.
            return fetch_repository(registry_path)
        end
        return nil, publish_err
    end

    delete_ref(registry_path, M.BOOTSTRAP_LEASE_REF, lease.oid)
    return true, nil
end

local function wait_for_bootstrap(registry_path)
    local deadline = os.time() + M.BOOTSTRAP_TIMEOUT_SECONDS
    local attempted_lease_oid
    local cached_lease
    local contended = false
    while not loose_ref_oid(registry_path, M.REGISTRY_REF) do
        local lease = get_bootstrap_lease(registry_path, cached_lease)
        cached_lease = lease
        local lease_age = lease and (os.time() - lease.started_at) or M.BOOTSTRAP_LEASE_SECONDS
        local lease_oid = lease and lease.oid or ZERO_OID
        if attempted_lease_oid ~= lease_oid then
            contended = false
        end
        if lease_age >= M.BOOTSTRAP_LEASE_SECONDS and attempted_lease_oid ~= lease_oid then
            attempted_lease_oid = lease_oid
            local token = unique_token()
            local retired = retire_ref_lock(registry_path, M.BOOTSTRAP_LEASE_REF, token)
            if retired then
                local replacement = create_bootstrap_lease(registry_path, lease_oid)
                if replacement then
                    return publish_bootstrap_candidate(registry_path, replacement)
                end
            end
            contended = true
        end

        if os.time() >= deadline then
            -- Filesystem or permission failures may still make the advisory
            -- lease unusable. Bypass it after the deadline; unique candidate
            -- refs and atomic canonical publication still preserve correctness.
            return publish_bootstrap_candidate(registry_path, {
                token = unique_token(),
                oid = lease and lease.oid or ZERO_OID,
            })
        end
        shell(contended and M.BOOTSTRAP_CONTENDED_WAIT_COMMAND or M.BOOTSTRAP_WAIT_COMMAND)
    end
    if M.exists() then
        return true, nil
    end
    return nil, "Published registry ref is invalid: " .. M.REGISTRY_REF
end

-- Concurrent refresh of the published repository.
function M.refresh()
    return fetch_repository(M.get_registry_path())
end

-- Public orchestration
function M.initialize_registry()
    local registry_path = M.get_registry_path()
    if not repository_exists() then
        local temp_path, create_err = create_private_repository()
        if not temp_path then
            return nil, create_err
        end

        local lease, lease_err = create_bootstrap_lease(temp_path, ZERO_OID)
        if not lease then
            shell("rm -rf " .. quote(temp_path))
            return nil, lease_err
        end

        if os.rename(temp_path, registry_path) then
            return publish_bootstrap_candidate(registry_path, lease)
        end
        shell("rm -rf " .. quote(temp_path))
    end

    if not repository_exists() then
        return nil, "Failed to publish empty registry: " .. registry_path
    end
    return wait_for_bootstrap(registry_path)
end

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
