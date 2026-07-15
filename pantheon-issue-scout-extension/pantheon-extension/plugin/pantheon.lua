if vim.g.loaded_pantheon then
  return
end

vim.g.loaded_pantheon = true

vim.api.nvim_create_user_command("PantheonOpen", function()
  require("pantheon").open()
end, { desc = "Open Pantheon" })

vim.api.nvim_create_user_command("PantheonClose", function()
  require("pantheon").close()
  require("pantheon.issues").close()
end, { desc = "Close Pantheon" })

vim.api.nvim_create_user_command("PantheonToggle", function()
  require("pantheon").toggle()
end, { desc = "Toggle Pantheon" })

vim.api.nvim_create_user_command("PantheonIssues", function(command)
  require("pantheon.issues").open(
    require("pantheon").config,
    command.args,
    command.bang
  )
end, {
  nargs = "*",
  bang = true,
  desc = "Find high-signal GitHub issues",
})
