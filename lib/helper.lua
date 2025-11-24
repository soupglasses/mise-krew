local M = {}

function M.command_exists(bin)
    local check_cmd = "command -v " .. bin .. " >/dev/null 2>&1"
    local ok = os.execute(check_cmd)

    return ok == 0
end

return M
