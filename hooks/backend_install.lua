function PLUGIN:BackendInstall(ctx)
    local tool = ctx.tool
    local version = ctx.version
    local install_path = ctx.install_path

    local registry = require("registry")
    local version_index = require("version_index")
    local manifest_parser = require("manifest")
    local installer = require("installer")

    if not tool or tool == "" then
        error("Tool name cannot be empty")
    end
    if not version or version == "" then
        error("Version cannot be empty")
    end
    if not install_path or install_path == "" then
        error("Install path cannot be empty")
    end

    local registry_ok, registry_err = registry.ensure_fresh()
    if not registry_ok then
        error("Failed to ensure registry: " .. tostring(registry_err))
    end

    local resolved_version, commit_hash = version_index.resolve_version(tool, version)
    if not resolved_version then
        error("Failed to resolve version '" .. version .. "' for tool '" .. tool .. "': " .. tostring(commit_hash))
    end

    local yaml_str, manifest_err = registry.get_manifest_at_commit(tool, commit_hash)
    if not yaml_str then
        error(
            "Failed to get manifest for "
                .. tool
                .. " at version "
                .. resolved_version
                .. ": "
                .. tostring(manifest_err)
        )
    end

    local manifest, parse_err = manifest_parser.parse(yaml_str)
    if not manifest then
        error("Failed to parse manifest: " .. tostring(parse_err))
    end

    local platform, platform_err = manifest_parser.select_platform(manifest, RUNTIME.osType, RUNTIME.archType)
    if not platform then
        error(
            "No platform available for " .. RUNTIME.osType .. "/" .. RUNTIME.archType .. ": " .. tostring(platform_err)
        )
    end

    os.execute("mkdir -p " .. install_path)

    local install_ok, install_err = installer.install(platform, install_path)
    if not install_ok then
        error("Installation failed: " .. tostring(install_err))
    end

    return {}
end
