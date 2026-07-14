-- lvim-context.winbar: the BREADCRUMB style (`style = "winbar" | "both"`) — the same context, one
-- line, zero rows stolen: `local function open  ➤  for _, r in ipairs(rows)  ➤  if line_hl then`.
--
-- It is a window-local `%{%…%}` winbar, so Neovim re-evaluates it on its own redraws (a cursor move
-- repaints it for free — no autocmd-driven redraw loop) and the segments' `%#group#` / `%@…@` items
-- are re-parsed as statusline items, which is what makes the crumbs clickable.
--
-- NO-CLOBBER: a window whose winbar is already owned by something else (the lvim-hud chrome winbar,
-- an lvim-breadcrumbs trail, a panel's key bar) is left alone — this renderer only ever writes over
-- an EMPTY winbar or its own, and only ever clears its own.
--
---@module "lvim-context.winbar"

local api = vim.api

local config = require("lvim-context.config")
local guard = require("lvim-context.guard")
local scope = require("lvim-context.scope")

local M = {}

---@type string  the window-local expression this module owns
local EXPR = "%{%v:lua.require'lvim-context.winbar'.render()%}"

--- Escape a source line for the statusline evaluator (a bare `%` is an item introducer).
---@param s string
---@return string
local function escape(s)
    return (s:gsub("%%", "%%%%"))
end

--- Truncate a crumb to `winbar.max_crumb` display cells (0 = no limit).
---@param s string
---@return string
local function truncate(s)
    local max = config.winbar.max_crumb or 0
    if max <= 0 or vim.fn.strdisplaywidth(s) <= max then
        return s
    end
    return vim.fn.strcharpart(s, 0, max)
end

--- May this window's winbar be written by us? (Normal windows only, and only an empty winbar or one
--- we already own.)
---@param win integer
---@return boolean
local function claimable(win)
    if not api.nvim_win_is_valid(win) or api.nvim_win_get_config(win).relative ~= "" then
        return false
    end
    local current = vim.wo[win].winbar
    return current == "" or current == EXPR
end

--- Put our winbar on a window (when the style asks for it and the buffer qualifies), or take ours
--- back off it.
---@param win integer
---@return nil
function M.update(win)
    local on = (config.style == "winbar" or config.style == "both") and guard.window_allowed(win)
    if on then
        if claimable(win) then
            vim.wo[win][0].winbar = EXPR
        end
    elseif api.nvim_win_is_valid(win) and vim.wo[win].winbar == EXPR then
        vim.wo[win][0].winbar = ""
    end
end

--- Take our winbar off every window that still carries it (a global disable / a style change).
---@return nil
function M.clear_all()
    for _, win in ipairs(api.nvim_list_wins()) do
        if api.nvim_win_is_valid(win) and vim.wo[win].winbar == EXPR then
            vim.wo[win][0].winbar = ""
        end
    end
end

--- The scopes the breadcrumb shows for a window: every enclosing scope, or — with
--- `winbar.only_scrolled` — just those the sticky header would pin (so the trail appears exactly
--- when the code it names has scrolled away).
---@param win integer
---@return LvimContextScopeRange[]
local function crumb_scopes(win)
    if not config.winbar.only_scrolled then
        return (scope.enclosing(win))
    end
    local seen, out = {}, {}
    for _, r in ipairs(scope.context(win).rows) do
        if not seen[r.scope] then
            seen[r.scope] = true
            out[#out + 1] = r.scope
        end
    end
    return out
end

--- The WINDOW being drawn. Measured, not assumed: `g:statusline_winid` is set for a 'statusline' /
--- 'tabline' evaluation but is NIL during a 'winbar' one — the evaluator instead makes the drawn
--- window CURRENT for the duration. So take the id when it is there (this body also works hosted in
--- a statusline) and the current window otherwise.
---@return integer|nil
local function drawn_win()
    local win = vim.g.statusline_winid
    if win and win ~= 0 and api.nvim_win_is_valid(win) then
        return win
    end
    win = api.nvim_get_current_win()
    return api.nvim_win_is_valid(win) and win or nil
end

--- The `%{%…%}` body: the clickable crumb trail of the window being drawn.
---@return string
function M.render()
    local win = drawn_win()
    if not win then
        return ""
    end
    if config.style ~= "winbar" and config.style ~= "both" then
        return ""
    end
    if not guard.window_allowed(win) then
        return ""
    end

    local buf = api.nvim_win_get_buf(win)
    local scopes = crumb_scopes(win)
    if #scopes == 0 then
        return ""
    end

    local nav = require("lvim-context.nav")
    local segs = {}
    for i, s in ipairs(scopes) do
        local group = "LvimContextCrumb"
        if config.colors.diagnostics then
            local sev = scope.severity(buf, s)
            group = sev == "error" and "LvimContextCrumbError" or sev == "warn" and "LvimContextCrumbWarn" or group
        end
        local seg = ("%%#%s#%s"):format(group, escape(truncate(nav.label(buf, s))))
        if config.winbar.clickable then
            seg = ("%%%d@v:lua.require'lvim-context.winbar'.on_click@%s%%X"):format(i, seg)
        end
        segs[#segs + 1] = seg
    end

    local sep = ("%%#LvimContextCrumbSep# %s "):format(escape(config.winbar.separator))
    return " " .. table.concat(segs, sep)
end

--- Mouse dispatch for the `%N@…@` crumb regions: the clicked WINDOW comes from the mouse position
--- (the winbar of a window that is not current is clickable too), the crumb index from the minwid.
---@param idx integer  the clicked crumb's index (1 = the outermost scope)
---@return nil
function M.on_click(idx)
    local win = vim.fn.getmousepos().winid
    if not win or win == 0 or not api.nvim_win_is_valid(win) then
        return
    end
    require("lvim-context.nav").jump(win, idx)
end

return M
