if vim.g.loaded_pantheon then
  return
end

vim.g.loaded_pantheon = true

vim.api.nvim_create_user_command("PantheonOpen", function()
  require("pantheon").open()
end, { desc = "Open Pantheon" })

vim.api.nvim_create_user_command("PantheonClose", function()
  require("pantheon").close()
end, { desc = "Close Pantheon" })

vim.api.nvim_create_user_command("PantheonToggle", function()
  require("pantheon").toggle()
end, { desc = "Toggle Pantheon" })
