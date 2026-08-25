function PLUGIN:BackendInstall(ctx)
    local tool = ctx.tool
    local version = ctx.version
    local install_path = ctx.install_path

    local diagnostics = require("diagnostics")
    local registry = require("registry")
    local version_index = require("version_index")
    local manifest_parser = require("manifest")
    local installer = require("installer")

    if not tool or tool == "" then
        diagnostics.fail("tool name cannot be empty")
    end
    if not version or version == "" then
        diagnostics.fail("version cannot be empty")
    end
    if not install_path or install_path == "" then
        diagnostics.fail("install path cannot be empty")
    end

    local registry_ok, registry_err = registry.ensure_fresh()
    if not registry_ok then
        diagnostics.fail("failed to ensure registry: " .. tostring(registry_err))
    end

    local resolved_version, commit_hash = version_index.resolve_version(tool, version)
    if not resolved_version then
        diagnostics.fail("failed to resolve krew:" .. tool .. "@" .. version .. ": " .. tostring(commit_hash))
    end

    local yaml_str, manifest_err = registry.get_manifest_at_commit(tool, commit_hash)
    if not yaml_str then
        diagnostics.fail(
            "failed to get manifest for "
                .. tool
                .. " at version "
                .. resolved_version
                .. ": "
                .. tostring(manifest_err)
        )
    end

    local manifest, parse_err = manifest_parser.parse(yaml_str)
    if not manifest then
        diagnostics.fail(
            "failed to parse manifest for krew:" .. tool .. "@" .. resolved_version .. ": " .. tostring(parse_err)
        )
    end

    local platform = manifest_parser.select_platform(manifest, RUNTIME.osType, RUNTIME.archType)
    if not platform then
        diagnostics.fail(
            "no "
                .. RUNTIME.osType
                .. "/"
                .. RUNTIME.archType
                .. " build found for krew:"
                .. tool
                .. "@"
                .. resolved_version
                .. ". Unexpected? Ensure mise-krew is up to date: `mise plugins update krew`"
        )
    end

    os.execute("mkdir -p " .. install_path)

    local install_ok, install_err = installer.install(platform, install_path)
    if not install_ok then
        diagnostics.fail("failed to install krew:" .. tool .. "@" .. resolved_version .. ": " .. tostring(install_err))
    end

    local file = require("file")
    local source = platform.bin and platform.bin:match("[^/]+$")
    local target = source and installer.target_bin_name(tool)
    if source and source ~= target then
        local from = file.join_path(install_path, source)
        if file.exists(from) then
            os.rename(from, file.join_path(install_path, target))
        end
    end

    return {}
end
