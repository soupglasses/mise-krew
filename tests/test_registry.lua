local M = require("framework").suite("registry")
local registry = require("registry")
local cmd = require("cmd")

local real_exec = cmd.exec
local real_stamp_file = registry.STAMP_FILE
local calls = {}

-- Point the registry at a throwaway plugin directory and record the git
-- commands it would run instead of running them.
local function setup()
    local temp = os.tmpname()
    os.remove(temp)
    os.execute("mkdir -p '" .. temp .. "'")

    _G.RUNTIME.pluginDirPath = temp
    calls = {}

    cmd.exec = function(...)
        local command = select(1, ...)
        if select("#", ...) == 2 and select(2, ...) == nil then
            error("cmd.exec options must be omitted instead of passed as nil")
        end

        table.insert(calls, command)
        -- Let `clone` complete: it moves the cloned directory into place.
        if command:match("^git clone") then
            local target = command:match("'([^']+)'%s*$")
            if target then
                os.execute("mkdir -p '" .. target .. "/.git'")
            end
        end
        return ""
    end

    return temp
end

local function teardown(temp)
    cmd.exec = real_exec
    registry.STAMP_FILE = real_stamp_file
    registry.LOCK_TIMEOUT_SECONDS = 300
    registry.LOCK_UNSTAMPED_RETRIES = 25
    os.execute("rm -rf '" .. temp .. "'")
end

local function fake_clone()
    os.execute("mkdir -p '" .. registry.get_registry_path() .. "/.git'")
end

local function joined_calls()
    return table.concat(calls, "\n")
end

local function assert_matches(haystack, needle, msg)
    if not haystack:find(needle, 1, true) then
        error(string.format("%s: '%s' not found in:\n%s", msg or "Assertion failed", needle, haystack))
    end
end

local function assert_absent(haystack, needle, msg)
    if haystack:find(needle, 1, true) then
        error(string.format("%s: unexpected '%s' in:\n%s", msg or "Assertion failed", needle, haystack))
    end
end

M.test("is_stale: true without a fetch stamp", function()
    local temp = setup()
    fake_clone()

    M.assert_equals(registry.get_last_fetch(), 0)
    M.assert_equals(registry.is_stale(), true)

    teardown(temp)
end)

M.test("is_stale: false right after a fetch", function()
    local temp = setup()
    fake_clone()

    registry.mark_fetched()

    M.assert_equals(registry.is_stale(), false)
    M.assert_equals(registry.get_last_fetch() > 0, true)

    teardown(temp)
end)

M.test("is_stale: true once the TTL has elapsed", function()
    local temp = setup()
    fake_clone()

    local handle = io.open(registry.get_stamp_path(), "w")
    handle:write(tostring(os.time() - registry.CACHE_TTL_SECONDS - 1))
    handle:close()

    M.assert_equals(registry.is_stale(), true)

    teardown(temp)
end)

