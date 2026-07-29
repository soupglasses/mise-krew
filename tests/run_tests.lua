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
        -- `io.open` cannot open directories everywhere; renaming a path onto
        -- itself succeeds for anything that exists.
        return os.rename(path, path) == true
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

-- Expose the fake plugin environment through `require`, the way the modules
-- reach it at runtime. The tables are shared, so a test can stub a single
-- function on them.
package.preload["file"] = function()
    return _G.file
end
package.preload["cmd"] = function()
    return _G.cmd
end

local framework = require("framework")
local suites = {
    (require("test_manifest")),
    (require("test_installer")),
    (require("test_registry")),
}

local ok = true
for _, suite in ipairs(suites) do
    if not framework.run(suite) then
        ok = false
    end
end

os.exit(ok and 0 or 1)
