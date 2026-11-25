--- Minimal zero-dependency floating commit picker for pretend.nvim.
--- Used when snacks.nvim is not installed: j/k to move, <Tab> to mark up to two commits,
--- <CR> to confirm (one commit or the range between two), q/<Esc> to cancel.
local M = {}

local ns = vim.api.nvim_create_namespace("pretend.picker")

---@param opts { title?: string }
---@param cb fun(from: string, to: string, cwd: string)
function M.pick(opts, cb)
    local cwd = vim.fn.getcwd()
    local res = vim.system(
        { "git", "log", "--max-count=300", "--format=%h %ad %s", "--date=short" },
        { text = true, cwd = cwd }
    ):wait()
    if res.code ~= 0 then
        return vim.notify("git log failed: " .. vim.trim(res.stderr or ""), vim.log.levels.ERROR, { title = "pretend" })
    end

    local lines = vim.split(vim.trim(res.stdout or ""), "\n", { trimempty = true })
    if #lines == 0 then
        return vim.notify("No commits found", vim.log.levels.WARN, { title = "pretend" })
    end

    local buf = vim.api.nvim_create_buf(false, true)
    vim.bo[buf].buftype = "nofile"
    vim.bo[buf].bufhidden = "wipe"
    vim.bo[buf].swapfile = false
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.bo[buf].modifiable = false

    -- Light syntax highlighting for hash and date
    local hl_ns = vim.api.nvim_create_namespace("pretend.picker.hl")
    for i, line in ipairs(lines) do
        local hash_end = line:find(" ")
        if hash_end then
            vim.api.nvim_buf_set_extmark(buf, hl_ns, i - 1, 0, { end_col = hash_end - 1, hl_group = "Constant" })
            local date_end = line:find(" ", hash_end + 1)
            if date_end then
                vim.api.nvim_buf_set_extmark(buf, hl_ns, i - 1, hash_end, { end_col = date_end - 1, hl_group = "Comment" })
            end
        end
    end

    local width = math.min(math.max(60, math.floor(vim.o.columns * 0.7)), vim.o.columns - 4)
    local height = math.min(#lines, math.max(8, math.floor(vim.o.lines * 0.5)), vim.o.lines - 6)
    local title = " " .. (opts.title or "Pretend: <Tab> two commits for a range") .. " "

    local win = vim.api.nvim_open_win(buf, true, {
        relative = "editor",
        width = width,
        height = height,
        row = math.floor((vim.o.lines - height) / 2) - 1,
        col = math.floor((vim.o.columns - width) / 2),
        style = "minimal",
        border = "rounded",
        title = title,
        title_pos = "center",
        footer = " <Tab> select | <CR> confirm | q/<Esc> cancel ",
        footer_pos = "center",
    })
    vim.wo[win].cursorline = true
    vim.wo[win].signcolumn = "yes:1"

    ---@type integer[] 1-based line numbers
    local selected = {}

    local function redraw_marks()
        vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
        for _, lnum in ipairs(selected) do
            vim.api.nvim_buf_set_extmark(buf, ns, lnum - 1, 0, {
                line_hl_group = "Visual",
                sign_text = "●",
                sign_hl_group = "Special",
            })
        end
    end

    local function close()
        if vim.api.nvim_win_is_valid(win) then
            vim.api.nvim_win_close(win, true)
        end
    end

    local function map(lhs, fn)
        vim.keymap.set("n", lhs, fn, { buffer = buf, nowait = true, silent = true })
    end

    map("q", close)
    map("<Esc>", close)

    map("<Tab>", function()
        local lnum = vim.api.nvim_win_get_cursor(win)[1]
        for i, existing in ipairs(selected) do
            if existing == lnum then
                table.remove(selected, i)
                redraw_marks()
                return
            end
        end
        if #selected >= 2 then
            return vim.notify("Select one commit, or two for the range between them", vim.log.levels.WARN, { title = "pretend" })
        end
        table.insert(selected, lnum)
        redraw_marks()
        if lnum < #lines then
            vim.api.nvim_win_set_cursor(win, { lnum + 1, 0 })
        end
    end)

    map("<CR>", function()
        local picks = #selected > 0 and vim.deepcopy(selected) or { vim.api.nvim_win_get_cursor(win)[1] }
        close()
        -- Log order is newest first, so the higher line number is the older commit
        table.sort(picks, function(a, b) return a > b end)
        local from = lines[picks[1]]:match("^%S+")
        local to = lines[picks[#picks]]:match("^%S+")
        if #picks == 1 then
            from = from .. "^"
        end
        cb(from, to, cwd)
    end)
end

return M
