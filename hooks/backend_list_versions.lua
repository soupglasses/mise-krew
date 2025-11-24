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

    -- Example implementations (choose/modify based on your backend):

    -- Example 1: API-based version listing (like npm, pip, cargo)
    --[[
    local http = require("http")
    local json = require("json")

    -- Replace with your backend's API endpoint
    local api_url = "https://api.<BACKEND>.org/packages/" .. tool .. "/versions"

    local resp, err = http.get({
        url = api_url,
        -- headers = { ["Authorization"] = "Bearer " .. token } -- if needed
    })

    if err then
        error("Failed to fetch versions for " .. tool .. ": " .. err)
    end

    if resp.status_code ~= 200 then
        error("API returned status " .. resp.status_code .. " for " .. tool)
    end

    local data = json.decode(resp.body)
    local versions = {}

    -- Parse versions from API response (adjust based on your API structure)
    if data.versions then
        for _, version in ipairs(data.versions) do
            table.insert(versions, version)
        end
    end
    --]]

    -- Example 2: Command-line based version listing
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

    -- Example 3: Registry file parsing
    --[[
    local file = require("file")

    -- Replace with path to your backend's registry or manifest
    local registry_path = "/path/to/<BACKEND>/registry/" .. tool .. ".json"

    if not file.exists(registry_path) then
        error("Tool " .. tool .. " not found in registry")
    end

    local content = file.read(registry_path)
    local data = json.decode(content)
    local versions = data.versions or {}
    --]]

    if #versions == 0 then
        error("No versions found for " .. tool)
    end

    return { versions = versions }
end
