local M = {}

function M.assert_equals(actual, expected, msg)
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

function M.assert_not_nil(value, msg)
    if value == nil then
        error(msg or "Expected non-nil value")
    end
end

function M.assert_table_has_key(t, key, msg)
    if t[key] == nil then
        error(string.format("%s: missing key '%s'", msg or "Assertion failed", key))
    end
end

function M.suite(name)
    local s = {
        name = name,
        tests = {},
        assert_equals = M.assert_equals,
        assert_not_nil = M.assert_not_nil,
        assert_table_has_key = M.assert_table_has_key,
    }
    function s.test(test_name, fn)
        table.insert(s.tests, { name = test_name, fn = fn })
    end
    return s
end

function M.run(suite)
    print("Running " .. suite.name .. " tests...")
    print(string.rep("=", 50))

    local passed = 0
    local failed = 0

    for _, t in ipairs(suite.tests) do
        local ok, err = pcall(t.fn)
        if ok then
            print("✓ " .. t.name)
            passed = passed + 1
        else
            print("✗ " .. t.name)
            print("  Error: " .. tostring(err))
            failed = failed + 1
        end
    end

    print(string.rep("=", 50))
    print(string.format("Results: %d passed, %d failed", passed, failed))

    return failed == 0
end

return M
