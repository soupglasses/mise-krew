#!/usr/bin/env lua

package.path = package.path .. ";./lib/?.lua"

local registry_path = arg[1] or "registry"
local registry_ref = "refs/remotes/origin/master"
local git = string.format("git -C %q -c core.fsmonitor=false", registry_path)

local revision_command = git .. string.format(" rev-parse --verify %q", registry_ref .. "^{commit}")
local revision_process = assert(io.popen(revision_command))
local revision = revision_process:read("*all"):match("^%s*(%x+)%s*$")
local revision_ok, _, revision_status = revision_process:close()
if not revision_ok or not revision then
    io.stderr:write("Failed to resolve " .. registry_ref .. " (status " .. tostring(revision_status) .. ")\n")
    os.exit(1)
end

local list_command = git .. string.format(" ls-tree -r --name-only %q -- plugins", revision)
local paths = assert(io.popen(list_command))
local manifest = require("manifest")
local failures = {}
local total = 0

for relative_path in paths:lines() do
    if relative_path:match("%.yaml$") then
        total = total + 1
        local object = revision .. ":" .. relative_path
        local read_command = git .. string.format(" cat-file blob %q", object)
        local file = assert(io.popen(read_command))
        local source = file:read("*all")
        local read_ok, _, read_status = file:close()
        if not read_ok then
            table.insert(failures, relative_path .. ": failed to read blob (status " .. tostring(read_status) .. ")")
        else
            local result, parse_err = manifest.parse(source)
            if not result then
                table.insert(failures, relative_path .. ": " .. tostring(parse_err))
            end
        end
    end
end

local listed_ok, _, list_status = paths:close()
if not listed_ok then
    io.stderr:write("Failed to list registry manifests (status " .. tostring(list_status) .. ")\n")
    os.exit(1)
end

if total == 0 then
    io.stderr:write("No registry manifests found under " .. registry_path .. "/plugins\n")
    os.exit(1)
end

if #failures > 0 then
    io.stderr:write(string.format("Failed to parse %d of %d registry manifests:\n", #failures, total))
    for _, failure in ipairs(failures) do
        io.stderr:write("  " .. failure .. "\n")
    end
    os.exit(1)
end

print(string.format("Parsed %d registry manifests", total))
