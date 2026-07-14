-- lvim-context: the sticky context header — while you scroll deep inside a function nested in a
-- class, the enclosing lines that have scrolled off the top stay PINNED above the window, so you
-- always know what block you are looking at. The same context can also be a one-line breadcrumb in
-- the window's winbar (`style`), and the header is a navigation surface: click a pinned line (or
-- pick an ancestor from the lvim-ui select) and you are there.
--
-- The scopes come from treesitter through lvim-ts — the set's only parser seam — with a pure-indent
-- fallback for buffers with no grammar, so a `.conf` or a log still gets a header. Everything is
-- keyed by WINDOW, never by buffer: two splits on the same file at different scroll positions each
-- get their own header.
--
-- This module is the public entry point: setup() merges user opts into the live config, validates
-- the glyphs and the enum options, binds the highlight factory, installs the (debounced) update
-- loop and defines :LvimContext. State changes fire the `LvimContextChanged` User autocmd, so a
-- statusline / the control-center can mirror and drive them.
--
---@module "lvim-context"

local api = vim.api
local uv = vim.uv

local config = require("lvim-context.config")
local guard = require("lvim-context.guard")
local scope = require("lvim-context.scope")
local render = require("lvim-context.render")
local winbar = require("lvim-context.winbar")
local nav = require("lvim-context.nav")
local uu = require("lvim-utils.utils")

local M = {}

---@type boolean  one-time registration (autocmds, command, highlight bind) done
local registered = false

---@type uv.uv_timer_t|nil  the update debounce
local timer = nil

--- Reject a glyph that is not exactly one display cell wide (a wider one would shift every cell of
--- the row it fills). "" is allowed where the config documents it.
---@param name string  config path, for the error message
---@param glyph string|nil
---@param allow_empty? boolean
---@return nil
local function validate_glyph(name, glyph, allow_empty)
    if glyph == nil or (allow_empty and (glyph == false or glyph == "")) then
        return -- disabled: nothing to validate
    end
    if type(glyph) ~= "string" or vim.fn.strdisplaywidth(glyph) ~= 1 then
        error(("lvim-context: %s must be a single-width glyph (got %s)"):format(name, vim.inspect(glyph)), 0)
    end
end

--- Reject an enum option that is not one of its allowed values.
---@param name string
---@param value any
---@param allowed string[]
---@return nil
local function validate_enum(name, value, allowed)
    if not vim.tbl_contains(allowed, value) then
        error(
            ("lvim-context: %s must be one of %s (got %s)"):format(
                name,
                table.concat(allowed, " | "),
                vim.inspect(value)
            ),
            0
        )
    end
end

--- Validate everything the merge could have broken.
---@return nil
local function validate()
    validate_enum("style", config.style, { "sticky", "winbar", "both" })
    validate_enum("mode", config.mode, { "cursor", "topline" })
    validate_enum("trim_scope", config.trim_scope, { "outer", "inner" })
    validate_enum("number_style", config.number_style, { "auto", "absolute", "relative" })
    validate_enum("scope.engine", config.scope.engine, { "treesitter", "indent" })
    validate_glyph("separator", config.separator, true)
    validate_glyph("winbar.separator", config.winbar.separator)
    validate_glyph("picker.icon", config.picker.icon)
end

--- Resolve an optional command/API buffer argument to a buffer handle.
---@param buf? integer  nil/0 = current
---@return integer
local function bufnr(buf)
    if buf == nil or buf == 0 then
        return api.nvim_get_current_buf()
    end
    return buf
end

--- Resolve an optional API window argument to a window handle.
---@param win? integer  nil/0 = current
---@return integer
local function winid(win)
    if win == nil or win == 0 then
        return api.nvim_get_current_win()
    end
    return win
end

--- Fire the state-change User event.
---@param buf integer|nil  nil = the global switch moved
---@param enabled boolean
---@return nil
local function notify_changed(buf, enabled)
    api.nvim_exec_autocmds("User", {
        pattern = "LvimContextChanged",
        data = { buf = buf, enabled = enabled },
    })
end

--- Refresh every window of the current tabpage NOW (the debounce's target; also the API's direct
--- entry). A window whose buffer is a header of ours is skipped — chrome is never content.
---@return nil
function M.update()
    for _, win in ipairs(api.nvim_tabpage_list_wins(0)) do
        if not render.is_overlay_buf(api.nvim_win_get_buf(win)) then
            render.update(win)
            winbar.update(win)
        end
    end
end

