-- lvim-context: :checkhealth lvim-context.
-- Answers the questions that otherwise look like bugs: WHY does the current buffer show no header
-- (the guard's exact reason — the top question this plugin kind gets), WHICH engine actually
-- resolves the scopes here (treesitter through lvim-ts vs the indent fallback, and whether a parser
-- exists for this filetype), what the scopes resolve to right now, whether the glyphs are
-- single-width, and what one full context resolution costs (measured, not guessed).
-- Read-only reporting — it never mutates config or state.
--
---@module "lvim-context.health"

local config = require("lvim-context.config")
local guard = require("lvim-context.guard")
local scope = require("lvim-context.scope")

local api = vim.api

local M = {}

--- Report one glyph's display width.
---@param health table  the vim.health reporter
---@param name string
---@param glyph string|nil
---@return nil
local function check_glyph(health, name, glyph)
    if not glyph or glyph == "" then
        return -- disabled (false / "") — nothing to validate
    end
    local w = vim.fn.strdisplaywidth(glyph)
    if w == 1 then
        health.ok(("%s = %q (single width)"):format(name, glyph))
    else
        health.error(("%s = %q is %d cells wide — it would shift the row it fills"):format(name, glyph, w))
    end
end

--- The engine the CURRENT buffer would resolve with, plus the parser situation behind it.
---@param health table
---@param buf integer
---@return nil
local function check_engine(health, buf)
    if config.scope.engine == "indent" then
        health.ok("engine: indent (configured — no parser needed)")
        return
    end
    local ft = vim.bo[buf].filetype
    local ok_parser, parser = pcall(vim.treesitter.get_parser, buf, nil, { error = false })
    local ok_ts, lts = pcall(require, "lvim-ts")
    if not ok_ts then
        health.warn("lvim-ts not found — the treesitter engine relies on Neovim's own parser lookup")
    end
    if ok_parser and parser then
        local lang = parser:lang()
        health.ok(("engine here: treesitter (language %q for filetype %q)"):format(lang, ft))
        if not vim.treesitter.query.get(lang, "highlights") then
            health.warn(("no `highlights` query for %q — the pinned lines will have no colours"):format(lang))
        end
    else
        local hint = ft ~= "" and ("no parser for filetype %q"):format(ft) or "the buffer has no filetype"
        health.info(("engine here: indent fallback — %s"):format(hint))
        if ok_ts and ft ~= "" then
            local ok_missing, missing = pcall(lts.missing_for_ft, ft)
            if ok_missing and type(missing) == "table" and #missing > 0 then
                health.info(("lvim-ts reports missing parsers for %q: %s"):format(ft, table.concat(missing, ", ")))
            end
        end
    end
end

--- Resolve the current window's context once, and report what it costs.
---@param health table
---@param win integer
---@return nil
local function check_context(health, win)
    scope.invalidate(win)
    local t0 = vim.uv.hrtime()
    local view = scope.context(win)
    local ms = (vim.uv.hrtime() - t0) / 1e6
    health.ok(("cold context resolution: %.2f ms (%d enclosing scopes)"):format(ms, #view.scopes))
    if #view.scopes == 0 then
        health.info("no enclosing scope at the cursor here")
        return
    end
    local parts = {}
    for _, s in ipairs(view.scopes) do
        parts[#parts + 1] = ("%s @ %d–%d"):format(s.type, s.srow + 1, s.erow + 1)
    end
    health.info(("scopes (outermost first): %s"):format(table.concat(parts, "  ➤  ")))
    health.info(("pinned right now: %d line(s)"):format(#view.rows))
end

--- Run the health report.
---@return nil
function M.check()
    local health = vim.health
    health.start("lvim-context")

    if vim.fn.has("nvim-0.10") == 1 then
        health.ok("Neovim >= 0.10")
    else
        health.error("Neovim >= 0.10 is required (extmark `overlap` queries, floating-window zindex)")
    end

    local ok_utils = pcall(require, "lvim-utils.utils")
    local ok_hl, hl = pcall(require, "lvim-utils.highlight")
    if ok_utils and ok_hl and type(hl.bind) == "function" then
        health.ok("lvim-utils found (palette-bound highlights + the shared config merge)")
    else
        health.error("lvim-utils is required (highlight.bind, colors, utils.merge)")
    end
    if pcall(require, "lvim-ui") then
        health.ok("lvim-ui found (the scope picker of `:LvimContext jump`)")
    else
        health.warn("lvim-ui not found — `:LvimContext jump` without an index cannot open its picker")
    end

    health.info(
        ("style = %s · mode = %s · max_lines = %d · trim_scope = %s"):format(
            config.style,
            config.mode,
            config.max_lines,
            config.trim_scope
        )
    )
    check_glyph(health, "separator", config.separator)
    check_glyph(health, "winbar.separator", config.winbar.separator)
    check_glyph(health, "picker.icon", config.picker.icon)

    -- The decision for the buffer checkhealth was invoked FROM ("why no header here?"): :checkhealth
    -- opens its own window, so the alternate buffer is the one the user was looking at.
    local buf = vim.fn.bufnr("#")
    if buf == -1 or not api.nvim_buf_is_valid(buf) then
        buf = api.nvim_get_current_buf()
    end
    local allowed, reason = guard.decide(buf)
    local name = vim.fn.fnamemodify(api.nvim_buf_get_name(buf), ":~:.")
    if name == "" then
        name = "[No Name]"
    end
    if allowed then
        health.ok(("buffer %s gets a context header"):format(name))
    else
        health.warn(("buffer %s gets NO context header: %s"):format(name, reason))
    end

    check_engine(health, buf)

    local wins = vim.fn.win_findbuf(buf)
    if allowed and #wins > 0 then
        check_context(health, wins[1])
    end
end

return M