M.test("ensure_fresh: runs no git command on a fresh registry", function()
    local temp = setup()
    fake_clone()
    registry.mark_fetched()

    local ok = registry.ensure_fresh()

    M.assert_equals(ok, true)
    M.assert_equals(#calls, 0, "a fresh registry must not touch git")

    teardown(temp)
end)

-- Regression test for #12: `git pull` obeys the user's `pull.rebase` /
-- `pull.ff` settings and `git checkout` mutates the work tree, both of which
-- break when several mise jobs refresh the shared clone at once.
M.test("refresh: fetches and resets, never pulls or checks out", function()
    local temp = setup()
    fake_clone()

    local ok, err = registry.refresh()
    local ran = joined_calls()

    M.assert_equals(ok, true, tostring(err))
    assert_matches(ran, "git fetch --prune --quiet origin", "expected a fetch")
    assert_matches(ran, "git reset --hard --quiet origin/master", "expected a reset to the fetched tip")
    assert_absent(ran, "git pull", "git pull is configuration-dependent")
    assert_absent(ran, "git checkout", "git checkout mutates the work tree")

    teardown(temp)
end)

M.test("refresh: records the fetch time", function()
    local temp = setup()
    fake_clone()

    registry.refresh()

    M.assert_equals(registry.is_stale(), false)

    teardown(temp)
end)

M.test("refresh: reports a fetch timestamp write failure", function()
    local temp = setup()
    fake_clone()
    registry.STAMP_FILE = ".git/missing/mise-krew-last-fetch"

    local ok, err = registry.refresh()

    M.assert_equals(ok, nil)
    assert_matches(tostring(err), "Failed to record registry fetch time", "expected a timestamp error")

    teardown(temp)
end)

M.test("clone: stages the clone aside before moving it into place", function()
    local temp = setup()

    local ok, err = registry.clone()

    M.assert_equals(ok, true, tostring(err))
    assert_matches(joined_calls(), ".incomplete", "expected the clone to be staged")
    M.assert_equals(registry.exists(), true)
    M.assert_equals(registry.is_stale(), false)

    teardown(temp)
end)

M.test("clone: reports a fetch timestamp write failure", function()
    local temp = setup()
    registry.STAMP_FILE = ".git/missing/mise-krew-last-fetch"

    local ok, err = registry.clone()

    M.assert_equals(ok, nil)
    assert_matches(tostring(err), "Failed to record registry fetch time", "expected a timestamp error")

    teardown(temp)
end)

M.test("with_lock: holds the lock for the callback and releases it after", function()
    local temp = setup()
    local file = require("file")
    local held = false

    local result = registry.with_lock(function()
        held = file.exists(registry.get_lock_path())
        return "done"
    end)

    M.assert_equals(held, true, "the lock must exist while the callback runs")
    M.assert_equals(result, "done")
    M.assert_equals(file.exists(registry.get_lock_path()), false, "the lock must be released")

    teardown(temp)
end)

M.test("with_lock: releases the lock when the callback raises", function()
    local temp = setup()
    local file = require("file")

    local result, err = registry.with_lock(function()
        error("boom")
    end)

    M.assert_equals(result, nil)
    M.assert_not_nil(err)
    M.assert_equals(file.exists(registry.get_lock_path()), false, "the lock must be released on error")

    teardown(temp)
end)

M.test("with_lock: an expired owner cannot release its successor's lock", function()
    local temp = setup()
    local file = require("file")
    local successor_path = registry.get_lock_path() .. ".successor"

    local result = registry.with_lock(function()
        os.rename(registry.get_lock_path(), successor_path)
        os.execute("mkdir -p '" .. registry.get_lock_path() .. "'")
        local owner = io.open(registry.get_lock_path() .. "/owner", "w")
        owner:write("successor")
        owner:close()
        local created_at = io.open(registry.get_lock_path() .. "/created_at", "w")
        created_at:write(tostring(os.time()))
        created_at:close()
        return "done"
    end)

    M.assert_equals(result, "done")
    M.assert_equals(file.exists(registry.get_lock_path()), true, "the successor's lock must remain")
    M.assert_equals(file.exists(successor_path), true, "the expired owner's lock must not affect its successor")

    teardown(temp)
end)

M.test("with_lock: refuses to run while another process holds the lock", function()
    local temp = setup()
    registry.LOCK_TIMEOUT_SECONDS = 0

    os.execute("mkdir -p '" .. registry.get_lock_path() .. "'")
    local handle = io.open(registry.get_lock_path() .. "/created_at", "w")
    handle:write(tostring(os.time()))
    handle:close()

    local ran = false
    local result, err = registry.with_lock(function()
        ran = true
        return true
    end)

    M.assert_equals(ran, false, "the callback must not run while the lock is held")
    M.assert_equals(result, nil)
    assert_matches(tostring(err), "Timed out", "expected a timeout error")

    teardown(temp)
end)

M.test("with_lock: reclaims a lock left behind by a dead process", function()
    local temp = setup()
    registry.LOCK_TIMEOUT_SECONDS = 0

    os.execute("mkdir -p '" .. registry.get_lock_path() .. "'")
    local owner = io.open(registry.get_lock_path() .. "/owner", "w")
    owner:write("dead-owner")
    owner:close()
    local handle = io.open(registry.get_lock_path() .. "/created_at", "w")
    handle:write(tostring(os.time() - registry.LOCK_STALE_SECONDS - 1))
    handle:close()

    local result = registry.with_lock(function()
        return "ran"
    end)

    M.assert_equals(result, "ran")

    teardown(temp)
end)

M.test("with_lock: reclaims a lock that never got a timestamp", function()
    local temp = setup()
    registry.LOCK_TIMEOUT_SECONDS = 0
    registry.LOCK_UNSTAMPED_RETRIES = 0

    os.execute("mkdir -p '" .. registry.get_lock_path() .. "'")
    local owner = io.open(registry.get_lock_path() .. "/owner", "w")
    owner:write("dead-owner")
    owner:close()

    local result = registry.with_lock(function()
        return "ran"
    end)

    M.assert_equals(result, "ran")

    teardown(temp)
end)

M.test("with_lock: never reclaims a lock without an owner identity", function()
    local temp = setup()
    registry.LOCK_TIMEOUT_SECONDS = 0
    registry.LOCK_UNSTAMPED_RETRIES = 0

    os.execute("mkdir -p '" .. registry.get_lock_path() .. "'")

    local result, err = registry.with_lock(function()
        return "must not run"
    end)

    M.assert_equals(result, nil)
    assert_matches(tostring(err), "Timed out", "an unidentified lock cannot be reclaimed safely")

    teardown(temp)
end)

M.test("ensure_fresh: serialises through the lock and refreshes once", function()
    local temp = setup()
    fake_clone()

    local ok, err = registry.ensure_fresh()

    M.assert_equals(ok, true, tostring(err))
    assert_matches(joined_calls(), "git fetch --prune --quiet origin", "expected a refresh")

    -- A second caller finds the registry fresh and does no git work, which is
    -- what keeps concurrent mise jobs down to a single fetch.
    calls = {}
    registry.ensure_fresh()
    M.assert_equals(#calls, 0, "the registry was already refreshed")

    teardown(temp)
end)

return M
