#!/usr/bin/env lua

package.path = package.path .. ";./lib/?.lua"

local plugin_path, repo_url, command_log = ...
local fail_canonical_update = os.getenv("MISE_KREW_FAIL_CANONICAL_UPDATE") == "1"

local function quote(value)
    return "'" .. tostring(value):gsub("'", "'\\''") .. "'"
end

local file = {
    join_path = function(...)
        return table.concat({ ... }, "/")
    end,
    exists = function(path)
        local handle = io.open(path, "r")
        if handle then
            handle:close()
            return true
        end
        return os.rename(path, path) == true
    end,
    read = function(path)
        local handle = io.open(path, "r")
        if not handle then
            return nil
        end
        local content = handle:read("*all")
        handle:close()
        return content
    end,
}

local cmd = {
    exec = function(command, options)
        if command_log then
            local log = assert(io.open(command_log, "a"))
            log:write(command, "\n")
            log:close()
        end

        if fail_canonical_update and command:find("update-ref 'refs/remotes/origin/master'", 1, true) then
            error("injected canonical update-ref failure")
        end

        if options and options.cwd then
            command = "cd " .. quote(options.cwd) .. " && " .. command
        end
        local handle = assert(io.popen(command .. " 2>&1"))
        local output = handle:read("*all")
        local ok, _, code = handle:close()
        if not ok then
            error(output ~= "" and output or "command exited with " .. tostring(code))
        end
        return output
    end,
}

package.preload["file"] = function()
    return file
end
package.preload["cmd"] = function()
    return cmd
end
_G.RUNTIME = { pluginDirPath = plugin_path }

local registry = require("registry")
registry.REPO_URL = repo_url
registry.CACHE_TTL_SECONDS = 0
registry.FETCH_RETRIES = 50
registry.BOOTSTRAP_LEASE_SECONDS = tonumber(os.getenv("MISE_KREW_BOOTSTRAP_LEASE_SECONDS"))
    or registry.BOOTSTRAP_LEASE_SECONDS
registry.BOOTSTRAP_TIMEOUT_SECONDS = tonumber(os.getenv("MISE_KREW_BOOTSTRAP_TIMEOUT_SECONDS"))
    or registry.BOOTSTRAP_TIMEOUT_SECONDS

local ok, err = registry.ensure_fresh()
if not ok then
    error(err)
end

local manifest, manifest_err = registry.get_current_manifest("demo")
if not manifest or not manifest:find("name: demo", 1, true) then
    error(manifest_err or "failed to read demo from the published ref")
end

local head, head_err = registry.get_head()
local history, history_err
if head then
    history, history_err = registry.get_file_history("demo", head)
end
if not history or history() ~= head then
    error(head_err or history_err or "history was not read from the captured commit")
end
