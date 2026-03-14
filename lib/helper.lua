local M = {}

function M.command_exists(bin)
    local check_cmd = "command -v " .. bin .. " >/dev/null 2>&1"
    local ok = os.execute(check_cmd)

    return ok == 0
end

function M.split_on_newlines(str)
    if string.sub(str, -1) ~= "\n" then
        str = str .. "\n"
    end
    return string.gmatch(str, "([^\n]*)\n")
end

function M.ensure_registry()
    local file = require("file")

    local registry_path = file.join_path(RUNTIME.pluginDirPath, "registry")

    if not file.exists(registry_path) then
        -- TODO: Error handling
        os.execute("git clone https://github.com/kubernetes-sigs/krew-index.git " .. registry_path)
    end

    return registry_path
end

function M.update_registry()
    local cmd = require("cmd")
    local registry_path = M.ensure_registry()
    cmd.exec("git pull", { cwd = registry_path })
end

function M.git_versions_of(path, repository)
    -- Returns an iterator for the given file in a git repository from latest to oldest.
    -- Each iteration's output is the file's content at its nth version.
    local cmd = require("cmd")

    local git_hashes = cmd.exec("git log --format=%H --follow " .. path, { cwd = repository })

    return M.split_on_newlines(git_hashes)
    -- TODO: return output of "git show " .. hash .. ":" .. path`
end

function M.versions_for(package)
    local file = require("file")

    local registry_path = M.ensure_registry()

    local package_path = file.join_path("plugins", package .. ".yaml")

    for _ in M.git_versions_of(package_path, registry_path) do
        -- 1. Try except tinyyaml parsing.
        -- 2. Assert kind and version of yaml is correct.
        -- 3. Read version, add to list.
    end
    -- 4. Return full list of versions.
end

-- download_package(package, version, type, arch)
-- Should use get_versions_of or similar to find its version of the file.
-- Should have a general lookup table for type (linux, macos, windows) and arch (x86, x64, arm).
-- Returns the tuple of information like what vfox expects.

return M
