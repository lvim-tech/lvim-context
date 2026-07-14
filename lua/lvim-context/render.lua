-- lvim-context.render: the STICKY HEADER — a floating overlay pinned to the first rows of its
-- parent window, holding the opening lines of the scopes that have scrolled off the top.
--
-- Why a float and not a decoration provider: the header must sit ABOVE the window's own text (it
-- replaces what the top rows would otherwise show), and no extmark can do that — only a window can.
-- It is chrome for ONE window (never a chooser — those go through lvim-ui), created lazily, kept in
-- sync on scroll / cursor moves and torn down with its parent. State is keyed by WINDOW: two splits
-- on the same buffer at different scroll positions each get their own header.
--
-- SOURCE-FAITHFUL COLOURS: the pinned line is not re-highlighted from scratch (that is where naive
-- implementations drift) — it is MIRRORED. For every pinned row both highlight layers of the source
-- buffer are copied onto the overlay row:
--   • the treesitter captures (queried from the same trees, injections included, with the same
--     `@capture.lang` group names and priorities the real highlighter uses), and
--   • every EXTMARK highlight namespace over that line (LSP semantic tokens, a rainbow layer, …).
-- The text is copied byte-for-byte, so every span lands on the same columns it has in the source.
--
-- ALIGNMENT: the overlay covers the parent's full width and reproduces the parent's gutter through
-- its own 'statuscolumn' (the mirrored line numbers when `line_numbers` is on, blanks otherwise), so
-- the pinned code sits in exactly the same screen column as the code below it. Horizontal scroll is
-- mirrored by scrolling the overlay window itself — the text stays byte-identical, so the copied
-- spans never have to be shifted.
--
---@module "lvim-context.render"

local api = vim.api
local ts = vim.treesitter

local config = require("lvim-context.config")
local guard = require("lvim-context.guard")
local scope = require("lvim-context.scope")

local M = {}

---@type integer  our extmark namespace on the overlay buffers (never on the source buffer)
local ns = api.nvim_create_namespace("LvimContext")

---@class LvimContextOverlay
---@field buf   integer                 the overlay's scratch buffer
---@field win    integer                the overlay's floating window
---@field parent integer                the window it is pinned to (its gutter is mirrored from there)
---@field key   string                  fingerprint of what is currently drawn (skip identical redraws)
---@field lnums integer[]               overlay row (1-based) → source line (1-based); 0 = the separator row
---@field gutter integer                display cells the overlay's statuscolumn must fill
---@field numbers boolean               render the mirrored line numbers in that gutter
---@field relative boolean              the parent numbers relatively (only read by `number_style = "auto"`)

---@type table<integer, LvimContextOverlay>  parent window → its header
local overlays = {}

