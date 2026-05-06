local M = require("framework").suite("installer")
local installer = require("installer")

M.test("target_bin_name: no hyphens", function()
    M.assert_equals(installer.target_bin_name("tree"), "kubectl-tree")
end)

M.test("target_bin_name: hyphens become underscores", function()
    M.assert_equals(installer.target_bin_name("foo-bar-baz"), "kubectl-foo_bar_baz")
end)

return M
