--- In-buffer inline diff overlay for pretend.nvim.
--- Uses Neovim's built-in vim.diff() and virt_lines extmarks to show removed/previous lines
--- above changed lines without modifying the real buffer (so LSP, treesitter, etc. keep working).
--- Works while pretending and on normal uncommitted changes alike.
local M = {}

local ns = vim.api.nvim_create_namespace("pretend.overlay")

---@type table<integer, { key: string, lines: string[]|false }>
local base_cache = {}
---@type table<integer, integer>
local top_virt_counts = {}

local visible = false
local auto_enabled = false
local auto_on = false
local current_root ---@type string|nil
local current_base ---@type string|nil -- pretend base commit, or nil when diffing normal HEAD

local function split_lines(str)
    if str == "" then
        return {}
    end
    local lines = vim.split(str, "\n", { plain = true })
    if lines[#lines] == "" then
        table.remove(lines)
    end
    return lines
end

local function clear_buf(buf)
    top_virt_counts[buf] = nil
    if vim.api.nvim_buf_is_valid(buf) then
        vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
    end
end

local function clear_all()
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
        clear_buf(buf)
    end
    base_cache = {}
    top_virt_counts = {}
end

local function reveal_top_in_win(win, count)
    if count <= 0 or not vim.api.nvim_win_is_valid(win) then
        return
    end
    vim.api.nvim_win_call(win, function()
        local view = vim.fn.winsaveview()
        if view.topline == 1 and view.topfill < count then
            vim.fn.winrestview({ topfill = count })
        end
    end)
end

local function reveal_top_virt_lines(buf, count)
    if count <= 0 then
        return
    end
    for _, win in ipairs(vim.fn.win_findbuf(buf)) do
        reveal_top_in_win(win, count)
    end
end

local function apply_diff(buf, old_lines)
    if not visible or not vim.api.nvim_buf_is_valid(buf) then
        return
    end
    clear_buf(buf)

    local new_lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    if #new_lines == 0 then
        return
    end

    -- File does not exist in HEAD (newly added)
    if old_lines == false then
        for row = 0, #new_lines - 1 do
            vim.api.nvim_buf_set_extmark(buf, ns, row, 0, {
                line_hl_group = "DiffAdd",
                priority = 10,
            })
        end
        return
    end

    local old_text = #old_lines > 0 and (table.concat(old_lines, "\n") .. "\n") or ""
    local new_text = table.concat(new_lines, "\n") .. "\n"
    local hunks = vim.diff(old_text, new_text, {
        result_type = "indices",
        algorithm = "histogram",
    })

    local top_virt_count = 0
    for _, hunk in ipairs(hunks) do
        local start_a, count_a, start_b, count_b = hunk[1], hunk[2], hunk[3], hunk[4]

        -- Highlight added / replacement lines in the buffer
        if count_b > 0 then
            for i = 0, count_b - 1 do
                local row = start_b - 1 + i
                if row < #new_lines then
                    vim.api.nvim_buf_set_extmark(buf, ns, row, 0, {
                        line_hl_group = "DiffAdd",
                        priority = 10,
                    })
                end
            end
        end

        -- Render deleted / previous lines as virtual lines
        if count_a > 0 then
            local virt_lines = {}
            for i = 0, count_a - 1 do
                local text = old_lines[start_a + i] or ""
                table.insert(virt_lines, { { text == "" and " " or text, "DiffDelete" } })
            end

            local row, above
            if count_b > 0 then
                row = start_b - 1
                above = true
            elseif start_b == 0 then
                row = 0
                above = true
            else
                row = math.min(start_b - 1, #new_lines - 1)
                above = false
            end

            vim.api.nvim_buf_set_extmark(buf, ns, row, 0, {
                virt_lines = virt_lines,
                virt_lines_above = above,
                priority = 10,
            })

            if row == 0 and above then
                top_virt_count = top_virt_count + #virt_lines
            end
        end
    end

    if top_virt_count > 0 then
        top_virt_counts[buf] = top_virt_count
        reveal_top_virt_lines(buf, top_virt_count)
    end
end

local function cache_key()
    return (current_root or "") .. ":" .. (current_base or "HEAD")
end

local function render_buf(buf)
    if not visible or not current_root then
        return
    end
    if not vim.api.nvim_buf_is_valid(buf) or not vim.api.nvim_buf_is_loaded(buf) then
        return
    end
    if vim.bo[buf].buftype ~= "" then
        return
    end

    local name = vim.api.nvim_buf_get_name(buf)
    if name == "" then
        return
    end
    local real = vim.uv.fs_realpath(name) or name
    local prefix = current_root .. "/"
    if not vim.startswith(real, prefix) then
        return
    end

    local key = cache_key()
    local cached = base_cache[buf]
    if cached and cached.key == key then
        apply_diff(buf, cached.lines)
        return
    end

    local rel = real:sub(#prefix + 1)
    local root_at_req = current_root
    vim.system({ "git", "show", "HEAD:" .. rel }, { text = true, cwd = root_at_req }, function(res)
        vim.schedule(function()
            if not visible or cache_key() ~= key then
                return
            end
            local old_lines = res.code == 0 and split_lines(res.stdout or "") or false
            base_cache[buf] = { key = key, lines = old_lines }
            apply_diff(buf, old_lines)
        end)
    end)
end

local function render_all()
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
        if vim.api.nvim_buf_is_loaded(buf) then
            render_buf(buf)
        end
    end
end

local function setup_autocmds()
    local group = vim.api.nvim_create_augroup("pretend_overlay", { clear = true })
    if not visible then
        return
    end
    vim.api.nvim_create_autocmd({ "BufEnter", "BufReadPost", "TextChanged", "TextChangedI" }, {
        group = group,
        callback = function(ev) render_buf(ev.buf) end,
    })
    -- Reveal virtual lines above line 1 when scrolling back up to the top (only on upward scroll,
    -- so CTRL-E can still scroll them out of view)
    vim.api.nvim_create_autocmd("WinScrolled", {
        group = group,
        callback = function()
            for win, delta in pairs(vim.v.event) do
                if win ~= "all" and delta.topline < 0 then
                    local winid = tonumber(win)
                    if winid and vim.api.nvim_win_is_valid(winid) then
                        local count = top_virt_counts[vim.api.nvim_win_get_buf(winid)]
                        if count and count > 0 then
                            vim.schedule(function() reveal_top_in_win(winid, count) end)
                        end
                    end
                end
            end
        end,
    })
    vim.api.nvim_create_autocmd("BufUnload", {
        group = group,
        callback = function(ev)
            base_cache[ev.buf] = nil
            top_virt_counts[ev.buf] = nil
        end,
    })
end

--- Configures whether the overlay turns on automatically when pretending starts.
---@param enabled boolean
function M.set_auto(enabled)
    auto_enabled = enabled
end

---@return boolean
function M.is_visible()
    return visible
end

--- Syncs overlay state with pretend status (called on start, done, focus, cd, startup).
---@param state pretend.State|nil
---@param root string|nil
function M.sync(state, root)
    if state and root then
        local changed = current_base ~= state.base or current_root ~= root
        current_base = state.base
        current_root = root
        if changed then
            base_cache = {}
        end
        if auto_enabled and not visible then
            visible = true
            auto_on = true
            setup_autocmds()
            render_all()
        elseif visible and changed then
            render_all()
        end
    else
        local was_pretending = current_base ~= nil
        current_base = nil
        if root then
            current_root = root
        end
        if was_pretending and auto_on then
            visible = false
            auto_on = false
            setup_autocmds()
            clear_all()
        elseif visible then
            -- Refresh against current HEAD (e.g. after commit or leaving pretend while manually on)
            base_cache = {}
            if current_root then
                render_all()
            else
                clear_all()
            end
        end
    end
end

--- Toggles the inline diff overlay on or off (works while pretending and on normal git changes).
---@param root string|nil
---@return boolean|nil new_state nil if not in a git repository
function M.toggle(root)
    if visible then
        visible = false
        auto_on = false
        setup_autocmds()
        clear_all()
        return false
    end
    root = root or current_root
    if not root then
        return nil
    end
    visible = true
    auto_on = false
    current_root = root
    base_cache = {}
    setup_autocmds()
    render_all()
    return true
end

return M
