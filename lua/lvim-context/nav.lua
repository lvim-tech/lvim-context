-- lvim-context.nav: the header as a NAVIGATION surface, not a passive banner.
--
-- Three ways in, one landing:
--   • a click on a pinned row (through lvim-utils.mouse — the ecosystem's mouse layer, never a
--     private global mouse map) or `keys.jump` while the header holds the cursor,
--   • `:LvimContext jump {n}` / a count — the n-th enclosing scope, outermost first,
--   • `:LvimContext jump` with no count — an lvim-ui SELECT listing the enclosing scopes, so a
--     specific ancestor can be picked (the canonical picker; never vim.ui.select).
--
-- A jump always sets the jumplist mark first, so `<C-o>` comes straight back.
--
---@module "lvim-context.nav"

local api = vim.api

local config = require("lvim-context.config")
local render = require("lvim-context.render")
local scope = require("lvim-context.scope")

local M = {}

--- Resolve an optional window argument to a window handle.
---@param win? integer  nil/0 = the current window
---@return integer
local function winid(win)
    if win == nil or win == 0 then
        return api.nvim_get_current_win()
    end
    return win
end

--- Move `win`'s cursor to a source line (first non-blank column), through the jumplist.
---@param win integer
---@param lnum integer  1-based
---@return nil
function M.goto_line(win, lnum)
    if not api.nvim_win_is_valid(win) then
        return
    end
    local buf = api.nvim_win_get_buf(win)
    lnum = math.max(1, math.min(lnum, api.nvim_buf_line_count(buf)))
    api.nvim_set_current_win(win)
    api.nvim_win_call(win, function()
        vim.cmd("normal! m'") -- the jumplist: <C-o> returns to where the jump started
        api.nvim_win_set_cursor(win, { lnum, 0 })
        vim.cmd("normal! ^")
    end)
end

--- Jump to the source line an overlay ROW shows (the click / `keys.jump` target).
---@param win integer  the PARENT window the header belongs to
---@param row integer  1-based row inside the header
---@return nil
function M.jump_row(win, row)
    local lnum = render.lnum_at(win, row)
    if lnum then
        M.goto_line(win, lnum)
    end
end

--- One scope's label for a picker row: its opening line, whitespace-collapsed and trimmed.
---@param buf integer
---@param s LvimContextScopeRange
---@return string
function M.label(buf, s)
    local text = api.nvim_buf_get_lines(buf, s.srow, s.srow + 1, false)[1] or ""
    return (vim.trim(text):gsub("%s+", " "))
end

--- Jump to an enclosing scope of `win`. With `index` (1 = the OUTERMOST scope) it jumps straight
--- there; without one it opens the lvim-ui select over the enclosing scopes.
---@param win? integer   nil = the current window
---@param index? integer 1-based, outermost first; nil = pick from the list
---@return nil
function M.jump(win, index)
    local target = winid(win)
    local buf = api.nvim_win_get_buf(target)
    local scopes = scope.enclosing(target)
    if #scopes == 0 then
        vim.notify("lvim-context: no enclosing context here", vim.log.levels.INFO)
        return
    end

    if index then
        local s = scopes[math.max(1, math.min(index, #scopes))]
        M.goto_line(target, s.srow + 1)
        return
    end

    local items = {}
    for i, s in ipairs(scopes) do
        items[i] = {
            label = ("%d  %s"):format(s.srow + 1, M.label(buf, s)),
            icon = config.picker.icon,
        }
    end
    require("lvim-ui").select({
        title = config.picker.title,
        items = items,
        current_item = items[#items], -- the innermost scope: the one you are actually in
        mark_current = false,
        callback = function(confirmed, i)
            if confirmed and scopes[i] then
                M.goto_line(target, scopes[i].srow + 1)
            end
        end,
    })
end

return M
