-- tests/test_manifest.lua
-- Unit tests for manifest parser

local M = {}

-- Simple test framework
local tests = {}
local failures = {}

function M.test(name, fn)
    table.insert(tests, { name = name, fn = fn })
end

function M.assert_equals(actual, expected, msg)
    if actual ~= expected then
        error(
            string.format(
                "%s: expected '%s', got '%s'",
                msg or "Assertion failed",
                tostring(expected),
                tostring(actual)
            )
        )
    end
end

function M.assert_not_nil(value, msg)
    if value == nil then
        error(msg or "Expected non-nil value")
    end
end

function M.assert_table_has_key(table, key, msg)
    if table[key] == nil then
        error(string.format("%s: missing key '%s'", msg or "Assertion failed", key))
    end
end

function M.run_all()
    print("Running manifest parser tests...")
    print(string.rep("=", 50))

    local passed = 0
    local failed = 0

    for _, test in ipairs(tests) do
        local ok, test_err = pcall(test.fn)
        if ok then
            print("✓ " .. test.name)
            passed = passed + 1
        else
            print("✗ " .. test.name)
            print("  Error: " .. tostring(test_err))
            failed = failed + 1
        end
    end

    print(string.rep("=", 50))
    print(string.format("Results: %d passed, %d failed", passed, failed))

    return failed == 0
end

function M.load_fixture(name)
    local path = "tests/fixtures/manifests/" .. name .. ".yaml"

    local f = io.open(path, "r")
    if not f then
        error("Could not open fixture: " .. path)
    end

    local content = f:read("*all")
    f:close()

    return content
end

