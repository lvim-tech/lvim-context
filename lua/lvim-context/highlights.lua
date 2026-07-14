-- lvim-context.highlights: every group the header paints with, built from ONE build() factory
-- reading the LIVE palette — there is no colour anywhere else in the plugin. init.lua registers it
-- through `lvim-utils.highlight.bind`, so the groups re-derive on ColorScheme / palette sync and
-- track the theme.
--
-- Accents are palette KEYS (never a hex in code); tint strengths are ROLE NAMES resolved against the
-- shared `lvim-utils.config.ui` scale — the plugin defines no numeric scale of its own. The pinned
-- lines are a BACKGROUND wash (they carry the source buffer's own foreground colours, mirrored from
-- its treesitter captures and extmark layers), so a tint here is a bg blend toward `c.bg`; the
-- separator rule and the mirrored line numbers are foregrounds.
--
---@module "lvim-context.highlights"

local c = require("lvim-utils.colors")
local hl = require("lvim-utils.highlight")
local config = require("lvim-context.config")

local M = {}

--- The shared tint scale (`lvim-utils.config.ui` `tint`), read LIVE so a retuned scale reaches us.
---@return table<string, number>
local function shared_tints()
    local ok, ui = pcall(require, "lvim-utils.config.ui")
    return (ok and type(ui) == "table" and ui.tint) or {}
end

--- Resolve a config accent: a palette key (tracks the live theme) or a literal "#rrggbb".
---@param key string
---@return string
local function accent(key)
    local v = c[key]
    return type(v) == "string" and v or key
end

--- Resolve a tint: a ROLE name from the shared scale, or a raw factor.
---@param t string|number|nil
---@param tints table<string, number>
---@return number|nil
local function tint_of(t, tints)
    if type(t) == "number" then
        return t
    end
    if type(t) == "string" then
        return tints[t]
    end
    return nil
end

--- The header background for a colour role: the accent blended toward the editor bg (the shared
--- "mtint" convention), or nil when the role carries no tint.
---@param role LvimContextColor
---@param tints table<string, number>
---@return string|nil
local function wash(role, tints)
    local t = tint_of(role.tint, tints)
    return t and hl.blend(accent(role.accent), c.bg, t) or nil
end

--- All lvim-context groups from the live palette + the live `config.colors`.
---@return table<string, table>
function M.build()
    local col = config.colors
    local tints = shared_tints()

    local ctx_bg = wash(col.context, tints)
    local err_bg = wash(col.error, tints)
    local warn_bg = wash(col.warn, tints)
    local sep_t = tint_of(col.separator.tint, tints)

    return {
        -- The pinned rows: a background wash only — the text keeps the source buffer's own colours.
        LvimContext = { bg = ctx_bg },
        -- A pinned row whose scope contains an error / a warning (colors.diagnostics).
        LvimContextError = { bg = err_bg },
        LvimContextWarn = { bg = warn_bg },
        -- The rule under the header: a foreground glyph on the header's own wash, so the row still
        -- reads as chrome rather than as a line of code.
        LvimContextSeparator = {
            fg = sep_t and hl.blend(accent(col.separator.accent), c.bg, sep_t) or accent(col.separator.accent),
            bg = ctx_bg,
            nocombine = true,
        },
        -- The mirrored line numbers in the header's gutter (config.line_numbers).
        LvimContextLineNr = { fg = accent(col.line_nr.accent), bg = ctx_bg },
        -- The winbar breadcrumb (style = "winbar" | "both").
        LvimContextCrumb = { fg = accent(col.crumb.accent) },
        LvimContextCrumbSep = { fg = accent(col.crumb_sep.accent) },
        LvimContextCrumbError = { fg = accent(col.error.accent) },
        LvimContextCrumbWarn = { fg = accent(col.warn.accent) },
    }
end

return M
