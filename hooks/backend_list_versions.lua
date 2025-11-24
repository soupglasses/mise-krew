-- hooks/backend_list_versions.lua
-- Lists available versions for a tool in this backend
-- Documentation: https://mise.jdx.dev/backend-plugin-development.html#backendlistversions

function PLUGIN:BackendListVersions(ctx)
    local tool = ctx.tool

    local file = require("file")
    local krew_root = file.join_path(RUNTIME.pluginDirPath, "root")
    local krew_cmd = "KREW_ROOT=" .. krew_root .. " krew"

    -- Validate tool name
    if not tool or tool == "" then
        error("Tool name cannot be empty")
    end

    -- Command-line based version listing
    local cmd = require("cmd")

    -- Replace with your backend's command to list versions
    local command = krew_cmd .. " update " .. " && " .. krew_cmd .. " info " .. tool
    local result = cmd.exec(command)

    if result:match("not found") then
        error("Failed to fetch versions for " .. tool)
    end

    local versions = {}
    -- Parse command output to extract versions
    -- VERSION: v1.3.0
    for version in result:gmatch("VERSION: (v?[%d%.]+[%w%-]*)") do
        table.insert(versions, version)
    end

    if #versions == 0 then
        error("No versions found for " .. tool)
    end

    return { versions = versions }
end
