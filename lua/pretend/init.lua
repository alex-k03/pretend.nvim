--- pretend.nvim: Neovim front end for git-pretend (https://github.com/alex-k03/git-pretend).
---
--- git-pretend makes a range of commits look like uncommitted changes, so gitsigns, LSP, grep and
--- diff views all work on it. This plugin adds a commit picker, statusline helpers, and reloads
--- buffers when you start and stop. All git work happens in the CLI.
local M = {}
local overlay = require("pretend.overlay")

---@class pretend.Config
---@field cmd string|string[] The git-pretend executable, or a command list to run it with
---@field overlay boolean Automatically show the inline diff overlay (previous/deleted lines) while pretending
---@field open false|"auto"|fun(state: pretend.State) What to open after starting (off by default; "auto": CodeDiff or Diffview if installed)
---@field close false|"auto"|fun() What to close after stopping (off by default; "auto": codediff / diffview tabs opened since starting)
---@field startup_notice boolean Remind on startup when a previous session left you pretending
local defaults = {
    cmd = "git-pretend",
    overlay = false,
    open = false,
    close = false,
    startup_notice = true,
}

---@type pretend.Config
M.config = vim.deepcopy(defaults)

---@class pretend.State
---@field version string
---@field prev_ref string refs/heads/<branch>, or "" if HEAD was detached
---@field prev_commit string
---@field base string The commit HEAD is at
---@field target string The commit the working tree is at
---@field branch string The branch you will go back to, or the commit if you started detached

local levels = vim.log.levels

local function notify(msg, level)
    vim.notify(msg, level or levels.INFO, { title = "pretend" })
end

local function command(args)
    local cmd = M.config.cmd
    return vim.list_extend(type(cmd) == "table" and vim.deepcopy(cmd) or { cmd }, args)
end

local function missing_cli()
    notify(
        "Can't run " .. table.concat(command({}), " ") .. ". Install git-pretend "
            .. "(https://github.com/alex-k03/git-pretend) or set `cmd` in setup().",
        levels.ERROR
    )
end

--- Runs git-pretend asynchronously; cb(result) runs on the main loop.
local function run(args, cb)
    local ok = pcall(vim.system, command(args), { text = true, cwd = vim.fn.getcwd() }, function(res)
        vim.schedule(function() cb(res) end)
    end)
    if not ok then
        missing_cli()
    end
end

local function output(res)
    return vim.trim((res.stdout or "") .. "\n" .. (res.stderr or ""))
end

local function repo_root()
    local res = vim.system({ "git", "rev-parse", "--show-toplevel" }, { text = true, cwd = vim.fn.getcwd() }):wait()
    if res.code ~= 0 then
        return nil
    end
    return vim.trim(res.stdout)
end

--- Modified file buffers inside the repository. Buffer names are resolved because
--- --show-toplevel is (/tmp vs /private/tmp on macOS).
local function modified_buffers(root)
    local bufs = {}
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
        local name = vim.api.nvim_buf_get_name(buf)
        if name ~= "" and vim.bo[buf].modified and vim.bo[buf].buftype == "" then
            local real = vim.uv.fs_realpath(name) or name
            if vim.startswith(real, root .. "/") then
                table.insert(bufs, buf)
            end
        end
    end
    return bufs
end

local current ---@type pretend.State|nil

---@param stdout string
---@return pretend.State
local function parse_state(stdout)
    local state = {}
    for line in stdout:gmatch("[^\n]+") do
        local key, value = line:match("^(%S+) ?(.*)$")
        if key then
            state[(key:gsub("-", "_"))] = value
        end
    end
    -- What git-pretend's `status --short` prints, without running it again
    state.branch = state.prev_ref ~= "" and state.prev_ref:gsub("^refs/heads/", "") or state.prev_commit:sub(1, 7)
    return state
end

--- What is being pretended in the current directory's repository, or nil.
---@return pretend.State|nil
function M.status()
    local ok, obj = pcall(vim.system, command({ "status", "--porcelain" }), { text = true, cwd = vim.fn.getcwd() })
    if not ok then
        return nil
    end
    local res = obj:wait()
    if res.code ~= 0 then
        current = nil
        return nil
    end
    current = parse_state(res.stdout)
    return current
end

--- While pretending HEAD is detached, so a statusline's branch component shows a commit hash.
--- This is the branch you will go back to (or commit, if you started detached), else nil. Cached.
---@return string|nil
function M.branch()
    return current and current.branch
end

--- For a statusline: "pretend" while pretending, else "". Cached, so cheap.
function M.statusline()
    return current and "pretend" or ""
end

local function redraw_statusline()
    if package.loaded.lualine then
        require("lualine").refresh()
    else
        vim.cmd.redrawstatus()
    end
end

local function refresh_statusline(cb)
    local ok = pcall(vim.system, command({ "status", "--porcelain" }), { text = true, cwd = vim.fn.getcwd() }, function(res)
        vim.schedule(function()
            current = res.code == 0 and parse_state(res.stdout) or nil
            local root = (current or overlay.is_visible()) and repo_root() or nil
            overlay.sync(current, root)
            redraw_statusline()
            if cb then
                cb(current)
            end
        end)
    end)
    if not ok then
        current = nil
        overlay.sync(nil, nil)
        if cb then
            cb(nil)
        end
    end
end

-- Tabs that existed when pretending started, so close_view only closes tabs opened since
local tabs_before ---@type table<integer, true>|nil
local diff_filetypes = { ["codediff-explorer"] = true, DiffviewFiles = true }

local function remember_tabs()
    tabs_before = {}
    for _, tab in ipairs(vim.api.nvim_list_tabpages()) do
        tabs_before[tab] = true
    end
end

local function open_view(state)
    local open = M.config.open
    if type(open) == "function" then
        open(state)
    elseif open == "auto" then
        if vim.fn.exists(":CodeDiff") == 2 then
            vim.cmd("CodeDiff")
        elseif vim.fn.exists(":DiffviewOpen") == 2 then
            vim.cmd("DiffviewOpen")
        end
    end
end

--- After stopping, the diff view shows changes that are gone. Closes the codediff / diffview tabs
--- opened since starting (by `open`, or by hand); other tabs are left alone.
local function close_view()
    local close = M.config.close
    if type(close) == "function" then
        return close()
    end
    if close ~= "auto" or not tabs_before then
        return
    end
    local stale = {}
    for _, tab in ipairs(vim.api.nvim_list_tabpages()) do
        if not tabs_before[tab] then
            for _, win in ipairs(vim.api.nvim_tabpage_list_wins(tab)) do
                if diff_filetypes[vim.bo[vim.api.nvim_win_get_buf(win)].filetype] then
                    table.insert(stale, tab)
                    break
                end
            end
        end
    end
    for _, tab in ipairs(stale) do
        if vim.api.nvim_tabpage_is_valid(tab) and #vim.api.nvim_list_tabpages() > 1 then
            vim.cmd.tabclose(vim.api.nvim_tabpage_get_number(tab))
        end
    end
    tabs_before = nil
end

local function check_start_ready()
    local root = repo_root()
    if not root then
        notify("Not in a git repository", levels.WARN)
        return nil
    end
    -- The checkout rewrites files on disk, and unsaved edits would end up on top of the wrong code
    local dirty = modified_buffers(root)
    if #dirty > 0 then
        local names = vim.tbl_map(function(b) return vim.fn.fnamemodify(vim.api.nvim_buf_get_name(b), ":~:.") end, dirty)
        notify("Save or discard your unsaved changes first:\n" .. table.concat(names, "\n"), levels.WARN)
        return nil
    end
    return root
end

--- Starts pretending. args are git-pretend's: { "<commit>" }, { "<old>", "<new>" },
--- { "main..." }, ...
---@param args string[]
function M.start(args)
    if not check_start_ready() then
        return
    end
    run(args, function(res)
        if res.code ~= 0 then
            return notify(output(res), levels.ERROR)
        end
        vim.cmd.checktime() -- reload open buffers from the new working tree
        notify(output(res))
        refresh_statusline(function(state)
            remember_tabs()
            open_view(state)
        end)
    end)
end

--- Stops pretending: git-pretend discards the pretend changes (saving edits as a patch), and
--- unsaved buffer edits in the repository are reverted to what is on disk again.
function M.done()
    local root = repo_root()
    run({ "done" }, function(res)
        if res.code ~= 0 then
            return notify(output(res), levels.ERROR)
        end
        if root then
            for _, buf in ipairs(modified_buffers(root)) do
                vim.api.nvim_buf_call(buf, function() vim.cmd("edit!") end)
            end
        end
        vim.cmd.checktime()
        close_view()
        refresh_statusline()
        notify(output(res))
    end)
end

--- Picks one or two commits from the git log. cb(from, to) gets git-pretend's arguments:
--- one commit gives (commit^, commit), two give (older, newer). Uses the Snacks picker when
--- available, else the built-in floating picker (both support <Tab> to select two).
---@param opts? { title?: string }
---@param cb fun(from: string, to: string, cwd: string)
function M.pick_commits(opts, cb)
    opts = opts or {}
    local title = opts.title or "Pretend: <Tab> two commits for a range"
    local has_snacks, snacks = pcall(require, "snacks")
    if has_snacks and snacks.picker then
        snacks.picker.git_log({
            title = title,
            confirm = function(picker)
                local items = picker:selected({ fallback = true })
                if #items == 0 then
                    return
                end
                if #items > 2 then
                    return notify("Select one commit, or two for the range between them", levels.WARN)
                end
                picker:close()
                -- Log order is newest first, so the higher idx is the older commit
                table.sort(items, function(a, b) return a.idx > b.idx end)
                local from, to = items[1].commit, items[#items].commit
                if #items == 1 then
                    from = from .. "^"
                end
                cb(from, to, items[1].cwd or vim.fn.getcwd())
            end,
        })
        return
    end

    require("pretend.picker").pick({ title = title }, cb)
end

--- Picks commits and starts pretending.
function M.pick()
    if M.status() then
        return notify("Already pretending; run :Pretend done first", levels.WARN)
    end
    if not check_start_ready() then
        return
    end
    M.pick_commits(nil, function(from, to)
        M.start(from == to .. "^" and { to } or { from, to })
    end)
end

--- Done if pretending, else pick commits and start.
function M.toggle()
    if M.status() then
        M.done()
    else
        M.pick()
    end
end

--- Toggles the inline diff overlay (previous/deleted lines in buffers; works while pretending
--- and on normal uncommitted changes).
function M.toggle_overlay()
    local on = overlay.toggle(repo_root())
    if on == nil then
        return notify("Not in a git repository", levels.WARN)
    end
    notify("Inline diff overlay " .. (on and "on" or "off"))
end

--- :Pretend [<commit> | <old> <new> | <range> | pick | status | overlay | done]
function M.command(args)
    if #args == 0 then
        if M.status() then
            args = { "status" }
        else
            return M.pick()
        end
    end
    local sub = args[1]
    if sub == "done" then
        M.done()
    elseif sub == "pick" then
        M.pick()
    elseif sub == "overlay" then
        M.toggle_overlay()
    elseif sub == "status" then
        run({ "status" }, function(res) notify(output(res)) end)
    else
        M.start(args)
    end
end

function M.complete(arg_lead, cmd_line)
    local before = (cmd_line or ""):sub(1, #(cmd_line or "") - #arg_lead)
    local is_first_arg = #vim.split(vim.trim(before), "%s+", { trimempty = true }) <= 1
    local items = is_first_arg and { "done", "overlay", "pick", "status" } or {}
    local res = vim.system(
        { "git", "for-each-ref", "--format=%(refname:short)", "refs/heads", "refs/remotes", "refs/tags" },
        { text = true, cwd = vim.fn.getcwd() }
    ):wait()
    if res.code == 0 then
        vim.list_extend(items, vim.split(vim.trim(res.stdout), "\n", { trimempty = true }))
    end
    return vim.tbl_filter(function(item) return vim.startswith(item, arg_lead) end, items)
end

---@param opts? pretend.Config
function M.setup(opts)
    M.config = vim.tbl_deep_extend("force", vim.deepcopy(defaults), opts or {})
    overlay.set_auto(M.config.overlay == true)

    local group = vim.api.nvim_create_augroup("pretend", { clear = true })
    -- Pretending can start or stop outside Neovim (the CLI in a terminal), so check again
    vim.api.nvim_create_autocmd({ "FocusGained", "DirChanged" }, {
        group = group,
        callback = function() vim.schedule(function() refresh_statusline() end) end,
    })

    local function check_on_startup()
        refresh_statusline(function(state)
            if M.config.startup_notice and state then
                notify(("Still pretending (HEAD %s, working tree %s). :Pretend done to stop."):format(
                    state.base:sub(1, 7), state.target:sub(1, 7)))
            end
        end)
    end
    if vim.v.vim_did_enter == 1 then
        vim.schedule(check_on_startup)
    else
        vim.api.nvim_create_autocmd("VimEnter", { group = group, once = true, callback = check_on_startup })
    end
end

return M
