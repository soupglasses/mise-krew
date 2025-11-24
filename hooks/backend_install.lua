-- hooks/backend_install.lua
-- Installs a specific version of a tool
-- Documentation: https://mise.jdx.dev/backend-plugin-development.html#backendinstall

function PLUGIN:BackendInstall(ctx)
    local tool = ctx.tool
    local version = ctx.version
    local install_path = ctx.install_path

    local file = require("file")
    local krew_root = file.join_path(RUNTIME.pluginDirPath, "root")
    local krew_cmd = "KREW_ROOT=" .. krew_root .. " krew"

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
    cmd.exec("mkdir -p " .. krew_root)

    -- Install implementation using krew backend
    local install_cmd = krew_cmd .. " install " .. tool
    local result_1 = cmd.exec(install_cmd)

    if result_1:match("does not exist") then
        error("Failed to install " .. tool .. ": " .. result_1)
    end

    -- Assume all krew binaries are 1-1 named and kubectl extensions.
    local target = "kubectl-" .. tool:gsub("-", "_")
    local source_path = file.join_path(krew_root, "bin", target)
    local target_path = file.join_path(install_path, target)
    local copy_cmd = string.format("cp %s %s", source_path, target_path)
    local result_2 = cmd.exec(copy_cmd)

    if result_2:match("failed") then
        error("Failed to install " .. tool .. ": " .. result_2)
    end

    return {}
end
