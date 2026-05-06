local M = require("framework").suite("installer")
local installer = require("installer")

M.test("target_bin_name: no hyphens", function()
    M.assert_equals(installer.target_bin_name("tree"), "kubectl-tree")
end)

M.test("target_bin_name: hyphens become underscores", function()
    M.assert_equals(installer.target_bin_name("foo-bar-baz"), "kubectl-foo_bar_baz")
end)

M.test("target_bin_name: rename_exe overrides", function()
    M.assert_equals(installer.target_bin_name("browse-pvc", { rename_exe = "kubectl-custom" }), "kubectl-custom")
end)

M.test("target_bin_name: empty rename_exe falls back", function()
    M.assert_equals(installer.target_bin_name("browse-pvc", { rename_exe = "" }), "kubectl-browse_pvc")
end)

M.test("target_bin_name: nil opts", function()
    M.assert_equals(installer.target_bin_name("browse-pvc", nil), "kubectl-browse_pvc")
end)

return M
