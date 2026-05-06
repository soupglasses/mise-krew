#!/usr/bin/env lua

package.path = package.path .. ";./lib/?.lua;./tests/?.lua"

_G.file = {
    join_path = function(...)
        return table.concat({ ... }, "/")
    end,
    dirname = function(path)
        return path:match("^(.*)/[^/]+$") or "."
    end,
    exists = function(path)
        local f = io.open(path, "r")
        if f then
            f:close()
            return true
        end
        return false
    end,
    read = function(path)
        local f = io.open(path, "r")
        if not f then
            return nil
        end
        local content = f:read("*all")
        f:close()
        return content
    end,
    get_modified_time = function(_)
        return os.time()
    end,
}

_G.cmd = {
    exec = function(_, _)
        return ""
    end,
}

_G.RUNTIME = {
    pluginDirPath = ".",
}

local framework = require("framework")
local suites = {
    (require("test_manifest")),
    (require("test_installer")),
}

local ok = true
for _, suite in ipairs(suites) do
    if not framework.run(suite) then
        ok = false
    end
end

os.exit(ok and 0 or 1)
