-- lib/installer.lua
-- Direct download installer with checksum verification and extraction

local M = {}

local function basename(path)
    return path:match("[^/]+$") or path
end

local function get_filename_from_url(url)
    local filename = url:match("[^/]+$")
    if filename then
        filename = filename:match("^([^?#]+)")
    end
    return filename or "artifact"
end

function M.install(platform, install_path)
    local file = require("file")

    local temp_dir = file.join_path(install_path, ".tmp")
    os.execute("mkdir -p " .. temp_dir)

    local filename = get_filename_from_url(platform.uri)
    local artifact_path = file.join_path(temp_dir, filename)

    print("Downloading " .. platform.uri)
    local download_ok, download_err = M.download(platform.uri, artifact_path)
    if not download_ok then
        M.cleanup(temp_dir)
        return nil, "Download failed: " .. tostring(download_err)
    end

    if platform.sha256 then
        local checksum_ok, checksum_err = M.verify_checksum(artifact_path, platform.sha256)
        if not checksum_ok then
            M.cleanup(temp_dir)
            return nil, "Checksum verification failed: " .. tostring(checksum_err)
        end
    end

    local is_archive = M.is_archive(platform.uri)

    if is_archive then
        local extract_dir = file.join_path(temp_dir, "extracted")
        os.execute("mkdir -p " .. extract_dir)

        print("Extracting archive")
        local extract_ok, extract_err = M.extract(artifact_path, extract_dir)
        if not extract_ok then
            M.cleanup(temp_dir)
            return nil, "Extraction failed: " .. tostring(extract_err)
        end

        local install_ok, install_err = M.install_files(platform, extract_dir, install_path)
        if not install_ok then
            M.cleanup(temp_dir)
            return nil, "File installation failed: " .. tostring(install_err)
        end
    else
        local bin_name = basename(platform.bin or "binary")
        local target_path = file.join_path(install_path, bin_name)

        local cp_ok = os.execute(string.format("cp '%s' '%s'", artifact_path, target_path))
        if not cp_ok then
            M.cleanup(temp_dir)
            return nil, "Failed to copy binary"
        end

        M.make_executable(target_path)
    end

    M.cleanup(temp_dir)

    return true, nil
end

function M.download(url, target_path)
    local http = require("http")

    local err = http.download_file({ url = url }, target_path)
    if err ~= nil then
        return nil, tostring(err)
    end

    local file = require("file")
    if not file.exists(target_path) then
        return nil, "Download completed but file not found at " .. target_path
    end

    return true, nil
end

function M.verify_checksum(file_path, expected_hash)
    local cmd = require("cmd")

    expected_hash = expected_hash:lower():gsub("%s", "")

    local checksum_cmds = {
        string.format("sha256sum '%s'", file_path),
        string.format("shasum -a 256 '%s'", file_path),
    }

    for _, checksum_cmd in ipairs(checksum_cmds) do
        local ok, result = pcall(cmd.exec, checksum_cmd)
        if ok and result and result ~= "" then
            local actual_hash = result:match("^(%x+)")
            if actual_hash then
                actual_hash = actual_hash:lower()
                if actual_hash == expected_hash then
                    return true, nil
                else
                    return nil, string.format("expected %s, got %s", expected_hash, actual_hash)
                end
            end
        end
    end

    return nil, "No checksum tool available (tried sha256sum, shasum)"
end

function M.is_archive(uri)
    local extensions = {
        "%.tar%.gz$",
        "%.tgz$",
        "%.tar%.bz2$",
        "%.tbz2$",
        "%.tar%.xz$",
        "%.txz$",
        "%.zip$",
        "%.tar$",
    }

    local lower_uri = uri:lower()
    for _, ext in ipairs(extensions) do
        if lower_uri:match(ext) then
            return true
        end
    end

    return false
end

function M.extract(archive_path, extract_dir)
    local archiver = require("archiver")

    local err = archiver.decompress(archive_path, extract_dir)
    if err ~= nil then
        return nil, tostring(err)
    end

    return true, nil
end

function M.install_files(platform, source_dir, install_path)
    local file = require("file")
    local cmd = require("cmd")

    if platform.files and #platform.files > 0 then
        local any_copied = false

        for _, mapping in ipairs(platform.files) do
            local from_pattern = mapping.from
            local to_path = mapping.to

            if from_pattern:match("%*") then
                local find_cmd_str =
                    string.format("find '%s' -path '%s/%s' -type f", source_dir, source_dir, from_pattern)
                local ok, found_files = pcall(cmd.exec, find_cmd_str)
                if not ok then
                    print("WARNING: find failed for pattern: " .. from_pattern)
                    found_files = ""
                end

                for found_file in found_files:gmatch("[^\r\n]+") do
                    found_file = found_file:gsub("%s+$", "")
                    if found_file ~= "" then
                        local relative = found_file:sub(#source_dir + 2)
                        local target

                        if to_path == "." then
                            target = file.join_path(install_path, basename(relative))
                        else
                            target = file.join_path(install_path, to_path)
                        end

                        local cp_ok = os.execute(string.format("cp '%s' '%s'", found_file, target))
                        if cp_ok then
                            any_copied = true
                            if platform.bin and basename(relative) == platform.bin then
                                M.make_executable(target)
                            end
                        else
                            print("WARNING: Failed to copy: " .. found_file)
                        end
                    end
                end
            else
                local source = file.join_path(source_dir, from_pattern)

                if file.exists(source) then
                    local target
                    if to_path == "." then
                        target = file.join_path(install_path, basename(from_pattern))
                    else
                        target = file.join_path(install_path, to_path)
                        local target_dir = target:match("^(.*)/") or "."
                        os.execute("mkdir -p '" .. target_dir .. "'")
                    end

                    local cp_ok = os.execute(string.format("cp '%s' '%s'", source, target))
                    if not cp_ok then
                        return nil, "Failed to copy: " .. from_pattern
                    end
                    any_copied = true

                    if platform.bin and basename(from_pattern) == platform.bin then
                        M.make_executable(target)
                    end
                else
                    print("WARNING: Source not found: " .. source)
                end
            end
        end

        if not any_copied then
            return nil, "No files were installed from files[] mappings"
        end
    else
        local bin_name = platform.bin
        if not bin_name then
            return nil, "No bin specified in platform"
        end

        local find_cmd_str = string.format("find '%s' -name '%s' -type f", source_dir, bin_name)
        local ok, found_binary = pcall(cmd.exec, find_cmd_str)
        if not ok or not found_binary or found_binary == "" then
            return nil, "Binary not found in archive: " .. bin_name
        end

        found_binary = found_binary:match("[^\r\n]+")
        if not found_binary then
            return nil, "Binary not found in archive: " .. bin_name
        end
        found_binary = found_binary:gsub("%s+$", "")

        local target = file.join_path(install_path, bin_name)

        local cp_ok = os.execute(string.format("cp '%s' '%s'", found_binary, target))
        if not cp_ok then
            return nil, "Failed to copy binary"
        end

        M.make_executable(target)
    end

    return true, nil
end

function M.make_executable(file_path)
    local os_type = RUNTIME.osType or ""
    if os_type:match("windows") or os_type:match("win32") then
        return
    end

    os.execute("chmod +x '" .. file_path .. "'")
end

function M.cleanup(temp_dir)
    os.execute("rm -rf '" .. temp_dir .. "'")
end

return M
