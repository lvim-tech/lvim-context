-- Whether a buffer gets a context header, and WHY not when it does not.
--
-- The reason matters as much as the decision: `:LvimContext` reports it, so a user who sees no
-- header learns which rule took it away instead of guessing. The rules are decided by
-- construction — a buftype that is not file content, a floating window — never by matching names.

local guard = require("lvim-context.guard")
local config = require("lvim-context.config")

--- A scratch buffer with the given options, cleaned up afterwards.
---@param opts { ft?: string, bt?: string, lines?: string[] }
---@param fn fun(buf: integer)
local function on_buffer(opts, fn)
    local buf = vim.api.nvim_create_buf(false, true)
    vim.bo[buf].buftype = opts.bt or ""
    vim.bo[buf].filetype = opts.ft or "lua"
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, opts.lines or { "local M = {}" })
    local ok, err = pcall(fn, buf)
    guard.forget(buf)
    pcall(vim.api.nvim_buf_delete, buf, { force = true })
    if not ok then
        error(err, 0)
    end
end

describe("lvim-context.guard.decide")

it("allows an ordinary file buffer", function()
    on_buffer({}, function(buf)
        local ok, why = guard.decide(buf)
        eq(true, ok, why)
        eq("ok", why)
    end)
end)

it("refuses a buffer that is not file content, and names the buftype", function()
    on_buffer({ bt = "nofile" }, function(buf)
        local ok, why = guard.decide(buf)
        eq(false, ok)
        truthy(why:find("nofile", 1, true) ~= nil, "the reason should name the buftype: " .. why)
    end)
end)

it("refuses an excluded filetype, and names it", function()
    local saved = vim.deepcopy(config.exclude.filetypes)
    table.insert(config.exclude.filetypes, "lvim-test-ft")
    on_buffer({ ft = "lvim-test-ft" }, function(buf)
        local ok, why = guard.decide(buf)
        eq(false, ok)
        truthy(why:find("lvim-test-ft", 1, true) ~= nil, why)
    end)
    config.exclude.filetypes = saved
end)

it("refuses a file longer than the configured limit, and says the limit", function()
    local saved = config.exclude.max_file_lines
    config.exclude.max_file_lines = 3
    on_buffer({ lines = { "1", "2", "3", "4" } }, function(buf)
        local ok, why = guard.decide(buf)
        eq(false, ok)
        truthy(why:find("3", 1, true) ~= nil, "the reason should carry the limit: " .. why)
    end)
    config.exclude.max_file_lines = saved
end)

it("treats a limit of zero as no limit", function()
    local saved = config.exclude.max_file_lines
    config.exclude.max_file_lines = 0
    on_buffer({ lines = { "1", "2", "3", "4", "5" } }, function(buf)
        eq(true, (guard.decide(buf)))
    end)
    config.exclude.max_file_lines = saved
end)

it("refuses a buffer the user turned off, and points at the command", function()
    on_buffer({}, function(buf)
        guard.set_enabled(buf, false)
        local ok, why = guard.decide(buf)
        eq(false, ok)
        truthy(why:find("LvimContext", 1, true) ~= nil, "the reason should say how to turn it back on: " .. why)
        guard.set_enabled(buf, true)
        eq(true, (guard.decide(buf)), "and turning it back on is enough")
    end)
end)

it("refuses everything while the plugin is disabled", function()
    local saved = config.enabled
    config.enabled = false
    on_buffer({}, function(buf)
        local ok, why = guard.decide(buf)
        eq(false, ok)
        truthy(why:find("disabled", 1, true) ~= nil, why)
    end)
    config.enabled = saved
end)

it("refuses a buffer that is gone", function()
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_delete(buf, { force = true })
    eq(false, (guard.decide(buf)))
end)

describe("lvim-context.guard.buf_enabled")

it("reports the per-buffer switch, defaulting to on", function()
    on_buffer({}, function(buf)
        eq(true, guard.buf_enabled(buf))
        guard.set_enabled(buf, false)
        eq(false, guard.buf_enabled(buf))
        guard.set_enabled(buf, true)
        eq(true, guard.buf_enabled(buf))
    end)
end)

it("forgets a buffer's switch when the buffer goes", function()
    on_buffer({}, function(buf)
        guard.set_enabled(buf, false)
        guard.forget(buf)
        eq(true, guard.buf_enabled(buf), "a recycled buffer number must not inherit the old answer")
    end)
end)

describe("lvim-context.guard.window_allowed")

it("refuses a floating window, which is chrome and not content", function()
    local buf = vim.api.nvim_create_buf(false, true)
    vim.bo[buf].filetype = "lua"
    local win = vim.api.nvim_open_win(buf, false, {
        relative = "editor",
        row = 1,
        col = 1,
        width = 10,
        height = 3,
    })
    eq(false, guard.window_allowed(win), "a float must never host a header")
    pcall(vim.api.nvim_win_close, win, true)
    pcall(vim.api.nvim_buf_delete, buf, { force = true })
end)

it("refuses a window that is gone", function()
    eq(false, guard.window_allowed(999999))
end)

it("allows the current ordinary window with a file buffer", function()
    local buf = vim.api.nvim_create_buf(false, true)
    vim.bo[buf].buftype = ""
    vim.bo[buf].filetype = "lua"
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "local M = {}" })
    local prev = vim.api.nvim_get_current_buf()
    vim.api.nvim_set_current_buf(buf)
    eq(true, guard.window_allowed(vim.api.nvim_get_current_win()))
    vim.api.nvim_set_current_buf(prev)
    guard.forget(buf)
    pcall(vim.api.nvim_buf_delete, buf, { force = true })
end)
