if vim.g.loaded_oculus then
  return
end

vim.g.loaded_oculus = true

vim.api.nvim_create_user_command("OculusOpen", function(opts)
  if opts.args == "" then
    require("oculus").open()
    return
  end

  -- "@login" or "@codeberg:login" opens a user's feed ("@me" is the signed-in
  -- account); anything else is a project.
  local user = opts.args:match("^@(.+)$")
  local ok, err

  if user then
    ok, err = require("oculus").open_user(user)
  else
    ok, err = require("oculus").open_project(opts.args)
  end

  if not ok then
    vim.notify("Oculus: " .. err, vim.log.levels.ERROR)
  end
end, {
  nargs = "?",
  desc = "Open Oculus, optionally on a project's or @user's activity feed",
  complete = function(arglead)
    local matches = {}

    for _, p in ipairs((require("oculus").config or {}).projects or {}) do
      local repository = type(p.repository) == "string" and p.repository or ""

      if repository ~= "" and repository:lower():sub(1, #arglead) == arglead:lower() then
        matches[#matches + 1] = repository
      end
    end

    return matches
  end,
})

vim.api.nvim_create_user_command("OculusWork", function()
  require("oculus").open_work()
end, { desc = "Open Oculus on your review requests, pull requests, assignments and mentions" })

vim.api.nvim_create_user_command("OculusPlexus", function(opts)
  require("oculus").open_plexus(opts.args ~= "" and opts.args or nil)
end, { nargs = "?", complete = "file", desc = "Explore a Plexus hypothesis and run its experiments" })

vim.api.nvim_create_user_command("OculusCapabilities", function(opts)
  require("oculus").open_capabilities(opts.args)
end, { nargs = 1, complete = "file", desc = "Discover Rust capability opportunities beside source" })

vim.api.nvim_create_user_command("OculusInvestigate", function()
  require("oculus").investigate()
end, { desc = "Investigate a local committed change and its consumer opportunities" })

vim.api.nvim_create_user_command("OculusInvestigations", function()
  require("oculus").open_investigations()
end, { desc = "Browse durable project change investigations" })

vim.api.nvim_create_user_command("OculusNexus", function()
  require("oculus").open_nexus()
end, { desc = "Manage local Nexus resources and experiment jobs" })

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

-- <Plug> mappings, so a keymap can be bound without going through setup().
for lhs, mapping in pairs({
  ["<Plug>(oculus-toggle)"] = {
    desc = "Toggle Oculus",
    run = function()
      require("oculus").toggle()
    end,
  },
  ["<Plug>(oculus-open)"] = {
    desc = "Open Oculus",
    run = function()
      require("oculus").open()
    end,
  },
  ["<Plug>(oculus-close)"] = {
    desc = "Close Oculus",
    run = function()
      require("oculus").close()
    end,
  },
  ["<Plug>(oculus-work)"] = {
    desc = "Open Oculus on your work",
    run = function()
      require("oculus").open_work()
    end,
  },
  ["<Plug>(oculus-inspect)"] = {
    desc = "Inspect an issue, pull request or commit",
    run = function()
      require("oculus").inspect()
    end,
  },
}) do
  vim.keymap.set("n", lhs, mapping.run, { silent = true, desc = mapping.desc })
end
