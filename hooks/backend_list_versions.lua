function PLUGIN:BackendListVersions(ctx)
    local tool = ctx.tool
    local diagnostics = require("diagnostics")

    if not tool or tool == "" then
        diagnostics.fail("tool name cannot be empty")
    end

    local version_index = require("version_index")

    local versions, err = version_index.get_versions(tool)
    if not versions then
        diagnostics.fail(tostring(err))
    end

    if #versions == 0 then
        diagnostics.fail("no versions found for krew:" .. tool)
    end

    return { versions = versions }
end
