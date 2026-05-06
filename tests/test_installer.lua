local M = {}

local tests = {}

function M.test(name, fn)
    table.insert(tests, { name = name, fn = fn })
end

local function assert_equals(actual, expected, msg)
    if actual ~= expected then
        error(
            string.format(
                "%s: expected '%s', got '%s'",
                msg or "Assertion failed",
                tostring(expected),
                tostring(actual)
            )
        )
    end
end

local installer = require("installer")

M.test("target_bin_name: no hyphens", function()
    assert_equals(installer.target_bin_name("tree"), "kubectl-tree")
end)

M.test("target_bin_name: hyphens become underscores", function()
    assert_equals(installer.target_bin_name("foo-bar-baz"), "kubectl-foo_bar_baz")
end)

M.test("target_bin_name: rename_exe overrides", function()
    assert_equals(installer.target_bin_name("browse-pvc", { rename_exe = "kubectl-custom" }), "kubectl-custom")
end)

M.test("target_bin_name: empty rename_exe falls back", function()
    assert_equals(installer.target_bin_name("browse-pvc", { rename_exe = "" }), "kubectl-browse_pvc")
end)

M.test("target_bin_name: nil opts", function()
    assert_equals(installer.target_bin_name("browse-pvc", nil), "kubectl-browse_pvc")
end)

function M.run_all()
    print("Running installer tests...")
    print(string.rep("=", 50))

    local passed = 0
    local failed = 0

    for _, test in ipairs(tests) do
        local ok, test_err = pcall(test.fn)
        if ok then
            print("✓ " .. test.name)
            passed = passed + 1
        else
            print("✗ " .. test.name)
            print("  Error: " .. tostring(test_err))
            failed = failed + 1
        end
    end

    print(string.rep("=", 50))
    print(string.format("Results: %d passed, %d failed", passed, failed))

    return failed == 0
end

return M