--- The debounced trigger (the autocmds' target): scrolling a long file fires WinScrolled per row,
--- and the tree walk must not run on every one of them.
---@return nil
local function schedule()
    if not timer then
        timer = uv.new_timer()
    end
    if timer then
        timer:stop()
        timer:start(math.max(0, config.debounce or 0), 0, function()
            vim.schedule(M.update)
        end)
    end
end

--- Is lvim-context drawing in a buffer (the global switch AND the buffer's own)?
---@param buf? integer  nil = report the GLOBAL switch only
---@return boolean
function M.enabled(buf)
    if buf == nil then
        return config.enabled
    end
    return config.enabled and guard.buf_enabled(bufnr(buf))
end

--- Turn the header on — globally, or for one buffer.
---@param buf? integer  nil = global
---@return nil
function M.enable(buf)
    if buf == nil then
        config.enabled = true
        notify_changed(nil, true)
    else
        buf = bufnr(buf)
        guard.set_enabled(buf, true)
        notify_changed(buf, true)
    end
    M.refresh(buf)
end

--- Turn the header off — globally, or for one buffer.
---@param buf? integer  nil = global
---@return nil
function M.disable(buf)
    if buf == nil then
        config.enabled = false
        notify_changed(nil, false)
    else
        buf = bufnr(buf)
        guard.set_enabled(buf, false)
        notify_changed(buf, false)
    end
    M.refresh(buf)
end

--- Flip the switch — globally, or for one buffer.
---@param buf? integer  nil = global
---@return nil
function M.toggle(buf)
    local on = buf == nil and config.enabled or guard.buf_enabled(bufnr(buf))
    if on then
        M.disable(buf)
    else
        M.enable(buf)
    end
end

--- Drop the resolved scopes and redraw every header (after a config change, a disable, a theme
--- reload). Headers whose window no longer qualifies are torn down by the update itself.
---@param _buf? integer  accepted for symmetry with the enable/disable API (the caches are per window)
---@return nil
function M.refresh(_buf)
    scope.invalidate()
    if not config.enabled then
        render.close_all()
        winbar.clear_all()
        return
    end
    M.update()
end

--- Every scope enclosing a window's anchor, outermost first — the public resolution other lvim-*
--- plugins reuse (a fold column, a picker's preview) instead of re-deriving it.
---@param win? integer  nil/0 = the current window
---@return LvimContextScopeRange[]
function M.scopes(win)
    return (scope.enclosing(winid(win)))
end

--- The source line the innermost PINNED scope of a window shows (nil when it has no header) — for a
--- statusline segment or the control-center.
---@param win? integer  nil/0 = the current window
---@return integer|nil  1-based line
function M.line_for(win)
    return render.line_for(winid(win))
end

--- Jump to an enclosing scope: with `index` (1 = the outermost) straight there, without one through
--- the lvim-ui select of the enclosing scopes.
---@param win? integer   nil/0 = the current window
---@param index? integer 1-based, outermost first
---@return nil
function M.jump(win, index)
    nav.jump(win, index)
end

--- :LvimContext [enable|disable|toggle|refresh|jump] [buffer|{n}]
---@param args string[]
---@return nil
local function command(args)
    local action = args[1] or "toggle"
    if action == "jump" then
        M.jump(0, tonumber(args[2]))
        return
    end
    local buf = args[2] == "buffer" and api.nvim_get_current_buf() or nil
    if action == "enable" then
        M.enable(buf)
    elseif action == "disable" then
        M.disable(buf)
    elseif action == "toggle" then
        M.toggle(buf)
    elseif action == "refresh" then
        M.refresh(buf)
    else
        vim.notify(("lvim-context: unknown action %q"):format(action), vim.log.levels.ERROR)
    end
end

--- Install the update loop.
---@return nil
local function install_autocmds()
    local aug = api.nvim_create_augroup("LvimContext", { clear = true })

    api.nvim_create_autocmd({
        "WinScrolled", -- the header's whole reason to exist
        "WinResized",
        "VimResized",
        "CursorMoved",
        "CursorMovedI",
        "TextChanged",
        "TextChangedI",
        "BufWinEnter",
        "WinEnter",
        "WinNew",
        "TabEnter",
        "DiagnosticChanged", -- only visible with colors.diagnostics, but cheap to follow
    }, {
        group = aug,
        callback = schedule,
        desc = "lvim-context: rebuild the context headers (debounced)",
    })

    -- 'number' / 'signcolumn' / 'foldcolumn' move the parent's text column: the header's own gutter
    -- must follow, or the pinned code stops lining up with the code below it.
    api.nvim_create_autocmd("OptionSet", {
        group = aug,
        pattern = { "number", "relativenumber", "numberwidth", "signcolumn", "foldcolumn", "wrap" },
        callback = schedule,
        desc = "lvim-context: the parent's gutter changed — re-align the header",
    })

    api.nvim_create_autocmd("WinClosed", {
        group = aug,
        callback = function(ev)
            render.close(tonumber(ev.match) or -1)
        end,
        desc = "lvim-context: tear a header down with its window",
    })

    api.nvim_create_autocmd("BufWipeout", {
        group = aug,
        callback = function(ev)
            guard.forget(ev.buf)
        end,
        desc = "lvim-context: drop a wiped buffer's own switch",
    })
end

--- Configure and start (idempotent — a second call re-merges the config, re-validates and refreshes,
--- but the autocmds, the command and the highlight bind are installed once).
---@param opts? LvimContextConfig
---@return nil
function M.setup(opts)
    uu.merge(config, opts or {})
    validate()

    if not registered then
        registered = true
        require("lvim-utils.highlight").bind(require("lvim-context.highlights").build)
        install_autocmds()

        api.nvim_create_user_command("LvimContext", function(cmd)
            command(cmd.fargs)
        end, {
            nargs = "*",
            complete = function(_, line)
                local words = vim.split(vim.trim(line), "%s+")
                if #words <= 2 and not line:match("%s$") or #words == 1 then
                    return { "enable", "disable", "toggle", "refresh", "jump" }
                end
                return { "buffer" }
            end,
            desc = "lvim-context: enable | disable | toggle | refresh [buffer] | jump [n]",
        })
    end

    -- A style change (or a re-setup) can orphan the other style's chrome.
    render.close_all()
    winbar.clear_all()
    M.refresh()
end

return M
