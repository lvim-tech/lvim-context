-- lvim-context: the live configuration table.
-- Holds the defaults; setup() merges user overrides into it in place (lvim-utils.utils.merge —
-- clean array replace), so every require("lvim-context.config") reader sees the effective values.
-- Everything is read LIVE: the renderer re-reads the table on every (debounced) update tick, so the
-- control center — or the user — can retune the header, the engine, the accents and the style at
-- runtime without a restart.
--
-- ZERO literals in code: every glyph, size, key, accent and tint the plugin paints with lives here.
-- Colours are palette KEYS (they track the live lvim-colorscheme theme — never a hex in code) and
-- tint strengths are ROLE NAMES from the shared scale in `lvim-utils.config.ui` (`tint.<role>`), so
-- the header wears the same rhythm as the rest of the lvim-tech chrome. A raw factor (0..1) is also
-- accepted wherever a role name is.
--
---@module "lvim-context.config"

---@class LvimContextColor
---@field accent string             a palette key ("blue", "comment", …) or a literal "#rrggbb"
---@field tint?  string|number      a tint ROLE from lvim-utils.config.ui (`tint.<role>`), or a raw factor

---@class LvimContextScope
---@field engine  "treesitter"|"indent"   how the enclosing scopes are found. "treesitter" (through
---              lvim-ts, the set's parser seam) falls back to "indent" automatically in a buffer
---              with no active parser — a plain `.conf`, a log, a grammarless filetype.
---@field nodes   table<string, string[]> what COUNTS as context, per language. A node counts when
---              its TYPE CONTAINS one of the strings ("function" matches `function_definition`,
---              `function_declaration`, …). `default` applies to EVERY language, on top of its own
---              list. The language key is the treesitter language, not the filetype.
---@field exclude_nodes table<string, string[]>  node types that never count (same substring rule);
---              `default` applies to every language

---@class LvimContextExclude
---@field filetypes      string[]  real-file filetypes that still want no header (prose, mostly).
---              Non-file buffers (`buftype ~= ""`) are excluded by CONSTRUCTION, never by name.
---@field max_file_lines integer   a buffer with more lines gets no header at all (0 = no limit)

---@class LvimContextKeys
---@field jump string  in the HEADER buffer: jump to the context line under the cursor ("" = unmapped)

---@class LvimContextPicker
---@field title string  the lvim-ui select's title when `:LvimContext jump` is given no index
---@field icon  string  the Nerd Font glyph in front of each scope row (single display width)

---@class LvimContextWinbar
---@field only_scrolled boolean  true = only the scopes that have scrolled off the top (what the
---              sticky header shows); false = every enclosing scope, so the trail is stable
---@field separator     string   the crumb separator (the set's pointer canon)
---@field max_crumb     integer  truncate one crumb to this many display cells (0 = no limit)
---@field clickable     boolean  wrap each crumb in a `%@…@` click region that jumps to it

---@class LvimContextColors
---@field context     LvimContextColor  the pinned lines' background wash
---@field separator   LvimContextColor  the rule under the header
---@field line_nr     LvimContextColor  the header's mirrored line numbers
---@field crumb       LvimContextColor  a winbar crumb's text
---@field crumb_sep   LvimContextColor  the ➤ between winbar crumbs
---@field diagnostics boolean            opt-in: a scope CONTAINING an error/warning takes the
---                  diagnostic accent, so the header says "the function you are inside of is broken"
---@field error       LvimContextColor  the diagnostic accents used when `diagnostics` is on
---@field warn        LvimContextColor

---@class LvimContextConfig
---@field enabled             boolean  master switch (see :LvimContext / the API)
---@field style               "sticky"|"winbar"|"both"  pinned overlay rows, a winbar breadcrumb, or both
---@field mode                "cursor"|"topline"  the context is computed from the CURSOR's node, or
---                          from whatever the window's top line sits inside
---@field max_lines           integer  cap the header height (0 = no cap)
---@field min_window_height   integer  no header at all in a window shorter than this (0 = no limit)
---@field multiline_threshold integer  how many lines of ONE scope's opener (a signature split over
---                          several lines) may be shown before it collapses to its first line
---@field trim_scope          "outer"|"inner"  which end is dropped when the context is deeper than
---                          `max_lines`: "outer" drops the outermost scopes, "inner" the innermost
---@field separator           string|false  the rule under the header (false/"" = none; single width)
---@field line_numbers        boolean  mirror the parent's number column in the header's gutter
---@field zindex              integer  the overlay's z-order
---@field debounce            integer  ms after a scroll / cursor move before the header is rebuilt
---@field scope               LvimContextScope
---@field exclude             LvimContextExclude
---@field keys                LvimContextKeys
---@field picker              LvimContextPicker
---@field winbar              LvimContextWinbar
---@field colors              LvimContextColors

---@type LvimContextConfig
return {
    enabled = true,
    style = "sticky",
    mode = "cursor",
    max_lines = 3,
    min_window_height = 0,
    multiline_threshold = 20,
    trim_scope = "outer",
    -- The rule under the pinned rows. OFF by default: the header already reads as chrome (its own wash),
    -- and a line under it only steals a row. Set a single-width glyph ("─") to draw one.
    separator = false,
    line_numbers = true,
    zindex = 20,
    debounce = 20,

    scope = {
        engine = "treesitter",
        -- Substring patterns, not exact types: one short list survives every grammar's naming
        -- (`function_definition`, `function_declaration`, `function_item`, …).
        nodes = {
            default = { "class", "function", "method", "for", "while", "if", "switch", "case" },
            rust = { "impl_item", "struct", "enum" },
            tex = { "chapter", "section", "subsection", "subsubsection" },
            scala = { "object_definition" },
            vhdl = { "process_statement", "architecture_body", "entity_declaration" },
            markdown = { "section" },
            elixir = { "anonymous_function", "arguments", "block", "do_block", "list", "map", "tuple" },
            json = { "pair" },
            yaml = { "block_mapping_pair" },
        },
        exclude_nodes = {},
    },

    exclude = {
        -- Non-file buffers (panels, trees, terminals, the dashboard, quickfix, prompts …) are
        -- excluded by CONSTRUCTION (buftype ~= ""), never by name — chrome is not content. These
        -- are the exceptions among REAL files.
        filetypes = { "markdown", "org", "text" },
        max_file_lines = 20000,
    },

    keys = {
        jump = "<CR>",
    },

    picker = {
        title = "Context",
        icon = "󰅩",
    },

    winbar = {
        only_scrolled = false,
        separator = "➤",
        max_crumb = 40,
        clickable = true,
    },

    colors = {
        context = { accent = "blue", tint = "body" },
        separator = { accent = "blue", tint = "separator" },
        line_nr = { accent = "comment" },
        crumb = { accent = "blue" },
        crumb_sep = { accent = "yellow" },
        diagnostics = false,
        error = { accent = "red", tint = "body" },
        warn = { accent = "orange", tint = "body" },
    },
}
