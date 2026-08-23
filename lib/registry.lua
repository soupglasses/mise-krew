-- lib/registry.lua
-- Git registry wrapper for krew-index operations
-- Manages local clone and provides access to manifest history

local M = {}

-- Registry configuration
M.REPO_URL = "https://github.com/kubernetes-sigs/krew-index.git"
M.REGISTRY_DIR = "registry"
M.LOCK_DIR = "registry.lock"
M.STAMP_FILE = ".git/mise-krew-last-fetch"
M.CACHE_TTL_SECONDS = 86400 -- 24 hours
M.LOCK_TIMEOUT_SECONDS = 300 -- give up waiting on another process holding the lock
M.LOCK_STALE_SECONDS = 900 -- reclaim a lock left behind by a killed process
M.LOCK_UNSTAMPED_RETRIES = 25 -- ~5s of a lock directory with no timestamp in it
M.LOCK_RETRY_COMMAND = "sleep 0.2"

-- os.execute returns an exit status on Lua 5.1 and a boolean on 5.2+
local function shell(command)
    local ok, _, code = os.execute(command)
    if type(ok) == "number" then
        return ok == 0
    end
    if ok == true then
        return code == nil or code == 0
    end
    return false
end

local function quote(path)
    local escaped = tostring(path):gsub("'", "'\\''")
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

-- Run a git command and turn a failure into a plain error string.
-- `cmd.exec` raises on a non-zero exit status, which reaches the user as a Lua
-- traceback instead of an actionable message.
local function git(args, cwd)
    local cmd = require("cmd")

    local ok, result
    if cwd then
        ok, result = pcall(cmd.exec, "git " .. args, { cwd = cwd })
    else
        ok, result = pcall(cmd.exec, "git " .. args)
    end
    if not ok then
        return nil, "`git " .. args .. "` failed: " .. tostring(result)
    end

    return result or "", nil
end

M.git = git

-- Get the path to the registry directory
function M.get_registry_path()
    local file = require("file")
    return file.join_path(RUNTIME.pluginDirPath, M.REGISTRY_DIR)
end

-- Get the path to the lock directory guarding registry mutations
function M.get_lock_path()
    local file = require("file")
    return file.join_path(RUNTIME.pluginDirPath, M.LOCK_DIR)
end

-- Get the path to the file recording when the registry was last fetched.
-- It lives inside `.git/` so it is invisible to git itself and disappears
-- together with the clone.
function M.get_stamp_path()
    local file = require("file")
    return file.join_path(M.get_registry_path(), M.STAMP_FILE)
end

-- Check if registry exists locally
function M.exists()
    local file = require("file")
    local registry_path = M.get_registry_path()
    return file.exists(registry_path) and file.exists(file.join_path(registry_path, ".git"))
end

-- Timestamp of the last successful fetch, 0 when never fetched
function M.get_last_fetch()
    local content = read_file(M.get_stamp_path())
    return tonumber(content and content:match("%d+")) or 0
end

-- Record a successful fetch
function M.mark_fetched()
    local ok, err = write_file(M.get_stamp_path(), tostring(os.time()))
    if not ok then
        return nil, "Failed to record registry fetch time: " .. tostring(err)
    end

    return true, nil
end

-- Check whether the registry is older than the TTL
function M.is_stale()
    return (os.time() - M.get_last_fetch()) >= M.CACHE_TTL_SECONDS
end

-- Age in seconds of the currently held lock, nil when it carries no timestamp
function M.lock_age()
    local content = read_file(M.get_lock_path() .. "/created_at")
    local created_at = tonumber(content and content:match("%d+"))
    if not created_at then
        return nil
    end

    return os.time() - created_at
end

local function get_lock_owner()
    return read_file(M.get_lock_path() .. "/owner")
end

