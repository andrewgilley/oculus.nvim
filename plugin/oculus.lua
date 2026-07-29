if vim.g.loaded_oculus then
  return
end

vim.g.loaded_oculus = true

vim.api.nvim_create_user_command("OculusOpen", function()
  require("oculus").open()
end, { desc = "Open Oculus" })

vim.api.nvim_create_user_command("OculusClose", function()
  require("oculus").close()
end, { desc = "Close Oculus" })

vim.api.nvim_create_user_command("OculusToggle", function()
  require("oculus").toggle()
end, { desc = "Toggle Oculus" })
