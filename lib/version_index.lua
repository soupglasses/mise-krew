-- lib/version_index.lua
-- Version index extraction and caching from git history

local M = {}

M.CACHE_SCHEMA_VERSION = 1
M.CACHE_TTL_SECONDS = 86400 -- 24 hours

-- Get cache directory path
function M.get_cache_dir()
    local file = require("file")
    return file.join_path(RUNTIME.pluginDirPath, "cache")
end

-- Get cache file path for a tool
function M.get_cache_path(tool)
    local file = require("file")
    return file.join_path(M.get_cache_dir(), tool .. ".json")
end

-- Ensure cache directory exists
function M.ensure_cache_dir()
    local file = require("file")
    local cache_dir = M.get_cache_dir()
    if not file.exists(cache_dir) then
        os.execute("mkdir -p " .. cache_dir)
    end
    return cache_dir
end

-- Build version index for a tool from git history
function M.build_index(tool)
    local registry = require("registry")
    local manifest = require("manifest")

    -- Ensure registry is available
    local registry_ok, registry_err = registry.ensure_fresh()
    if not registry_ok then
        return nil, "Failed to ensure registry: " .. tostring(registry_err)
    end

    -- Get current HEAD
    local head, head_err = registry.get_head()
    if not head then
        return nil, "Failed to get registry HEAD: " .. tostring(head_err)
    end

    -- Get file history
    local commits_iter, history_err = registry.get_file_history(tool)
    if not commits_iter then
        return nil, "Failed to get file history: " .. tostring(history_err)
    end

    local versions = {}
    local commits_by_version = {}
    local seen = {}

    for commit_hash in commits_iter do
        local yaml_str, _ = registry.get_manifest_at_commit(tool, commit_hash)
        if yaml_str then
            local version, _ = manifest.parse_version(yaml_str)
            if version and not seen[version] then
                table.insert(versions, version)
                commits_by_version[version] = commit_hash
                seen[version] = true
            end
        end
    end

    if #versions == 0 then
        return nil, "No versions found for tool: " .. tool
    end

    -- Sort versions ascending (oldest first, newest last) for mise compatibility
    table.sort(versions, function(a, b)
        local na = a:match("^v?(.*)$")
        local nb = b:match("^v?(.*)$")
        local pa, pb = {}, {}
        for p in na:gmatch("[^.-]+") do
            table.insert(pa, tonumber(p) or p)
        end
        for p in nb:gmatch("[^.-]+") do
            table.insert(pb, tonumber(p) or p)
        end
        for i = 1, math.max(#pa, #pb) do
            local ap = pa[i] or 0
            local bp = pb[i] or 0
            if type(ap) == "number" and type(bp) == "number" then
                if ap ~= bp then
                    return ap < bp
                end
            else
                local sa, sb = tostring(ap), tostring(bp)
                if sa ~= sb then
                    return sa < sb
                end
            end
        end
        return false
    end)

    local index = {
        schema_version = M.CACHE_SCHEMA_VERSION,
        tool = tool,
        registry_head = head,
        generated_at = os.time(),
        versions = versions,
        commits_by_version = commits_by_version,
    }

    return index, nil
end

-- Load cached index for a tool
function M.load_cached(tool)
    local file = require("file")
    local json = require("json")

    local cache_path = M.get_cache_path(tool)
    if not file.exists(cache_path) then
        return nil
    end

    local content = file.read(cache_path)
    if not content then
        return nil
    end

    local ok, cache = pcall(json.decode, content)
    if not ok or not cache then
        return nil
    end

    -- Validate schema version
    if cache.schema_version ~= M.CACHE_SCHEMA_VERSION then
        return nil
    end

    -- Check if cache is stale
    local age = os.time() - (cache.generated_at or 0)
    if age > M.CACHE_TTL_SECONDS then
        return nil
    end

    -- Check if registry HEAD has changed
    local registry = require("registry")
    if registry.exists() then
        local current_head, _ = registry.get_head()
        if current_head and current_head ~= cache.registry_head then
            return nil
        end
    end

    return cache
end

-- Save index to cache
function M.save_cache(index)
    local file = require("file")
    local json = require("json")

    M.ensure_cache_dir()

    local cache_path = M.get_cache_path(index.tool)
    local content = json.encode(index)

    local f = io.open(cache_path, "w")
    if f then
        f:write(content)
        f:close()
        return true
    end

    return false
end

-- Get version index for a tool (with caching)
function M.get_index(tool)
    -- Try to load from cache first
    local cached = M.load_cached(tool)
    if cached then
        return cached, nil
    end

    -- Build fresh index
    local index, err = M.build_index(tool)
    if not index then
        return nil, err
    end

    -- Save to cache
    M.save_cache(index)

    return index, nil
end

-- Get list of versions for a tool
function M.get_versions(tool)
    local index, err = M.get_index(tool)
    if not index then
        return nil, err
    end

    return index.versions, nil
end

-- Resolve a version request to a canonical version
-- Handles "latest" and normalizes version strings
function M.resolve_version(tool, requested_version)
    local index, err = M.get_index(tool)
    if not index then
        return nil, err
    end

    if requested_version == "latest" then
        if #index.versions > 0 then
            local latest = index.versions[#index.versions]
            return latest, index.commits_by_version[latest]
        else
            return nil, "No versions available"
        end
    end

    -- Normalize the requested version (strip 'v' prefix for comparison)
    local normalized_request = requested_version:match("^v?(.*)$")

    -- Try exact match first
    for _, version in ipairs(index.versions) do
        if version == requested_version then
            return version, index.commits_by_version[version]
        end
    end

    -- Try without 'v' prefix
    for _, version in ipairs(index.versions) do
        local normalized_version = version:match("^v?(.*)$")
        if normalized_version == normalized_request then
            return version, index.commits_by_version[version]
        end
    end

    return nil, "Version not found: " .. requested_version
end

-- Get commit hash for a specific version
function M.get_commit_for_version(tool, version)
    local index, err = M.get_index(tool)
    if not index then
        return nil, err
    end

    local resolved_version, commit_hash = M.resolve_version(tool, version)
    if not resolved_version then
        return nil, commit_hash -- error message
    end

    return commit_hash, nil
end

return M