---@type table<integer, LvimContextOverlay>  overlay buffer → its header (the statuscolumn's lookup)
local by_buf = {}

--- Is `buf` one of our overlay buffers? (The update loop must never treat a header as content.)
---@param buf integer
---@return boolean
function M.is_overlay_buf(buf)
    return by_buf[buf] ~= nil
end

--- Turn an `nvim_eval_statusline` result back into a 'statuscolumn' EXPRESSION: the evaluated text, cut at the
--- reported highlight spans and each piece wrapped in its own `%#group#`, with `%` escaped so a literal `%` in
--- the gutter is not re-interpreted. This is how the parent's rendered gutter is replayed in our window while
--- keeping its colours (sign hl, LineNr / CursorLineNr, the chrome's own groups).
---@param res { str: string, highlights: table[] }
---@return string
local function statuscol_expr(res)
    local text = res.str
    local hls = res.highlights or {}
    if #hls == 0 then
        return (text:gsub("%%", "%%%%"))
    end
    local out = {}
    for i, h in ipairs(hls) do
        local from = h.start + 1
        local to = hls[i + 1] and hls[i + 1].start or #text
        local piece = text:sub(from, to):gsub("%%", "%%%%")
        out[#out + 1] = ("%%#%s#%s"):format(h.group, piece)
    end
    return table.concat(out)
end

--- The overlay's 'statuscolumn' body: the mirrored gutter of the parent window — the source line
--- number of the row being drawn (right-aligned exactly like 'number' does it), or blanks, padded to
--- the parent's own gutter width so the pinned text lands in the parent's text column. The separator
--- row extends its rule across the gutter too, so the rule spans the full window.
---@return string
function M.statuscolumn()
    local buf = api.nvim_win_get_buf(vim.g.statusline_winid or 0)
    local ov = by_buf[buf]
    if not ov or ov.gutter <= 0 then
        return ""
    end
    local lnum = ov.lnums[vim.v.lnum] or 0
    if lnum == 0 then
        -- the separator row (or an unmapped row): the rule, or plain padding
        local sep = config.separator or "" -- false = off; the rest of the module reads "" as "no rule"
        if sep ~= "" and vim.v.lnum == #ov.lnums then
            return "%#LvimContextSeparator#" .. sep:rep(ov.gutter)
        end
        return "%#LvimContextLineNr#" .. (" "):rep(ov.gutter)
    end
    if not ov.numbers then
        return "%#LvimContextLineNr#" .. (" "):rep(ov.gutter)
    end
    -- `number_style = "auto"` — MIRROR the parent's own gutter. A hand-rolled number column can only ever
    -- imitate plain 'number': the moment the parent's gutter is a custom statuscolumn (a sign cell, a fold
    -- column, the `▌` rule of the lvim-hud chrome), our numbers land on a different column than the code below
    -- them. `nvim_eval_statusline` with `use_statuscol_lnum` renders the parent's OWN gutter for an arbitrary
    -- line — exactly the question being asked — so the header reproduces it decorations and all.
    --
    -- "absolute" / "relative" force the numbering instead, and then the mirror cannot be used: the parent's
    -- statuscolumn decides its own numbers, and its options may NOT be flipped from inside a redraw. Those
    -- modes therefore draw OUR number column, right-aligned in the parent's gutter WIDTH (so the code still
    -- lines up), without the parent's decorations.
    local style = config.number_style
    if style == "auto" then
        local pstc = ov.parent and api.nvim_win_is_valid(ov.parent) and vim.wo[ov.parent].statuscolumn or ""
        if pstc ~= "" then
            local ok, res = pcall(api.nvim_eval_statusline, pstc, {
                winid = ov.parent,
                use_statuscol_lnum = lnum,
                highlights = true,
            })
            if ok and res and res.str then
                return statuscol_expr(res)
            end
        end
    end
    local shown = lnum
    if style == "relative" or (style == "auto" and ov.relative) then
        local cur = ov.parent and api.nvim_win_is_valid(ov.parent) and api.nvim_win_get_cursor(ov.parent)[1] or lnum
        shown = math.abs(cur - lnum)
    end
    local text = tostring(shown)
    -- The number column reserves its last cell as the gap to the text (as 'number' does); a number
    -- too wide for the gutter would push the text out of alignment, so it yields to blanks.
    if #text > ov.gutter - 1 then
        return "%#LvimContextLineNr#" .. (" "):rep(ov.gutter)
    end
    return "%#LvimContextLineNr#" .. (" "):rep(ov.gutter - 1 - #text) .. text .. " "
end

--- Copy the source buffer's TREESITTER captures for one line onto the overlay row — the same trees
--- (injections included), the same `@capture.lang` group names and the same priorities the real
--- highlighter uses, so the pinned line reads exactly like the line it mirrors.
---@param src integer  source buffer
---@param srow integer  0-based source row
---@param dst integer  overlay buffer
---@param drow integer  0-based overlay row
---@return nil
local function mirror_treesitter(src, srow, dst, drow)
    local ok, parser = pcall(ts.get_parser, src, nil, { error = false })
    if not ok or not parser then
        return
    end
    -- A scrolled-off line is not necessarily inside the range the highlighter last parsed: ask for
    -- it explicitly (cheap — it is one line, and the trees are incremental).
    pcall(parser.parse, parser, { srow, srow + 1 })

    parser:for_each_tree(function(tstree, ltree)
        if not tstree then
            return
        end
        local root = tstree:root()
        local rsrow, _, rerow = root:range()
        if srow < rsrow or srow > rerow then
            return -- this tree does not cover the line (an injection elsewhere in the file)
        end
        local lang = ltree:lang()
        local query = ts.query.get(lang, "highlights")
        if not query then
            return
        end
        for id, node, metadata in query:iter_captures(root, src, srow, srow + 1) do
            local name = query.captures[id]
            if not name:find("^_") then -- `_`-prefixed captures are internal to the query
                local range = ts.get_range(node, src, metadata[id])
                local nsrow, nscol, nerow, necol = range[1], range[2], range[4], range[5]
                if nsrow <= srow and nerow >= srow then
                    local scol = nsrow == srow and nscol or 0
                    local ecol = nerow == srow and necol or -1
                    pcall(api.nvim_buf_set_extmark, dst, ns, drow, scol, {
                        end_col = ecol >= 0 and ecol or nil,
                        end_row = ecol < 0 and drow + 1 or nil,
                        hl_group = "@" .. name .. "." .. lang,
                        priority = tonumber(metadata.priority) or vim.hl.priorities.treesitter,
                        strict = false,
                    })
                end
            end
        end
    end)
end

--- Copy every EXTMARK highlight layer over one source line (LSP semantic tokens, a rainbow layer,
--- any plugin's namespace) onto the overlay row — the layers treesitter alone does not know about.
---@param src integer
---@param srow integer
---@param dst integer
---@param drow integer
---@return nil
local function mirror_extmarks(src, srow, dst, drow)
    local marks = api.nvim_buf_get_extmarks(src, -1, { srow, 0 }, { srow, -1 }, {
        details = true,
        overlap = true, -- a span that STARTS on an earlier line but reaches into this one
        type = "highlight",
    })
    for _, m in ipairs(marks) do
        local mrow, mcol, d = m[2], m[3], m[4]
        if d and d.hl_group then
            local erow = d.end_row or mrow
            local ecol = d.end_col
            if erow >= srow then
                local scol = mrow == srow and mcol or 0
                local end_col = (erow == srow and ecol) or nil
                pcall(api.nvim_buf_set_extmark, dst, ns, drow, scol, {
                    end_col = end_col,
                    end_row = end_col == nil and drow + 1 or nil,
                    hl_group = d.hl_group,
                    priority = d.priority,
                    hl_eol = d.hl_eol,
                    strict = false,
                })
            end
        end
    end
end

--- Close (and forget) a parent window's header.
---@param win integer
---@return nil
local function close(win)
    local ov = overlays[win]
    if not ov then
        return
    end
    overlays[win] = nil
    by_buf[ov.buf] = nil
    if api.nvim_win_is_valid(ov.win) then
        pcall(api.nvim_win_close, ov.win, true)
    end
    if api.nvim_buf_is_valid(ov.buf) then
        pcall(api.nvim_buf_delete, ov.buf, { force = true })
    end
end

--- Close every header (a global disable, or teardown).
---@return nil
function M.close_all()
    for win in pairs(overlays) do
        close(win)
    end
end

--- Close the header of a window that no longer exists / no longer qualifies.
---@param win integer
---@return nil
function M.close(win)
    close(win)
end

--- Create the overlay window + its scratch buffer for a parent window (once per parent).
---@param win integer
---@return LvimContextOverlay|nil
local function open(win)
    local buf = api.nvim_create_buf(false, true)
    vim.bo[buf].bufhidden = "wipe"
    vim.bo[buf].buftype = "nofile"
    vim.bo[buf].undolevels = -1

    local ok, ovwin = pcall(api.nvim_open_win, buf, false, {
        relative = "win",
        win = win,
        row = 0,
        col = 0,
        width = api.nvim_win_get_width(win),
        height = 1,
        -- Chrome: `focusable = false` keeps it out of the wincmd cycle (`<C-w>w` must never land in a
        -- header), while `mouse = true` still lets mouse events reach it — the pair is exactly what a
        -- clickable overlay needs. Without `mouse`, a non-focusable float is transparent to the
        -- pointer and the click lands on the code UNDER the header.
        focusable = false,
        mouse = true,
        style = "minimal",
        border = "none",
        zindex = config.zindex,
        noautocmd = true,
    })
    if not ok then
        pcall(api.nvim_buf_delete, buf, { force = true })
        return nil
    end

    vim.wo[ovwin].wrap = false -- a pinned line is one row, always
    vim.wo[ovwin].winhighlight = "Normal:LvimContext,NormalNC:LvimContext"
    vim.wo[ovwin].statuscolumn = "%{%v:lua.require'lvim-context.render'.statuscolumn()%}"

    local ov = { buf = buf, win = ovwin, parent = win, key = "", lnums = {}, gutter = 0, numbers = false }
    overlays[win] = ov
    by_buf[buf] = ov

    -- The header is a navigation surface: a click jumps to the line it shows. It goes through the
    -- ecosystem's mouse layer (lvim-utils.mouse), never a private global mouse map.
    local ok_mouse, mouse = pcall(require, "lvim-utils.mouse")
    if ok_mouse then
        mouse.lock(buf)
        mouse.register_click(buf, function(line)
            local nav = require("lvim-context.nav")
            mouse.defer_activation(function()
                nav.jump_row(win, line)
            end)
        end)
    end

    local key = config.keys.jump
    if key and key ~= "" then
        vim.keymap.set("n", key, function()
            local nav = require("lvim-context.nav")
            nav.jump_row(win, api.nvim_win_get_cursor(ovwin)[1])
        end, { buffer = buf, nowait = true, silent = true, desc = "lvim-context: jump to this context line" })
    end

    return ov
end

--- The header rows a window may actually keep: at least one row of real code must stay visible, and
--- the separator (when configured) costs a row of its own.
---@param win integer
---@param rows LvimContextRow[]
---@return LvimContextRow[]
local function fit(win, rows)
    local sep = (config.separator or "") ~= "" and 1 or 0
    local room = api.nvim_win_get_height(win) - 1 - sep
    if room < 1 then
        return {}
    end
    if #rows > room then
        return scope.trim(rows, room)
    end
    return rows
end

--- Draw (or refresh) the header of one parent window.
---@param win integer
---@return nil
function M.update(win)
    if config.style ~= "sticky" and config.style ~= "both" then
        close(win)
        return
    end
    if not guard.window_allowed(win) then
        close(win)
        return
    end
    local min_h = config.min_window_height or 0
    if min_h > 0 and api.nvim_win_get_height(win) < min_h then
        close(win)
        return
    end

    local view = scope.context(win)
    local rows = fit(win, view.rows)
    if #rows == 0 then
        close(win)
        return
    end

    local src = api.nvim_win_get_buf(win)
    local info = vim.fn.getwininfo(win)[1]
    local gutter = info and info.textoff or 0
    local width = api.nvim_win_get_width(win)
    local sep = config.separator or "" -- false = off
    local height = #rows + (sep ~= "" and 1 or 0)
    local leftcol = api.nvim_win_call(win, function()
        return vim.fn.winsaveview().leftcol
    end)

    -- Nothing to do when the same rows are already pinned in the same geometry.
    local diag = config.colors.diagnostics
    local fingerprint = { src, api.nvim_buf_get_changedtick(src), width, gutter, leftcol, sep, tostring(diag) }
    for _, r in ipairs(rows) do
        fingerprint[#fingerprint + 1] = r.row
    end
    local key = table.concat(fingerprint, ":")

    ---@type LvimContextOverlay|nil
    local ov = overlays[win]
    if not ov or not api.nvim_win_is_valid(ov.win) or not api.nvim_buf_is_valid(ov.buf) then
        close(win)
        ov = open(win)
        if not ov then
            return
        end
    elseif ov.key == key then
        return
    end

    -- The pinned text: the source lines, byte-for-byte (so every mirrored span lands on its column).
    local lines, lnums = {}, {}
    for i, r in ipairs(rows) do
        lines[i] = api.nvim_buf_get_lines(src, r.row, r.row + 1, false)[1] or ""
        lnums[i] = r.row + 1
    end
    if sep ~= "" then
        lines[#lines + 1] = sep:rep(math.max(0, width - gutter))
        lnums[#lnums + 1] = 0
    end

    vim.bo[ov.buf].modifiable = true
    api.nvim_buf_set_lines(ov.buf, 0, -1, false, lines)
    vim.bo[ov.buf].modifiable = false
    api.nvim_buf_clear_namespace(ov.buf, ns, 0, -1)

    ov.lnums = lnums
    ov.gutter = gutter
    ov.numbers = config.line_numbers and (vim.wo[win].number or vim.wo[win].relativenumber)
    ov.relative = vim.wo[win].relativenumber and not vim.wo[win].number -- 'auto' with no statuscolumn
    ov.key = key

    for i, r in ipairs(rows) do
        local drow = i - 1
        mirror_treesitter(src, r.row, ov.buf, drow)
        mirror_extmarks(src, r.row, ov.buf, drow)
        -- A scope containing an error / a warning takes the diagnostic wash (opt-in), so the header
        -- says "the function you are inside of is broken" without scrolling back to it.
        local line_hl = nil
        if diag then
            local sev = scope.severity(src, r.scope)
            line_hl = sev == "error" and "LvimContextError" or sev == "warn" and "LvimContextWarn" or nil
        end
        if line_hl then
            api.nvim_buf_set_extmark(ov.buf, ns, drow, 0, { line_hl_group = line_hl, priority = 1 })
        end
    end
    if sep ~= "" then
        api.nvim_buf_set_extmark(ov.buf, ns, #rows, 0, {
            end_row = #rows + 1,
            hl_group = "LvimContextSeparator",
            hl_eol = true,
            priority = 1,
        })
    end

    api.nvim_win_set_config(ov.win, {
        relative = "win",
        win = win,
        row = 0,
        col = 0,
        width = width,
        height = height,
        zindex = config.zindex,
    })
    -- Follow the parent's horizontal scroll by scrolling the overlay itself (the text is identical,
    -- so no span has to be re-mapped).
    api.nvim_win_call(ov.win, function()
        vim.fn.winrestview({ topline = 1, lnum = 1, leftcol = leftcol, col = leftcol })
    end)
end

--- The source line the innermost pinned scope of a window shows (the `line_for(win)` API).
---@param win integer
---@return integer|nil  1-based line, or nil when the window has no header
function M.line_for(win)
    local ov = overlays[win]
    if not ov then
        return nil
    end
    for i = #ov.lnums, 1, -1 do
        if ov.lnums[i] > 0 then
            return ov.lnums[i]
        end
    end
    return nil
end

--- The source line an overlay ROW shows (the click / `<CR>` target).
---@param win integer  the PARENT window
---@param row integer  1-based row in the overlay
---@return integer|nil  1-based source line
function M.lnum_at(win, row)
    local ov = overlays[win]
    if not ov then
        return nil
    end
    local lnum = ov.lnums[row]
    return (lnum and lnum > 0) and lnum or nil
end

return M
