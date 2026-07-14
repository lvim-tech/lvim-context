-- lvim-context.guard: the exclusion decision — does this buffer get a context header at all?
-- The set-wide rule first: a buffer with `buftype ~= ""` (panels, trees, terminals, the dashboard,
-- quickfix, help, prompts — anything an lvim-ui surface hosts) is out BY CONSTRUCTION, never by a
-- filetype name. Chrome is not content, and a header pinned over a panel would be nonsense. The
-- config lists carry only the exceptions among REAL files (prose, mostly) plus the size cap.
--
-- decide() returns the REASON too, so :checkhealth can answer "why do I see no context here?" —
-- the single most-asked question of this plugin kind.
--
---@module "lvim-context.guard"

local config = require("lvim-context.config")

local api = vim.api

local M = {}

--- Per-buffer disable set (:LvimContext disable buffer / require("lvim-context").disable(buf)).
---@type table<integer, boolean>
local disabled = {}

--- Flip a buffer's own switch.
---@param buf integer
---@param on boolean
---@return nil
function M.set_enabled(buf, on)
    disabled[buf] = (not on) or nil
end

--- A buffer's own switch (true unless explicitly disabled).
---@param buf integer
---@return boolean
function M.buf_enabled(buf)
    return not disabled[buf]
end

--- Drop a wiped buffer's entry.
---@param buf integer
---@return nil
function M.forget(buf)
    disabled[buf] = nil
end

--- The full decision for a buffer, with the reason when it is out.
---@param buf integer
---@return boolean allowed
---@return string reason  "ok", or why the buffer gets no header
function M.decide(buf)
    if not config.enabled then
        return false, "lvim-context is disabled (:LvimContext enable)"
    end
    if not api.nvim_buf_is_valid(buf) then
        return false, "invalid buffer"
    end
    if disabled[buf] then
        return false, "this buffer is disabled (:LvimContext enable buffer)"
    end
    local bt = vim.bo[buf].buftype
    if bt ~= "" then
        return false, ('buftype "%s" is not file content (built-in guard)'):format(bt)
    end
    local ft = vim.bo[buf].filetype
    for _, f in ipairs(config.exclude.filetypes) do
        if f == ft then
            return false, ('filetype "%s" is in exclude.filetypes'):format(ft)
        end
    end
    local limit = config.exclude.max_file_lines or 0
    if limit > 0 and api.nvim_buf_line_count(buf) > limit then
        return false, ("more than exclude.max_file_lines (%d) lines"):format(limit)
    end
    return true, "ok"
end

--- The boolean decision (the hot path — one call per window per update tick).
---@param buf integer
---@return boolean
function M.allowed(buf)
    return (M.decide(buf))
end

--- Is `win` a window a header may be pinned to? A floating window is chrome (a picker, a peek, our
--- OWN overlay); only a normal window hosts a header — again decided by construction, not by name.
---@param win integer
---@return boolean
function M.window_allowed(win)
    if not api.nvim_win_is_valid(win) then
        return false
    end
    if api.nvim_win_get_config(win).relative ~= "" then
        return false
    end
    return M.allowed(api.nvim_win_get_buf(win))
end

return M
