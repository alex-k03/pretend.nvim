if vim.g.loaded_pretend then
    return
end
vim.g.loaded_pretend = true

vim.api.nvim_create_user_command("Pretend", function(cmd) require("pretend").command(cmd.fargs) end, {
    nargs = "*",
    complete = function(arg_lead, cmd_line) return require("pretend").complete(arg_lead, cmd_line) end,
    desc = "git-pretend: review commits as uncommitted changes",
})
