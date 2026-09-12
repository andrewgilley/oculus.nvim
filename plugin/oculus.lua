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

vim.api.nvim_create_user_command("OculusRename", function(opts)
  require("oculus.window").rename(opts.args ~= "" and opts.args or nil)
end, { nargs = "?", desc = "Rename the selected Oculus group or item display name" })

vim.api.nvim_create_user_command("OculusReloadTracking", function()
  local ok, err = require("oculus").reload_tracking()

  if not ok and not require("oculus").config.tracking_file then
    vim.notify(err, vim.log.levels.ERROR)
  end
end, { desc = "Reload the Oculus tracking JSON file" })

local function complete_target(arglead)
  local config = require("oculus").config or {}
  local projects = config.projects or {}
  local completions = { "pr ", "issue ", "commit " }

  for _, p in ipairs(projects) do
    if type(p.repository) == "string" and p.repository ~= "" then
      completions[#completions + 1] = p.repository .. "#"
    end

    if type(p.name) == "string" and p.name ~= "" then
      completions[#completions + 1] = p.name:lower() .. "#"
    end
  end

  local matches = {}

  for _, c in ipairs(completions) do
    if c:lower():sub(1, #arglead) == arglead:lower() then
      matches[#matches + 1] = c
    end
  end

  return matches
end

vim.api.nvim_create_user_command("OculusInspect", function(opts)
  local target = opts.args ~= "" and opts.args or nil
  require("oculus").inspect(target)
end, {
  nargs = "?",
  desc = "Inspect an issue, pull request, or commit",
  complete = complete_target,
})

vim.api.nvim_create_user_command("OculusInvestigate", function(opts)
  local target = opts.args ~= "" and opts.args or nil
  require("oculus").investigate(target)
end, {
  nargs = "?",
  desc = "Investigate an issue, pull request, commit, or project architecture",
  complete = complete_target,
})

vim.api.nvim_create_user_command("OculusBuildEngine", function()
  require("oculus.investigate.engine").build()
end, {
  desc = "Build the oculus-engine Rust binary with cargo",
})

vim.api.nvim_create_user_command("OculusAddDirectory", function(opts)
  local name = opts.args ~= "" and opts.args or nil

  if not name then
    require("oculus.window").prompt_create_directory()
  else
    require("oculus").create_project_directory(name)
  end
end, {
  nargs = "?",
  desc = "Create a parent directory for projects in Oculus",
})

vim.api.nvim_create_user_command("OculusMoveToDirectory", function(opts)
  local args = vim.split(vim.trim(opts.args or ""), "%s+")

  if #args == 0 or args[1] == "" then
    require("oculus.window").prompt_move_project_to_directory()
  elseif #args == 1 then
    require("oculus.window").move_project_to_directory(nil, args[1])
  else
    require("oculus.window").move_project_to_directory(args[1], args[2])
  end
end, {
  nargs = "*",
  desc = "Move a project to a directory in Oculus",
})
