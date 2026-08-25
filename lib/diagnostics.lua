-- User-facing diagnostics for mise-krew hooks.

local M = {}

function M.format(message)
    local version = PLUGIN and PLUGIN.version or "unknown"
    return "mise-krew " .. tostring(version) .. ": " .. message
end

function M.fail(message)
    error(M.format(message), 0)
end

return M
