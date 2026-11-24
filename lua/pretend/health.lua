local M = {}

function M.check()
    local health = vim.health
    local pretend = require("pretend")

    health.start("git-pretend CLI")
    local cmd = pretend.config.cmd
    cmd = type(cmd) == "table" and vim.deepcopy(cmd) or { cmd }
    local ok, obj = pcall(vim.system, vim.list_extend(cmd, { "--version" }), { text = true })
    local res = ok and obj:wait()
    if res and res.code == 0 then
        health.ok(vim.trim(res.stdout))
    else
        health.error("Can't run " .. table.concat(cmd, " "), {
            "Install it: https://github.com/alex-k03/git-pretend#install",
            "or point `cmd` in setup() at the script",
        })
    end

    health.start("Optional")
    if pcall(require, "snacks") then
        health.ok("snacks.nvim: commit picker with two-commit ranges")
    else
        health.info("snacks.nvim not found: the picker falls back to vim.ui.select (one commit)")
    end
    if vim.fn.exists(":CodeDiff") == 2 then
        health.ok("codediff.nvim: opened when you start pretending")
    elseif vim.fn.exists(":DiffviewOpen") == 2 then
        health.ok("diffview.nvim: opened when you start pretending")
    else
        health.info("No diff view found (codediff.nvim or diffview.nvim); `open` does nothing by default")
    end
end

return M
