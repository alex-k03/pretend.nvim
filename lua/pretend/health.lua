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
        health.ok("snacks.nvim: commit picker with diff preview")
    else
        health.info("snacks.nvim not found: using built-in floating commit picker (<Tab> two commits for a range)")
    end
    local view = vim.fn.exists(":CodeDiff") == 2 and "codediff.nvim"
        or vim.fn.exists(":DiffviewOpen") == 2 and "diffview.nvim"
    local open, close = pretend.config.open, pretend.config.close
    if view then
        health.ok(("%s found: `open` %s, `close` %s"):format(view,
            open == "auto" and "opens it on start" or open and "is a function" or "is off",
            close == "auto" and "closes it on stop" or close and "is a function" or "is off"))
    elseif open == "auto" or close == "auto" then
        health.warn("`open` or `close` is \"auto\", but neither codediff.nvim nor diffview.nvim is installed")
    else
        health.info("No diff view plugin found (codediff.nvim or diffview.nvim); `open` and `close` are off")
    end
end

return M
