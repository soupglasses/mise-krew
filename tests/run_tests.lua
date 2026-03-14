#!/usr/bin/env lua
-- tests/run_tests.lua
-- Simple test runner for unit tests

-- Add lib directory to path
package.path = package.path .. ";./lib/?.lua;./tests/?.lua"

-- Mock the file module for testing
_G.file = {
    join_path = function(...)
        local parts = { ... }
        return table.concat(parts, "/")
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
    get_modified_time = function(path)
        return os.time()
    end,
}

_G.cmd = {
    exec = function(command, opts)
        return ""
    end,
}

_G.RUNTIME = {
    pluginDirPath = ".",
}

-- Load and run tests
print("Loading test modules...")

local ok, test_manifest = pcall(require, "test_manifest")
if not ok then
    print("Failed to load test_manifest:", test_manifest)
    os.exit(1)
end

-- Run all tests
local success = test_manifest.run_all()

if success then
    print("\nAll tests passed!")
    os.exit(0)
else
    print("\nSome tests failed!")
    os.exit(1)
end
