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
      if repository ~= "" and p.path then repository = repository .. "/" .. p.path end

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

vim.api.nvim_create_user_command("OculusInvestigate", function(opts)
  if opts.args ~= "" and opts.args ~= "rust" and opts.args ~= "c-zig" then
    vim.notify("Oculus: choose rust or c-zig investigation analysis.", vim.log.levels.WARN)
    return
  end

  require("oculus").investigate(opts.args == "c-zig" and { analysis = "c_zig" } or nil)
end, {
  nargs = "?",
  complete = function(arglead)
    return vim.tbl_filter(function(value) return value:sub(1, #arglead) == arglead end, { "rust", "c-zig" })
  end,
  desc = "Investigate a local committed Rust or C/C++ to Zig relationship",
})

vim.api.nvim_create_user_command("OculusInvestigations", function()
  require("oculus").open_investigations()
end, { desc = "Browse durable project change investigations" })

vim.api.nvim_create_user_command("OculusWorkspace", function(opts)
  local workspace = require("oculus.workspace")
  local oculus = require("oculus")
  local arg = vim.trim(opts.args or "")

  if arg == "" then
    local active = workspace.get_active(oculus.config)
    local all = workspace.list(oculus.config)

    if #all == 0 then
      vim.notify("Oculus: No workspaces configured.", vim.log.levels.INFO)
      return
    end

    local lines = { "Oculus Workspaces:" }

    for _, ws in ipairs(all) do
      local is_active = active and (active.name:lower() == ws.name:lower())
      local mark = is_active and "* " or "  "
      local desc = (ws.description and ws.description ~= "") and (" - " .. ws.description) or ""
      local proj_count = #(ws.projects or {})
      local proj_str = string.format(" [%d project%s]", proj_count, proj_count == 1 and "" or "s")
      lines[#lines + 1] = string.format("%s%s%s%s%s", mark, ws.name, is_active and " (active)" or "", desc, proj_str)
    end

    vim.notify(table.concat(lines, "\n"), vim.log.levels.INFO)
    return
  end

  if arg:lower() == "none" or arg:lower() == "clear" then
    workspace.set_active(oculus.config, nil)
    vim.notify("Oculus: Active workspace cleared.", vim.log.levels.INFO)
    return
  end

  local ok, err_or_ws = workspace.set_active(oculus.config, arg)

  if ok then
    local count = #(err_or_ws.projects or {})
    vim.notify(string.format("Oculus: Active workspace set to '%s' (%d project%s).", err_or_ws.name, count, count == 1 and "" or "s"), vim.log.levels.INFO)
  else
    local all = workspace.list(oculus.config)
    local names = vim.tbl_map(function(w) return w.name end, all)
    local avail = #names > 0 and (" Available: " .. table.concat(names, ", ")) or " (No workspaces configured)"
    vim.notify(string.format("Oculus: %s.%s", err_or_ws, avail), vim.log.levels.WARN)
  end
end, {
  nargs = "?",
  desc = "View or switch the active Oculus project workspace",
  complete = function(arglead)
    local workspace = require("oculus.workspace")
    local config = require("oculus").config or {}
    local completions = { "clear", "none" }

    for _, ws in ipairs(workspace.list(config)) do
      completions[#completions + 1] = ws.name
    end

    local matches = {}

    for _, c in ipairs(completions) do
      if c:lower():sub(1, #arglead) == arglead:lower() then
        matches[#matches + 1] = c
      end
    end

    return matches
  end,
})

vim.api.nvim_create_user_command("OculusNexus", function()
  require("oculus").open_nexus()
end, { desc = "Manage local Nexus resources and experiment jobs" })

vim.api.nvim_create_user_command("OculusComposition", function(opts)
  require("oculus").open_composition(opts.args ~= "" and opts.args or nil)
end, { nargs = "?", complete = "file", desc = "Inspect, queue and reopen a linked Plexus composition" })

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

local function complete_projects(arglead)
  local matches = {}
  local config = require("oculus").config or {}
  local projects = config.projects

  if not projects or #projects == 0 then
    local win = package.loaded["oculus.window"]

    if win and win.state and win.state.opts and win.state.opts.projects then
      projects = win.state.opts.projects
    end
  end

  for _, p in ipairs(projects or {}) do
    local repository = type(p.repository) == "string" and p.repository or ""
    if repository ~= "" and p.path then repository = repository .. "/" .. p.path end

    if repository ~= "" and repository:lower():sub(1, #arglead) == arglead:lower() then
      matches[#matches + 1] = repository
    end

    if type(p.name) == "string" and p.name ~= "" and p.name:lower():sub(1, #arglead) == arglead:lower() then
      matches[#matches + 1] = p.name
    end
  end

  return matches
end

local function refresh_project_descriptions_cmd(opts)
  local target = vim.trim(opts.args or "")
  local oculus = require("oculus")

  local ok, err = oculus.refresh_project_descriptions(target ~= "" and target or nil, function(projects, updated)
    if target ~= "" then
      if #projects > 0 then
        vim.notify(string.format("Oculus: Refreshed project description for '%s'.", target), vim.log.levels.INFO)
      else
        vim.notify(string.format("Oculus: Project '%s' not found.", target), vim.log.levels.WARN)
      end
    else
      local count = type(projects) == "table" and #projects or 0

      if count == 0 then
        vim.notify("Oculus: No saved projects to refresh.", vim.log.levels.INFO)
      else
        vim.notify(string.format("Oculus: Refreshed descriptions for %d saved project%s.", count, count == 1 and "" or "s"), vim.log.levels.INFO)
      end
    end
  end)

  if ok == false and err then
    vim.notify("Oculus: " .. err, vim.log.levels.WARN)
  end
end

vim.api.nvim_create_user_command("OculusRefreshProjectDescriptions", refresh_project_descriptions_cmd, {
  nargs = "?",
  desc = "Refresh project description text of saved projects from GitHub or Codeberg",
  complete = complete_projects,
})

vim.api.nvim_create_user_command("OculusRefreshDescriptions", refresh_project_descriptions_cmd, {
  nargs = "?",
  desc = "Refresh project description text of saved projects (alias)",
  complete = complete_projects,
})

vim.api.nvim_create_user_command("OculusRefreshProjectDescription", refresh_project_descriptions_cmd, {
  nargs = "?",
  desc = "Refresh project description text of saved projects (alias)",
  complete = complete_projects,
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
  ["<Plug>(oculus-refresh-project-descriptions)"] = {
    desc = "Refresh project description text of saved projects",
    run = function()
      require("oculus").refresh_project_descriptions()
    end,
  },
  ["<Plug>(oculus-refresh-project-description)"] = {
    desc = "Refresh project description text of saved projects",
    run = function()
      require("oculus").refresh_project_descriptions()
    end,
  },
}) do
  vim.keymap.set("n", lhs, mapping.run, { silent = true, desc = mapping.desc })
end
