-- hooks/backend_install.lua
-- Installs a specific version of a tool
-- Documentation: https://mise.jdx.dev/backend-plugin-development.html#backendinstall

function PLUGIN:BackendInstall(ctx)
    local tool = ctx.tool
    local version = ctx.version
    local install_path = ctx.install_path

    -- Validate inputs
    if not tool or tool == "" then
        error("Tool name cannot be empty")
    end
    if not version or version == "" then
        error("Version cannot be empty")
    end
    if not install_path or install_path == "" then
        error("Install path cannot be empty")
    end

    -- Create installation directory
    local cmd = require("cmd")
    cmd.exec("mkdir -p " .. install_path)

    -- Example implementations (choose/modify based on your backend):

    -- Example 1: Package manager installation (like npm, pip)
    local install_cmd = "<BACKEND> install " .. tool .. "@" .. version .. " --target " .. install_path
    local result = cmd.exec(install_cmd)

    if result:match("error") or result:match("failed") then
        error("Failed to install " .. tool .. "@" .. version .. ": " .. result)
    end

    -- Example 2: Download and extract from URL
    --[[
    local http = require("http")
    local file = require("file")

    -- Construct download URL (adjust based on your backend's URL pattern)
    local platform = RUNTIME.osType:lower()
    local arch = RUNTIME.archType
    local download_url = "https://releases.<BACKEND>.org/" .. tool .. "/" .. version .. "/" .. tool .. "-" .. platform .. "-" .. arch .. ".tar.gz"

    -- Download the tool
    local temp_file = install_path .. "/" .. tool .. ".tar.gz"
    local resp, err = http.download({
        url = download_url,
        output = temp_file
    })

    if err then
        error("Failed to download " .. tool .. "@" .. version .. ": " .. err)
    end

    -- Extract the archive
    cmd.exec("cd " .. install_path .. " && tar -xzf " .. temp_file)
    cmd.exec("rm " .. temp_file)

    -- Set executable permissions
    cmd.exec("chmod +x " .. install_path .. "/bin/" .. tool)
    --]]

    -- Example 3: Build from source
    --[[
    local git_url = "https://github.com/owner/" .. tool .. ".git"

    -- Clone the repository
    cmd.exec("git clone " .. git_url .. " " .. install_path .. "/src")
    cmd.exec("cd " .. install_path .. "/src && git checkout " .. version)

    -- Build the tool (adjust based on build system)
    local build_result = cmd.exec("cd " .. install_path .. "/src && make install PREFIX=" .. install_path)

    if build_result:match("error") then
        error("Failed to build " .. tool .. "@" .. version)
    end

    -- Clean up source
    cmd.exec("rm -rf " .. install_path .. "/src")
    --]]

    -- Platform-specific installation logic
    --[[
    if RUNTIME.osType == "Darwin" then
        -- macOS-specific installation
        local macos_cmd = "<BACKEND> install-macos " .. tool .. "@" .. version .. " " .. install_path
        cmd.exec(macos_cmd)
    elseif RUNTIME.osType == "Linux" then
        -- Linux-specific installation
        local linux_cmd = "<BACKEND> install-linux " .. tool .. "@" .. version .. " " .. install_path
        cmd.exec(linux_cmd)
    elseif RUNTIME.osType == "Windows" then
        -- Windows-specific installation
        local windows_cmd = "<BACKEND> install-windows " .. tool .. "@" .. version .. " " .. install_path
        cmd.exec(windows_cmd)
    else
        error("Unsupported platform: " .. RUNTIME.osType)
    end
    --]]

    return {}
end
