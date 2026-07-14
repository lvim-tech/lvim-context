# lvim-context

The sticky context header — while you scroll deep inside a function nested in a class, the enclosing lines that have scrolled off the top stay **pinned** above the window, so you always know what block you are looking at. The same context can be a one-line breadcrumb in the winbar instead (or as well), and the header is a **navigation surface**: click a pinned line and you are there.

[![License: BSD-3-Clause](https://img.shields.io/badge/License-BSD--3--Clause-blue.svg)](https://github.com/lvim-tech/lvim-context/blob/main/LICENSE)

## Features

- **The sticky header** — the enclosing scopes whose opening lines have scrolled off the top, pinned in the window's first rows: outermost first, one line per scope, with an optional `─` rule under them so the block reads as chrome, not as code.
- **Source-faithful colours** — a pinned line is not re-highlighted from scratch (which is where the colours drift): it is **mirrored**. Both highlight layers of the source buffer are copied onto it — the treesitter captures (same trees, injections included, same `@capture.lang` groups and priorities) *and* every extmark highlight namespace over that line (LSP semantic tokens, a rainbow layer, …). A pinned line looks exactly like the line it mirrors.
- **Aligned with the code** — the header reproduces the parent window's gutter through its own `'statuscolumn'` (mirroring the **source** line numbers when `'number'` is on), so the pinned code sits in exactly the same screen column as the code below it. Horizontal scroll is followed too.
- **Per window, never per buffer** — two splits showing the same file at different scroll positions each get their own header (the case that breaks implementations keyed on the buffer).
- **Two engines** — `treesitter` (through **lvim-ts**, the set's parser seam), with a pure-**indent** fallback that needs no grammar, so a `.conf` or a log still gets a header.
- **`max_lines` / `trim_scope` / `multiline_threshold` / `min_window_height` / `mode`** — cap the height and pick which end is dropped; collapse an over-long opener (a signature split over several lines) to its first line; skip the header in a short window; compute the context from the **cursor** or from the window's **top line**.
- **Navigation** — click a pinned line to jump to it (through the ecosystem's mouse layer), or `:LvimContext jump [n]`; without an index it opens the canonical **lvim-ui** picker over the enclosing scopes, so a specific ancestor can be chosen.
- **Winbar breadcrumb** (`style = "winbar" | "both"`) — the same context as `Class ➤ method ➤ if` in the window's winbar: one line, zero rows stolen, each crumb clickable. It never clobbers a winbar owned by something else.
- **Diagnostics-aware** (opt-in) — a scope that *contains* an error/warning takes the diagnostic accent, so the header tells you the enclosing function is broken while you are deep inside it.
- **The guard by construction** — a buffer with `buftype ~= ""` (panels, trees, terminals, the dashboard, quickfix, prompts) never gets a header; the config lists only carry the exceptions among real files, plus a hard `max_file_lines` cap.
- **A public `scopes(win)` API** — the enclosing scope ranges, so other plugins (a fold column, a picker's preview) reuse the same resolution instead of re-deriving it.
- **Self-themed** — every highlight group derives from the live lvim-utils palette (accents are palette keys, tint strengths are roles of the shared scale) and rebuilds on `ColorScheme` / palette sync.
- `:LvimContext`, a full Lua API, a `LvimContextChanged` User event and `:checkhealth lvim-context` (including *why* the current buffer shows no header, and the measured resolution cost).

## Installation

Requires Neovim >= 0.10 and [lvim-utils](https://github.com/lvim-tech/lvim-utils) (palette-bound highlights, the shared config merge, the mouse layer). [lvim-ui](https://github.com/lvim-tech/lvim-ui) provides the scope picker of `:LvimContext jump`; [lvim-ts](https://github.com/lvim-tech/lvim-ts) is the parser registry the treesitter engine resolves through — without a parser the engine falls back to indentation.

### lvim-installer (recommended)

Install and manage it from the LVIM package manager — open the **Plugins** tab and install / update / pin it:

```vim
:LvimInstaller plugins
```

lvim-installer installs plugins through Neovim's built-in `vim.pack`, so no external plugin manager is needed.

### Native (vim.pack)

```lua
vim.pack.add({
    { src = "https://github.com/lvim-tech/lvim-utils" },
    { src = "https://github.com/lvim-tech/lvim-ui" },
    { src = "https://github.com/lvim-tech/lvim-context" },
})
require("lvim-context").setup({})
```

## Setup

Call `setup()` optionally with a config table. The full default config:

```lua
require("lvim-context").setup({
    enabled = true,
    style = "sticky", -- "sticky" (pinned rows) | "winbar" (breadcrumb) | "both"
    mode = "cursor", -- "cursor" (the node at the cursor) | "topline" (what the top line sits inside)
    max_lines = 3, -- cap the header height (0 = no cap)
    min_window_height = 0, -- no header in a window shorter than this (0 = no limit)
    multiline_threshold = 20, -- lines of ONE opener shown before it collapses to its first line
    trim_scope = "outer", -- which end is dropped past max_lines: "outer" | "inner"
    separator = false, -- the rule under the header (false / "" = none; else a single-width glyph)
    line_numbers = true, -- mirror the parent's number column in the header's gutter
    zindex = 20, -- the overlay's z-order
    debounce = 20, -- ms after a scroll / cursor move before the header is rebuilt

    scope = {
        engine = "treesitter", -- "treesitter" (via lvim-ts) | "indent" (no parser needed)
        -- What COUNTS as context, per language. A node counts when its TYPE CONTAINS one of the
        -- strings ("function" matches function_definition, function_declaration, function_item …).
        -- `default` applies to every language, on top of its own list.
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
        exclude_nodes = {}, -- node types that never count (same substring rule), per language
    },

    exclude = {
        -- Non-file buffers (panels, trees, terminals, the dashboard, quickfix, prompts …) are
        -- excluded by CONSTRUCTION (buftype ~= ""), never by name. These are the exceptions
        -- among REAL files.
        filetypes = { "markdown", "org", "text" },
        max_file_lines = 20000, -- a bigger buffer gets no header at all (0 = no limit)
    },

    keys = {
        jump = "<CR>", -- in the HEADER buffer: jump to the context line under the cursor
    },

    picker = {
        title = "Context", -- the lvim-ui select's title (`:LvimContext jump` with no index)
        icon = "󰅩", -- the glyph in front of each scope row
    },

    winbar = {
        only_scrolled = false, -- true = only the scopes the sticky header would pin
        separator = "➤", -- the crumb separator
        max_crumb = 40, -- truncate one crumb to this many cells (0 = no limit)
        clickable = true, -- each crumb is a click region that jumps to it
    },

    colors = {
        -- Accents are palette KEYS (they track the live theme) or "#rrggbb"; tints are ROLE names
        -- from the shared lvim-utils.config.ui scale (a raw 0..1 factor is accepted too).
        context = { accent = "blue", tint = "body" }, -- the pinned lines' background wash
        separator = { accent = "blue", tint = "separator" }, -- the rule under the header
        line_nr = { accent = "comment" }, -- the mirrored line numbers
        crumb = { accent = "blue" }, -- a winbar crumb
        crumb_sep = { accent = "yellow" }, -- the ➤ between crumbs
        diagnostics = false, -- a scope CONTAINING an error/warning takes the diagnostic accent
        error = { accent = "red", tint = "body" },
        warn = { accent = "orange", tint = "body" },
    },
})
```

### Notes on the options

- **`scope.nodes` are substring patterns**, not exact types — one short list survives every grammar's naming. `default` applies to every language; a language key adds to it (`rust = { "impl_item" }` keeps the defaults *and* pins `impl` blocks). Use `exclude_nodes` to veto a type the substrings would otherwise catch.
- **The header hides the lines it covers**, so a scope counts as "scrolled off" while its opener sits above the first line the header still leaves visible — the rule row included. The header therefore grows exactly as far as it must, and never buries an opener behind its own rule.
- **`multiline_threshold`** applies to ONE scope's opener: the first line through the line where its body begins (`def render(` … `) -> str:` is one opener of 7 lines). Past the threshold it collapses to the opener's first line.
- **`trim_scope = "outer"`** (the default) drops the OUTERMOST rows when the context is deeper than `max_lines` — the scopes you are actually inside of survive. `"inner"` does the opposite.
- **`mode = "topline"`** computes the context from whatever the window's top line sits inside, so the header does not change while the cursor moves within the viewport.
- **`line_numbers`** only shows numbers where the parent window has `'number'` / `'relativenumber'` on; the gutter itself is always reproduced, so the pinned code stays aligned with the code below.

## Commands

```
:LvimContext                       " toggle globally
:LvimContext enable|disable|toggle " flip the global switch
:LvimContext enable buffer         " …only for the current buffer
:LvimContext refresh               " re-resolve and repaint every header
:LvimContext jump                  " pick an enclosing scope (the lvim-ui select) and jump to it
:LvimContext jump 2                " jump straight to the 2nd scope, outermost first
```

## API

```lua
local ctx = require("lvim-context")
ctx.enable(buf) -- buf: nil = global, 0/bufnr = per buffer
ctx.disable(buf)
ctx.toggle(buf)
ctx.refresh()
ctx.enabled(buf) -- boolean; nil = the global switch, 0/bufnr = effective for that buffer
ctx.update() -- rebuild the headers of the current tabpage now
ctx.scopes(win) -- the enclosing scope ranges, outermost first (win: nil/0 = current)
ctx.line_for(win) -- the source line of the innermost PINNED scope, or nil
ctx.jump(win, index) -- index: nil = the lvim-ui picker; 1 = the outermost scope
```

A scope range is `{ srow, erow, hdr_end, type, engine }` (0-based rows; `hdr_end` is the last line of the scope's opener).

Every state change fires a `User` autocmd:

```lua
vim.api.nvim_create_autocmd("User", {
    pattern = "LvimContextChanged",
    callback = function(ev)
        -- ev.data = { buf = <bufnr>|nil, enabled = <boolean> }  (buf = nil → the global switch)
    end,
})
```

## Highlights

All groups are built from the live lvim-utils palette (accents and tint roles from the config) and rebuild on `ColorScheme` / palette sync:

| Group                                          | Paints                                             |
| ---------------------------------------------- | -------------------------------------------------- |
| `LvimContext`                                  | the pinned rows' background wash                    |
| `LvimContextError` / `LvimContextWarn`         | a pinned row whose scope contains an error/warning  |
| `LvimContextSeparator`                         | the rule under the header                           |
| `LvimContextLineNr`                            | the header's mirrored line numbers                  |
| `LvimContextCrumb` / `LvimContextCrumbSep`     | a winbar crumb / the `➤` between crumbs             |
| `LvimContextCrumbError` / `LvimContextCrumbWarn` | a crumb whose scope contains an error/warning     |

The pinned TEXT is never coloured by these groups — it carries the source buffer's own highlights, mirrored span for span.

## Health

`:checkhealth lvim-context` reports the dependency state, every glyph's display width, **the exclusion decision for the current buffer** (the exact reason when it gets no header), the engine that actually runs there (treesitter through lvim-ts vs the indent fallback, and the missing parsers when it falls back), the scopes resolved right now, and the measured cost of one cold resolution.

## License

BSD 3-Clause — see [LICENSE](LICENSE).
