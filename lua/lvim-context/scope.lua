-- lvim-context.scope: "what am I inside of" — the enclosing scopes of a WINDOW's anchor position,
-- outermost first, and the subset of their opening lines that has scrolled off the top (the sticky
-- context proper).
--
-- Everything here is keyed by WINDOW, never by buffer: two splits showing the same buffer at
-- different scroll positions (or with different cursors) have different contexts, and a resolver
-- keyed on the buffer would paint both headers the same — the classic bug of this plugin kind.
--
-- Two engines:
--   treesitter — the ancestor chain of the node at the anchor, filtered by the per-language node
--     lists (a node counts when its TYPE CONTAINS one of the configured strings, so one short list
--     survives every grammar's naming). The parser is reached through lvim-ts, the set's only
--     treesitter seam; the walk itself is Neovim's own vim.treesitter. Injections are honoured: the
--     language of the node lists is the language ACTUALLY at the anchor (an injected SQL string
--     inside Lua resolves against `sql`).
--   indent — pure indentation, no parser needed (a grammarless `.conf`, a log): an ancestor is the
--     first non-blank line above that is shallower than the level we are at, and its block runs to
--     the last line still at (or deeper than) its own indent + 1. The automatic fallback whenever
--     the treesitter engine finds no parser.
--
-- A scope's HEADER is what gets pinned: its first line, plus any further lines of the same OPENER
-- (a signature split over several lines). The opener ends where the BODY begins — the first child
-- starting below the opening line — and the body's own line is only part of the header when it
-- carries header text before it (`) -> T where T: Debug {`). Structural, so it needs no per-grammar
-- query and no per-language tuning.
--
---@module "lvim-context.scope"

local config = require("lvim-context.config")
local guard = require("lvim-context.guard")

local api = vim.api
local ts = vim.treesitter

local M = {}

---@class LvimContextScopeRange
---@field srow    integer  0-based first line of the scope (its opener's first line)
---@field erow    integer  0-based last line of the scope
---@field hdr_end integer  0-based last line of the scope's OPENER (>= srow, <= erow)
---@field type    string   the node type ("function_declaration"), or "indent" for the indent engine
---@field engine  "treesitter"|"indent"  which engine produced it

---@class LvimContextRow
---@field row   integer                 0-based SOURCE line the header row mirrors
---@field scope LvimContextScopeRange   the scope that row belongs to

---@class LvimContextView
---@field rows   LvimContextRow[]        the header rows, outermost first (already trimmed)
---@field scopes LvimContextScopeRange[] every enclosing scope, outermost first
---@field engine "treesitter"|"indent"|nil  the engine that resolved them
---@field top    integer                 0-based first visible line of the window

--- Resolved-scope cache, keyed by window: the ancestor walk is the expensive part and it only
--- changes when the buffer changes or the anchor moves — scrolling through one function must not
--- re-walk the tree on every row.
---@type table<integer, { key: string, scopes: LvimContextScopeRange[], engine: "treesitter"|"indent"|nil }>
local cache = {}

--- Drop the cache (a config merge or an explicit refresh changes what "counts" as a scope).
---@param win? integer  nil = every window
---@return nil
function M.invalidate(win)
    if win then
        cache[win] = nil
    else
        cache = {}
    end
end

--- Does `node_type` match one of the substring patterns listed for `lang` (or under `default`)?
---@param map table<string, string[]>
---@param lang string
---@param node_type string
---@return boolean
local function listed(map, lang, node_type)
    for _, key in ipairs({ lang, "default" }) do
        local list = map[key]
        if type(list) == "table" then
            for _, pat in ipairs(list) do
                if node_type:find(pat, 1, true) then
                    return true
                end
            end
        end
    end
    return false
end

--- A buffer line (empty string past the end).
---@param buf integer
---@param row integer  0-based
---@return string
local function line_at(buf, row)
    return api.nvim_buf_get_lines(buf, row, row + 1, false)[1] or ""
end

--- The byte column of the first non-blank character (0-based); the line's length when it is blank.
---@param s string
---@return integer
local function first_nonblank(s)
    local ws = s:match("^%s*") or ""
    return #ws
end

--- The scope's OPENER: the last line still belonging to the construct that opens the block (see
--- the module header for the rule).
---@param node TSNode
---@param buf integer
---@param srow integer
---@param erow integer
---@return integer  0-based last line of the opener
local function opener_end(node, buf, srow, erow)
    local body, first_below = nil, nil
    for child in node:iter_children() do
        local csr, _, cer = child:range()
        if csr > srow then
            first_below = first_below or child
            if cer > csr then
                body = child -- the first MULTI-LINE child below the opening line: the block itself
                break
            end
        end
    end
    body = body or first_below
    if not body then
        return srow
    end
    local bsr, bsc = body:range()
    local hdr_end = bsr - 1
    -- The body's own line belongs to the opener when there is header text BEFORE it on that line
    -- (`) -> T where T: Debug {`); when the body starts at the line's first non-blank column it IS
    -- the first body line (a Python suite, a Lua block) and stays out.
    if bsc > first_nonblank(line_at(buf, bsr)) then
        hdr_end = bsr
    end
    return math.min(math.max(hdr_end, srow), erow)
end

--- The treesitter engine: the ancestor chain at the anchor, filtered by the node lists.
---@param buf integer
---@param row integer  0-based anchor row
---@param col integer  0-based anchor column
---@return LvimContextScopeRange[]|nil  nil = no parser here (fall back to the indent engine)
local function ts_scopes(buf, row, col)
    local ok, parser = pcall(ts.get_parser, buf, nil, { error = false })
    if not ok or not parser then
        return nil
    end
    -- The language ACTUALLY at the anchor (an injected block resolves against its own grammar), with
    -- lvim-ts's filetype→language mapping as the fallback when the range lookup yields nothing.
    local lang
    local ok_range, ltree = pcall(parser.language_for_range, parser, { row, col, row, col })
    if ok_range and ltree then
        lang = ltree:lang()
    end
    if not lang then
        local ok_ts, lts = pcall(require, "lvim-ts")
        lang = (ok_ts and lts.lang_for_buf(buf)) or vim.bo[buf].filetype
    end

    local ok_node, node = pcall(ts.get_node, { bufnr = buf, pos = { row, col } })
    if not ok_node or not node then
        return {}
    end

    local out = {}
    while node do
        local t = node:type()
        if listed(config.scope.nodes, lang, t) and not listed(config.scope.exclude_nodes, lang, t) then
            local srow, _, erow, ecol = node:range()
            if ecol == 0 then
                erow = erow - 1 -- a node ending at column 0 does not own that line
            end
            if erow > srow then
                table.insert(out, 1, {
                    srow = srow,
                    erow = erow,
                    hdr_end = opener_end(node, buf, srow, erow),
                    type = t,
                    engine = "treesitter",
                })
            end
        end
        node = node:parent()
    end
    return out
end

--- The display indent of a line, and whether it is blank.
---@param buf integer
---@param row integer
---@return integer indent  display width of the leading whitespace
---@return boolean blank
local function indent_of(buf, row)
    local s = line_at(buf, row)
    if s:match("^%s*$") then
        return 0, true
    end
    return vim.fn.strdisplaywidth(s:sub(1, first_nonblank(s))), false
end

--- The indent engine: the enclosing blocks derived from indentation alone.
---@param buf integer
---@param row integer  0-based anchor row
---@return LvimContextScopeRange[]
local function indent_scopes(buf, row)
    local total = api.nvim_buf_line_count(buf)
    -- A blank anchor line has no indent of its own: take the next non-blank line's.
    local depth, blank = indent_of(buf, row)
    if blank then
        for r = row + 1, total - 1 do
            local d, b = indent_of(buf, r)
            if not b then
                depth = d
                break
            end
        end
    end

    local out = {}
    local level = depth
    for r = row - 1, 0, -1 do
        local d, b = indent_of(buf, r)
        if not b and d < level then
            -- `r` heads a block: it runs down to the last line still deeper than it.
            local erow = r
            for rr = r + 1, total - 1 do
                local dd, bb = indent_of(buf, rr)
                if bb then
                    -- a blank line neither ends nor extends the block
                elseif dd > d then
                    erow = rr
                else
                    break
                end
            end
            if erow > r then
                table.insert(out, 1, { srow = r, erow = erow, hdr_end = r, type = "indent", engine = "indent" })
            end
            level = d
            if level == 0 then
                break
            end
        end
    end
    return out
end

--- The window's anchor position: the cursor (mode "cursor") or its top line (mode "topline").
---@param win integer
---@param buf integer
---@return integer row  0-based
---@return integer col  0-based
local function anchor(win, buf)
    if config.mode == "topline" then
        local top = vim.fn.line("w0", win) - 1
        return top, first_nonblank(line_at(buf, top))
    end
    local pos = api.nvim_win_get_cursor(win)
    local row = pos[1] - 1
    local len = #line_at(buf, row)
    return row, math.max(0, math.min(pos[2], math.max(0, len - 1)))
end

--- Every scope enclosing the window's anchor, outermost first — the public resolution (the
--- `scopes(win)` API other lvim-* plugins reuse), cached per window.
---@param win integer
---@return LvimContextScopeRange[] scopes
---@return "treesitter"|"indent"|nil engine
function M.enclosing(win)
    if not guard.window_allowed(win) then
        return {}, nil
    end
    local buf = api.nvim_win_get_buf(win)
    local row, col = anchor(win, buf)
    local key = ("%d:%d:%d:%d"):format(buf, api.nvim_buf_get_changedtick(buf), row, col)
    local hit = cache[win]
    if hit and hit.key == key then
        return hit.scopes, hit.engine
    end

    local scopes, engine = nil, config.scope.engine
    if engine == "treesitter" then
        scopes = ts_scopes(buf, row, col)
        if not scopes then
            engine = "indent" -- no parser in this buffer: the fallback, silently
        end
    end
    if engine == "indent" then
        scopes = indent_scopes(buf, row)
    end
    scopes = scopes or {}
    cache[win] = { key = key, scopes = scopes, engine = engine }
    return scopes, engine
