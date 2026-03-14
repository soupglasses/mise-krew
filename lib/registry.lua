-- lib/registry.lua
-- Git registry wrapper for krew-index operations
-- Manages local clone and provides access to manifest history

local M = {}

-- Registry configuration
M.REPO_URL = "https://github.com/kubernetes-sigs/krew-index.git"
M.REGISTRY_DIR = "registry"
M.CACHE_TTL_SECONDS = 86400 -- 24 hours

-- Get the path to the registry directory
function M.get_registry_path()
    local file = require("file")
    return file.join_path(RUNTIME.pluginDirPath, M.REGISTRY_DIR)
end

-- Check if registry exists locally
function M.exists()
    local file = require("file")
    local registry_path = M.get_registry_path()
    return file.exists(registry_path) and file.exists(file.join_path(registry_path, ".git"))
end

-- Ensure registry is cloned and up to date
function M.ensure_fresh()
    if not M.exists() then
        return M.clone()
    end

    return M.refresh_if_stale()
end

-- Clone the registry repository
function M.clone()
    local cmd = require("cmd")

    local registry_path = M.get_registry_path()

    local clone_cmd = string.format("git clone %s %s", M.REPO_URL, registry_path)
    local result = cmd.exec(clone_cmd)

    if result:match("error") or result:match("fatal") then
        return nil, "Failed to clone registry: " .. result
    end

    return true, nil
end

-- Refresh registry if stale (older than TTL)
function M.refresh_if_stale()
    local cmd = require("cmd")
    local registry_path = M.get_registry_path()

    local last_fetch = cmd.exec("git log -1 --format=%ct HEAD 2>/dev/null || echo 0", { cwd = registry_path })
    last_fetch = tonumber(last_fetch:match("^%s*(%d+)%s*$")) or 0
    local now = os.time()

    if last_fetch > 0 and (now - last_fetch) < M.CACHE_TTL_SECONDS then
        return true, nil
    end

    return M.refresh()
end

-- Force refresh the registry
function M.refresh()
    local cmd = require("cmd")
    local registry_path = M.get_registry_path()

    -- Fetch from origin
    local fetch_result = cmd.exec("git fetch --prune origin", { cwd = registry_path })

    -- Pull changes safely
    cmd.exec("git checkout master", { cwd = registry_path })
    local pull_result = cmd.exec("git pull --ff-only", { cwd = registry_path })

    if pull_result:match("error") and pull_result:match("fatal") then
        return nil, "Failed to refresh registry: " .. pull_result
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
    local log_cmd =
        string.format("git --no-pager log --format=%%H --no-show-signature --follow -- %s 2>/dev/null", plugin_path)

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

    local result = cmd.exec(show_cmd, { cwd = registry_path })

    if result:match("fatal") or result:match("error") then
        return nil, "Failed to get manifest at commit " .. commit_hash
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