-- Move a lock we still own away from the shared path before deleting it.
-- The inner directory serialises all removers; re-checking ownership and age
-- after acquiring it prevents a delayed owner or stale-lock waiter from
-- deleting a successor's lock.
local function retire_lock(expected_owner, stale_only)
    local lock_path = M.get_lock_path()
    local removing_path = lock_path .. "/.removing"
    if expected_owner == nil then
        return false
    end

    if not shell("mkdir " .. quote(removing_path) .. " 2>/dev/null") then
        return false
    end

    local owner = get_lock_owner()
    local age = M.lock_age()
    local may_remove = owner == expected_owner and (not stale_only or age == nil or age > M.LOCK_STALE_SECONDS)

    if not may_remove then
        shell("rmdir " .. quote(removing_path) .. " 2>/dev/null")
        return false
    end

    local retired_path = lock_path .. ".retired." .. unique_token()
    if not os.rename(lock_path, retired_path) then
        shell("rmdir " .. quote(removing_path) .. " 2>/dev/null")
        return false
    end

    shell("rm -rf " .. quote(retired_path))
    return true
end

-- Release only the lock identified by this owner's token.
function M.release_lock(owner)
    return retire_lock(owner, false)
end

-- Run `fn` with exclusive access to the registry directory.
-- `mkdir` without `-p` is atomic on POSIX: it succeeds for exactly one caller
-- and fails for every other, which is what makes it usable as a mutex between
-- the concurrent mise jobs sharing this plugin directory.
function M.with_lock(fn)
    local lock_path = M.get_lock_path()
    local acquire = "mkdir " .. quote(lock_path) .. " 2>/dev/null"
    local deadline = os.time() + M.LOCK_TIMEOUT_SECONDS
    local unstamped_for = 0

    while not shell(acquire) do
        local age = M.lock_age()
        local owner = get_lock_owner()
        if age == nil and owner ~= nil then
            -- The owner identity is written before the timestamp. Once it is
            -- present, the lock can be reclaimed without confusing it with a
            -- newly created, not-yet-identified successor.
            unstamped_for = unstamped_for + 1
        else
            unstamped_for = 0
        end

        local should_reclaim = (age and age > M.LOCK_STALE_SECONDS) or unstamped_for > M.LOCK_UNSTAMPED_RETRIES
        local reclaimed = should_reclaim and retire_lock(owner, true)

        if not reclaimed and os.time() >= deadline then
            return nil, "Timed out waiting for the registry lock at " .. lock_path
        elseif not reclaimed then
            shell(M.LOCK_RETRY_COMMAND)
        end
    end

    local owner = unique_token()
    local owned, owner_err = write_file(lock_path .. "/owner", owner)
    if not owned then
        shell("rm -rf " .. quote(lock_path))
        return nil, "Failed to identify the registry lock owner: " .. tostring(owner_err)
    end

    local stamped, stamp_err = write_file(lock_path .. "/created_at", tostring(os.time()))
    if not stamped then
        M.release_lock(owner)
        return nil, "Failed to timestamp the registry lock: " .. tostring(stamp_err)
    end

    local ok, result, err = pcall(fn)
    M.release_lock(owner)

    if not ok then
        return nil, tostring(result)
    end

    return result, err
end

-- Ensure registry is cloned and up to date
function M.ensure_fresh()
    if M.exists() and not M.is_stale() then
        return true, nil
    end

    -- Every mise job resolving a `krew:` tool reaches this point at the same
    -- time on the same clone. Unserialised, their git invocations interleave
    -- and git aborts with errors such as "cannot lock ref
    -- 'refs/remotes/origin/master'" or "Cannot rebase onto multiple branches".
    return M.with_lock(function()
        -- Re-check under the lock: whoever held it has usually just done the
        -- work, leaving nothing to do here.
        if not M.exists() then
            return M.clone()
        end

        if M.is_stale() then
            return M.refresh()
        end

        return true, nil
    end)
end

