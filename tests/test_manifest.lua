local M = require("framework").suite("manifest parser")

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

M.test("browse-pvc: parse basic fields", function()
    local manifest = require("manifest")
    local result, parse_err = manifest.parse(M.load_fixture("browse-pvc"))
    M.assert_not_nil(result, "Parse failed: " .. tostring(parse_err))

    M.assert_equals(result.name, "browse-pvc", "name mismatch")
    M.assert_equals(result.version, "v1.4.1", "version mismatch")
    M.assert_not_nil(result.homepage, "missing homepage")
    M.assert_equals(#result.platforms, 4, "expected 4 platforms")
end)

M.test("ctx: parse with matchExpressions and files", function()
    local manifest = require("manifest")
    local result, parse_err = manifest.parse(M.load_fixture("ctx"))
    M.assert_not_nil(result, "Parse failed: " .. tostring(parse_err))

    M.assert_equals(result.name, "ctx", "name mismatch")
    M.assert_equals(result.version, "v0.9.5", "version mismatch")
    M.assert_equals(#result.platforms, 1, "expected 1 platform")

    local platform = result.platforms[1]
    M.assert_not_nil(platform.selector.matchExpressions, "missing matchExpressions")
    M.assert_equals(#platform.files, 2, "expected 2 files")
end)

M.test("tree: parse multiple platforms", function()
    local manifest = require("manifest")
    local result, parse_err = manifest.parse(M.load_fixture("tree"))
    M.assert_not_nil(result, "Parse failed: " .. tostring(parse_err))

    M.assert_equals(result.name, "tree", "name mismatch")
    M.assert_equals(result.version, "v0.4.6", "version mismatch")
    M.assert_equals(#result.platforms, 5, "expected 5 platforms")

    local found_windows = false
    for _, p in ipairs(result.platforms) do
        if p.bin == "kubectl-tree.exe" then
            found_windows = true
            break
        end
    end
    M.assert_equals(found_windows, true, "missing Windows platform with .exe")
end)

M.test("platform selection: darwin/amd64", function()
    local manifest = require("manifest")
    local result, parse_err = manifest.parse(M.load_fixture("browse-pvc"))
    M.assert_not_nil(result, "Parse failed: " .. tostring(parse_err))

    local platform, platform_err = manifest.select_platform(result, "darwin", "amd64")
    M.assert_not_nil(platform, "Platform selection failed: " .. tostring(platform_err))
    M.assert_not_nil(platform.uri, "missing uri")
    M.assert_not_nil(platform.sha256, "missing sha256")
end)

M.test("platform selection: linux/arm64", function()
    local manifest = require("manifest")
    local result, parse_err = manifest.parse(M.load_fixture("tree"))
    M.assert_not_nil(result, "Parse failed: " .. tostring(parse_err))

    local platform, platform_err = manifest.select_platform(result, "linux", "arm64")
    M.assert_not_nil(platform, "Platform selection failed: " .. tostring(platform_err))
    M.assert_equals(platform.bin, "kubectl-tree", "bin mismatch")
end)

M.test("platform selection: matchExpressions In", function()
    local manifest = require("manifest")
    local result, parse_err = manifest.parse(M.load_fixture("ctx"))
    M.assert_not_nil(result, "Parse failed: " .. tostring(parse_err))

    local platform, platform_err = manifest.select_platform(result, "darwin", "amd64")
    M.assert_not_nil(platform, "Darwin selection failed: " .. tostring(platform_err))

    local platform2, err2 = manifest.select_platform(result, "linux", "amd64")
    M.assert_not_nil(platform2, "Linux selection failed: " .. tostring(err2))
end)

M.test("volsync v0.15.0: platform after multiline description", function()
    local manifest = require("manifest")
    local result, parse_err = manifest.parse(M.load_fixture("volsync"))
    M.assert_not_nil(result, "Parse failed: " .. tostring(parse_err))
    M.assert_equals(#result.platforms, 2, "expected platforms after description block")

    local platform, platform_err = manifest.select_platform(result, "linux", "amd64")
    M.assert_not_nil(platform, "Platform selection failed: " .. tostring(platform_err))
    M.assert_equals(platform.bin, "kubectl-volsync", "bin mismatch")
end)

M.test("view-secret: parse explicit block scalar indentation", function()
    local manifest = require("manifest")
    local result, parse_err = manifest.parse(M.load_fixture("view-secret"))
    M.assert_not_nil(result, "Parse failed: " .. tostring(parse_err))
    M.assert_equals(result.version, "v0.16.0", "version mismatch")
    M.assert_equals(#result.platforms, 2, "expected platforms after description block")

    local platform, platform_err = manifest.select_platform(result, "linux", "amd64")
    M.assert_not_nil(platform, "Platform selection failed: " .. tostring(platform_err))
    M.assert_equals(platform.bin, "kubectl-view-secret", "bin mismatch")
end)

M.test("platform selection: unsupported platform", function()
    local manifest = require("manifest")
    local result, parse_err = manifest.parse(M.load_fixture("browse-pvc"))
    M.assert_not_nil(result, "Parse failed: " .. tostring(parse_err))

    local platform, _ = manifest.select_platform(result, "windows", "amd64")
    if platform ~= nil then
        error("Should not find platform for Windows")
    end
end)

M.test("version extraction: browse-pvc", function()
    local manifest = require("manifest")
    local version, version_err = manifest.parse_version(M.load_fixture("browse-pvc"))
    M.assert_not_nil(version, "Version extraction failed: " .. tostring(version_err))
    M.assert_equals(version, "v1.4.1", "version mismatch")
end)

M.test("OS normalization", function()
    local manifest = require("manifest")
    M.assert_equals(manifest.normalize_os("macos"), "darwin")
    M.assert_equals(manifest.normalize_os("osx"), "darwin")
    M.assert_equals(manifest.normalize_os("DARWIN"), "darwin")
    M.assert_equals(manifest.normalize_os("linux"), "linux")
    M.assert_equals(manifest.normalize_os("windows"), "windows")
end)

M.test("Arch normalization", function()
    local manifest = require("manifest")
    M.assert_equals(manifest.normalize_arch("x86_64"), "amd64")
    M.assert_equals(manifest.normalize_arch("x64"), "amd64")
    M.assert_equals(manifest.normalize_arch("AMD64"), "amd64")
    M.assert_equals(manifest.normalize_arch("arm64"), "arm64")
    M.assert_equals(manifest.normalize_arch("aarch64"), "arm64")
end)

M.test("error handling: invalid yaml", function()
    local manifest = require("manifest")
    local result, _ = manifest.parse("not: valid: yaml: [")
    if result ~= nil then
        error("Should fail on invalid YAML")
    end
end)

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

return M
