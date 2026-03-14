function PLUGIN:BackendListVersions(ctx)
    local tool = ctx.tool

    if not tool or tool == "" then
        error("Tool name cannot be empty")
    end

    local version_index = require("version_index")

    local versions, err = version_index.get_versions(tool)
    if not versions then
        error("Failed to get versions for '" .. tool .. "': " .. tostring(err))
    end

    if #versions == 0 then
        error("No versions found for " .. tool)
    end

    return { versions = versions }
end