-- Clone the registry repository.
-- Callers must hold the registry lock (see `M.with_lock`).
function M.clone()
    local registry_path = M.get_registry_path()

    -- Clone aside and move into place, so an interrupted clone can never be
    -- mistaken for a usable registry by the next run.
    local temp_path = registry_path .. ".incomplete"
    shell("rm -rf " .. quote(temp_path))

    local _, err = git(string.format("clone --quiet %s %s", M.REPO_URL, quote(temp_path)))
    if err then
        shell("rm -rf " .. quote(temp_path))
        return nil, "Failed to clone registry: " .. err
    end

    shell("rm -rf " .. quote(registry_path))
    if not os.rename(temp_path, registry_path) then
        shell("rm -rf " .. quote(temp_path))
        return nil, "Failed to move the registry into place: " .. registry_path
    end

    local marked, mark_err = M.mark_fetched()
    if not marked then
        return nil, mark_err
    end

    return true, nil
end

-- Force refresh the registry.
-- Callers must hold the registry lock (see `M.with_lock`).
function M.refresh()
    local registry_path = M.get_registry_path()

    local _, fetch_err = git("fetch --prune --quiet origin", registry_path)
    if fetch_err then
        return nil, "Failed to refresh registry: " .. fetch_err
    end

    -- `git pull` would merge or rebase according to the user's git
    -- configuration (`pull.rebase`, `pull.ff`, ...), which has no say over how
    -- a read-only mirror is updated. Move to the fetched tip instead.
    local _, reset_err = git("reset --hard --quiet origin/master", registry_path)
    if reset_err then
        return nil, "Failed to reset registry to origin/master: " .. reset_err
    end

    local marked, mark_err = M.mark_fetched()
    if not marked then
        return nil, mark_err
    end

    return true, nil
end

-- Get current HEAD commit hash
function M.get_head()
    local cmd = require("cmd")
    local registry_path = M.get_registry_path()

    local result = cmd.exec("git rev-parse HEAD", { cwd = registry_path })
    result = result:gsub("%s+$", "") -- trim whitespace

    if result == "" or result:match("fatal") then
        return nil, "Failed to get HEAD"
    end

    return result, nil
end

-- Get git log for a specific plugin file
-- Returns iterator over commit hashes
function M.get_file_history(plugin_name)
    local cmd = require("cmd")
    local registry_path = M.get_registry_path()

    local plugin_path = "plugins/" .. plugin_name .. ".yaml"
    local log_cmd = string.format("git --no-pager log --format=%%H --no-show-signature -- %s 2>/dev/null", plugin_path)

    local result = cmd.exec(log_cmd, { cwd = registry_path })

    if result == "" or result:match("fatal") then
        return nil, "Failed to get file history for: " .. plugin_name
    end

    local lines = {}
    for line in result:gmatch("[^\r\n]+") do
        line = line:match("^%s*(.-)%s*$")
        if line ~= "" and #line == 40 and line:match("^[0-9a-fA-F]+") then
            table.insert(lines, line)
        end
    end

    local i = 0
    return function()
        i = i + 1
        return lines[i]
    end
end

-- Get manifest content at a specific commit
function M.get_manifest_at_commit(plugin_name, commit_hash)
    local cmd = require("cmd")
    local registry_path = M.get_registry_path()

    local plugin_path = "plugins/" .. plugin_name .. ".yaml"
    local show_cmd = string.format("git show %s:%s", commit_hash, plugin_path)

    local ok, result = pcall(cmd.exec, show_cmd, { cwd = registry_path })
    if not ok then
        return nil, "Failed to get manifest at commit " .. commit_hash .. ": " .. tostring(result)
    end

    return result, nil
end

-- Get the current manifest (latest version)
function M.get_current_manifest(plugin_name)
    local file = require("file")
    local registry_path = M.get_registry_path()

    local plugin_path = file.join_path(registry_path, "plugins", plugin_name .. ".yaml")

    if not file.exists(plugin_path) then
        return nil, "Plugin not found in registry: " .. plugin_name
    end

    local content = file.read(plugin_path)
    if not content then
        return nil, "Failed to read manifest for: " .. plugin_name
    end

    return content, nil
end

-- Check if a plugin exists in the registry
function M.plugin_exists(plugin_name)
    local file = require("file")
    local registry_path = M.get_registry_path()

    local plugin_path = file.join_path(registry_path, "plugins", plugin_name .. ".yaml")
    return file.exists(plugin_path)
end

return M