-- Test: Parse browse-pvc manifest
M.test("browse-pvc: parse basic fields", function()
    local manifest = require("manifest")
    local yaml = M.load_fixture("browse-pvc")

    local result, parse_err = manifest.parse(yaml)
    M.assert_not_nil(result, "Parse failed: " .. tostring(parse_err))

    M.assert_equals(result.name, "browse-pvc", "name mismatch")
    M.assert_equals(result.version, "v1.4.1", "version mismatch")
    M.assert_not_nil(result.homepage, "missing homepage")
    M.assert_equals(#result.platforms, 4, "expected 4 platforms")
end)

-- Test: Parse ctx manifest with files[]
M.test("ctx: parse with matchExpressions and files", function()
    local manifest = require("manifest")
    local yaml = M.load_fixture("ctx")

    local result, parse_err = manifest.parse(yaml)
    M.assert_not_nil(result, "Parse failed: " .. tostring(parse_err))

    M.assert_equals(result.name, "ctx", "name mismatch")
    M.assert_equals(result.version, "v0.9.5", "version mismatch")
    M.assert_equals(#result.platforms, 1, "expected 1 platform")

    local platform = result.platforms[1]
    M.assert_not_nil(platform.selector.matchExpressions, "missing matchExpressions")
    M.assert_equals(#platform.files, 2, "expected 2 files")
end)

-- Test: Parse tree manifest with multiple platforms
M.test("tree: parse multiple platforms", function()
    local manifest = require("manifest")
    local yaml = M.load_fixture("tree")

    local result, parse_err = manifest.parse(yaml)
    M.assert_not_nil(result, "Parse failed: " .. tostring(parse_err))

    M.assert_equals(result.name, "tree", "name mismatch")
    M.assert_equals(result.version, "v0.4.6", "version mismatch")
    M.assert_equals(#result.platforms, 5, "expected 5 platforms")

    -- Check Windows platform has .exe extension
    local found_windows = false
    for _, p in ipairs(result.platforms) do
        if p.bin == "kubectl-tree.exe" then
            found_windows = true
            break
        end
    end
    M.assert_equals(found_windows, true, "missing Windows platform with .exe")
end)

-- Test: Platform selection for Darwin/AMD64
M.test("platform selection: darwin/amd64", function()
    local manifest = require("manifest")
    local yaml = M.load_fixture("browse-pvc")

    local result, parse_err = manifest.parse(yaml)
    M.assert_not_nil(result, "Parse failed: " .. tostring(parse_err))

    local platform, platform_err = manifest.select_platform(result, "darwin", "amd64")
    M.assert_not_nil(platform, "Platform selection failed: " .. tostring(platform_err))
    M.assert_not_nil(platform.uri, "missing uri")
    M.assert_not_nil(platform.sha256, "missing sha256")
end)

-- Test: Platform selection for Linux/ARM64
M.test("platform selection: linux/arm64", function()
    local manifest = require("manifest")
    local yaml = M.load_fixture("tree")

    local result, parse_err = manifest.parse(yaml)
    M.assert_not_nil(result, "Parse failed: " .. tostring(parse_err))

    local platform, platform_err = manifest.select_platform(result, "linux", "arm64")
    M.assert_not_nil(platform, "Platform selection failed: " .. tostring(platform_err))
    M.assert_equals(platform.bin, "kubectl-tree", "bin mismatch")
end)

-- Test: Platform selection with matchExpressions
M.test("platform selection: matchExpressions In", function()
    local manifest = require("manifest")
    local yaml = M.load_fixture("ctx")

    local result, parse_err = manifest.parse(yaml)
    M.assert_not_nil(result, "Parse failed: " .. tostring(parse_err))

    -- ctx uses matchExpressions with "In" operator for darwin/linux
    local platform, platform_err = manifest.select_platform(result, "darwin", "amd64")
    M.assert_not_nil(platform, "Darwin selection failed: " .. tostring(platform_err))

    local platform2, err2 = manifest.select_platform(result, "linux", "amd64")
    M.assert_not_nil(platform2, "Linux selection failed: " .. tostring(err2))
end)

-- Test: Platform selection failure for unsupported platform
M.test("platform selection: unsupported platform", function()
    local manifest = require("manifest")
    local yaml = M.load_fixture("browse-pvc")

    local result, parse_err = manifest.parse(yaml)
    M.assert_not_nil(result, "Parse failed: " .. tostring(parse_err))

    -- browse-pvc doesn't support windows
    local platform, _ = manifest.select_platform(result, "windows", "amd64")
    if platform ~= nil then
        error("Should not find platform for Windows")
    end
end)

-- Test: Version extraction
M.test("version extraction: browse-pvc", function()
    local manifest = require("manifest")
    local yaml = M.load_fixture("browse-pvc")

    local version, version_err = manifest.parse_version(yaml)
    M.assert_not_nil(version, "Version extraction failed: " .. tostring(version_err))
    M.assert_equals(version, "v1.4.1", "version mismatch")
end)

-- Test: OS normalization
M.test("OS normalization", function()
    local manifest = require("manifest")

    M.assert_equals(manifest.normalize_os("macos"), "darwin")
    M.assert_equals(manifest.normalize_os("osx"), "darwin")
    M.assert_equals(manifest.normalize_os("DARWIN"), "darwin")
    M.assert_equals(manifest.normalize_os("linux"), "linux")
    M.assert_equals(manifest.normalize_os("windows"), "windows")
end)

-- Test: Arch normalization
M.test("Arch normalization", function()
    local manifest = require("manifest")

    M.assert_equals(manifest.normalize_arch("x86_64"), "amd64")
    M.assert_equals(manifest.normalize_arch("x64"), "amd64")
    M.assert_equals(manifest.normalize_arch("AMD64"), "amd64")
    M.assert_equals(manifest.normalize_arch("arm64"), "arm64")
    M.assert_equals(manifest.normalize_arch("aarch64"), "arm64")
end)

-- Test: Invalid YAML handling
M.test("error handling: invalid yaml", function()
    local manifest = require("manifest")

    local result, _ = manifest.parse("not: valid: yaml: [")
    if result ~= nil then
        error("Should fail on invalid YAML")
    end
end)

-- Test: Missing required fields
M.test("error handling: missing version", function()
    local manifest = require("manifest")

    local yaml = [[
apiVersion: krew.googlecontainertools.github.com/v1alpha2
kind: Plugin
metadata:
  name: test
spec:
  homepage: https://example.com
]]

    local result, _ = manifest.parse(yaml)
    if result ~= nil then
        error("Should fail on missing version")
    end
end)

-- Run all tests
return M
