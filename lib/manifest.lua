-- lib/manifest.lua
-- Krew manifest parser and platform selector
-- Parses krew plugin manifests and selects appropriate platform

local M = {}

-- Parse a krew manifest from YAML string
-- Returns structured manifest table or nil, error
function M.parse(yaml_str)
    local yaml = require("yaml")

    local ok, result = pcall(yaml.eval, yaml_str)
    if not ok then
        return nil, "Failed to parse manifest: " .. tostring(result)
    end

    -- Validate required fields
    if not result.apiVersion then
        return nil, "Missing apiVersion in manifest"
    end

    if not result.kind or result.kind ~= "Plugin" then
        return nil, "Invalid or missing kind in manifest"
    end

    if not result.metadata or not result.metadata.name then
        return nil, "Missing metadata.name in manifest"
    end

    if not result.spec then
        return nil, "Missing spec in manifest"
    end

    if not result.spec.version then
        return nil, "Missing spec.version in manifest"
    end

    -- Normalize the manifest structure
    local manifest = {
        name = result.metadata.name,
        version = result.spec.version,
        homepage = result.spec.homepage,
        description = result.spec.description,
        shortDescription = result.spec.shortDescription,
        platforms = {},
    }

    -- Parse platforms
    if result.spec.platforms then
        for _, platform in ipairs(result.spec.platforms) do
            local parsed_platform = M.parse_platform(platform)
            if parsed_platform then
                table.insert(manifest.platforms, parsed_platform)
            end
        end
    end

    return manifest
end

-- Parse a single platform entry
function M.parse_platform(platform)
    if not platform then
        return nil
    end

    local parsed = {
        uri = platform.uri,
        sha256 = platform.sha256,
        bin = platform.bin,
        files = {},
    }

    -- Parse selector
    if platform.selector then
        parsed.selector = {}

        -- Parse matchLabels
        if platform.selector.matchLabels then
            parsed.selector.matchLabels = {}
            for k, v in pairs(platform.selector.matchLabels) do
                parsed.selector.matchLabels[k] = v
            end
        end

        -- Parse matchExpressions
        if platform.selector.matchExpressions then
            parsed.selector.matchExpressions = {}
            for _, expr in ipairs(platform.selector.matchExpressions) do
                table.insert(parsed.selector.matchExpressions, {
                    key = expr.key,
                    operator = expr.operator,
                    values = expr.values or {},
                })
            end
        end
    end

    -- Parse files
    if platform.files then
        for _, file in ipairs(platform.files) do
            table.insert(parsed.files, {
                from = file.from,
                to = file.to,
            })
        end
    end

    return parsed
end

-- Select the best matching platform for the current OS/arch
-- os_type and arch_type should match mise's RUNTIME values
function M.select_platform(manifest, os_type, arch_type)
    if not manifest or not manifest.platforms then
        return nil, "No platforms in manifest"
    end

    -- Normalize OS and arch names
    local normalized_os = M.normalize_os(os_type)
    local normalized_arch = M.normalize_arch(arch_type)

    for _, platform in ipairs(manifest.platforms) do
        if M.platform_matches(platform, normalized_os, normalized_arch) then
            return platform, nil
        end
    end

    return nil, "No matching platform found for " .. os_type .. "/" .. arch_type
end

-- Normalize OS name to krew convention
function M.normalize_os(os)
    local mapping = {
        macos = "darwin",
        osx = "darwin",
        darwin = "darwin",
        linux = "linux",
        windows = "windows",
        win32 = "windows",
        win64 = "windows",
    }

    return mapping[string.lower(os or "")] or os
end

-- Normalize arch name to krew convention
function M.normalize_arch(arch)
    local mapping = {
        x86_64 = "amd64",
        amd64 = "amd64",
        x64 = "amd64",
        arm64 = "arm64",
        aarch64 = "arm64",
        arm = "arm",
        armv7 = "arm",
        i386 = "386",
        x86 = "386",
        ppc64le = "ppc64le",
        s390x = "s390x",
    }

    return mapping[string.lower(arch or "")] or arch
end

-- Check if a platform matches the given OS/arch
function M.platform_matches(platform, os, arch)
    if not platform.selector then
        -- No selector means matches all
        return true
    end

    -- Check matchLabels
    if platform.selector.matchLabels then
        local labels = platform.selector.matchLabels

        if labels.os and labels.os ~= os then
            return false
        end

        if labels.arch and labels.arch ~= arch then
            return false
        end
    end

    -- Check matchExpressions
    if platform.selector.matchExpressions then
        for _, expr in ipairs(platform.selector.matchExpressions) do
            if not M.evaluate_expression(expr, os, arch) then
                return false
            end
        end
    end

    return true
end

-- Evaluate a matchExpression
function M.evaluate_expression(expr, os, arch)
    if not expr.key or not expr.operator then
        return false
    end

    local value
    if expr.key == "os" then
        value = os
    elseif expr.key == "arch" then
        value = arch
    else
        -- Unknown key - fail closed
        return false
    end

    if expr.operator == "In" then
        for _, v in ipairs(expr.values or {}) do
            if v == value then
                return true
            end
        end
        return false
    elseif expr.operator == "NotIn" then
        for _, v in ipairs(expr.values or {}) do
            if v == value then
                return false
            end
        end
        return true
    else
        -- Unsupported operator - fail closed
        return false
    end
end

-- Extract version from manifest (convenience function)
function M.parse_version(yaml_str)
    local manifest, err = M.parse(yaml_str)
    if not manifest then
        return nil, err
    end

    return manifest.version, nil
end

return M