end

--- Cap a header to `cap` rows, dropping the end `trim_scope` names: "outer" drops the OUTERMOST rows
--- (the innermost scopes — the ones you are actually in — survive), "inner" drops the innermost.
--- Also the renderer's seam for a window too short to hold the whole header.
---@param rows LvimContextRow[]
---@param cap integer  0 = no cap
---@return LvimContextRow[]
function M.trim(rows, cap)
    if cap <= 0 or #rows <= cap then
        return rows
    end
    local kept = {}
    for i = 1, cap do
        kept[i] = config.trim_scope == "inner" and rows[i] or rows[#rows - cap + i]
    end
    return kept
end

--- The header rows for a window: the opening lines of the enclosing scopes that have scrolled OFF
--- the top.
---
-- The subtle part is WHAT "scrolled off" means once a header exists: the header OVERLAYS the
-- window's first rows, so it hides as many source lines as it is tall (its rows plus the separator
-- rule). A scope therefore counts while its opener sits above the first line the header still leaves
-- visible — and every row the header grows by pushes that line one further down, which can pull the
-- NEXT scope in. Growing the header row by row (outermost first) settles exactly that fixpoint;
-- forgetting the separator's row is what makes an opener vanish behind the rule instead of being
-- pinned. `multiline_threshold` then collapses an over-long opener to its first line, and
-- `max_lines` / `trim_scope` cap the height.
---@param win integer
---@return LvimContextView
function M.context(win)
    local scopes, engine = M.enclosing(win)
    local top = vim.fn.line("w0", win) - 1
    local sep_rows = (config.separator or "") ~= "" and 1 or 0
    ---@type LvimContextRow[]
    local rows = {}

    for _, s in ipairs(scopes) do
        -- the first source line the header does not already cover (0 rows = no header, no rule)
        local at = top + #rows + (#rows > 0 and sep_rows or 0)
        if s.srow < at and s.erow > at then
            local last = s.hdr_end
            local span = last - s.srow + 1
            local threshold = config.multiline_threshold or 0
            if threshold > 0 and span > threshold then
                last = s.srow -- an opener longer than the threshold collapses to its first line
            end
            for r = s.srow, last do
                rows[#rows + 1] = { row = r, scope = s }
            end
        end
    end

    return { rows = M.trim(rows, config.max_lines or 0), scopes = scopes, engine = engine, top = top }
end

--- The worst diagnostic severity INSIDE a scope's range ("error" > "warn"), or nil.
--- Opt-in (`colors.diagnostics`): the header then says "the function you are deep inside of is
--- broken" without scrolling back to its signature.
---@param buf integer
---@param s LvimContextScopeRange
---@return "error"|"warn"|nil
function M.severity(buf, s)
    local sev = vim.diagnostic.severity
    local worst = nil
    for _, d in ipairs(vim.diagnostic.get(buf, { severity = { min = sev.WARN } })) do
        if d.lnum >= s.srow and d.lnum <= s.erow then
            if d.severity == sev.ERROR then
                return "error"
            end
            worst = "warn"
        end
    end
    return worst
end

return M
