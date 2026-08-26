local M = require("framework").suite("installer")
local installer = require("installer")

package.loaded.file = file

local function shell_succeeds(command)
    local status, _, exit_code = os.execute(command)
    return status == true or status == 0 or exit_code == 0
end

local function with_temp_dir(fn)
    local temp_dir = os.tmpname()
    os.remove(temp_dir)
    assert(shell_succeeds("mkdir -p '" .. temp_dir .. "'"))

    local ok, err = pcall(fn, temp_dir)
    installer.cleanup(temp_dir)
    if not ok then
        error(err)
    end
end

local function write_file(path, contents)
    local handle = assert(io.open(path, "w"))
    handle:write(contents)
    handle:close()
end

M.test("target_bin_name: no hyphens", function()
    M.assert_equals(installer.target_bin_name("tree"), "kubectl-tree")
end)

M.test("target_bin_name: hyphens become underscores", function()
    M.assert_equals(installer.target_bin_name("foo-bar-baz"), "kubectl-foo_bar_baz")
end)

M.test("install_files: installs neat's ./kubectl-neat from the archive root", function()
    with_temp_dir(function(temp_dir)
        local source_dir = temp_dir .. "/source"
        local install_path = temp_dir .. "/install"
        assert(shell_succeeds("mkdir -p '" .. source_dir .. "' '" .. install_path .. "'"))
        write_file(source_dir .. "/kubectl-neat", "neat")

        local ok, err = installer.install_files({ bin = "./kubectl-neat" }, source_dir, install_path)

        M.assert_equals(ok, true, err)
        M.assert_equals(file.read(install_path .. "/kubectl-neat"), "neat")
        M.assert_equals(shell_succeeds("test -x '" .. install_path .. "/kubectl-neat'"), true)
    end)
end)

M.test("install_files: installs a nested archive binary in the install root", function()
    with_temp_dir(function(temp_dir)
        local source_dir = temp_dir .. "/source"
        local install_path = temp_dir .. "/install"
        assert(shell_succeeds("mkdir -p '" .. source_dir .. "/dist/linux' '" .. install_path .. "'"))
        write_file(source_dir .. "/dist/linux/kubectl-example", "example")

        local ok, err = installer.install_files({ bin = "dist/linux/kubectl-example" }, source_dir, install_path)

        M.assert_equals(ok, true, err)
        M.assert_equals(file.read(install_path .. "/kubectl-example"), "example")
        M.assert_equals(shell_succeeds("test -x '" .. install_path .. "/kubectl-example'"), true)
    end)
end)

M.test("install_files: rejects bin paths outside the archive", function()
    local ok, err = installer.install_files({ bin = "../kubectl-example" }, "/archive", "/install")

    M.assert_equals(ok, nil)
    M.assert_equals(err, "Invalid archive-relative bin path: ../kubectl-example")
end)

return M
