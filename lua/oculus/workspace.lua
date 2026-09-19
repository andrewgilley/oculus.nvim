local M = {}

-- Normalizes an individual workspace entry.
-- Accepts either `{ name = "...", description = "...", projects = { ... } }`
-- or a project list `{ "repo1", "repo2" }` with a fallback name.
function M.normalize_entry(raw, fallback_name)
  if type(raw) ~= "table" then
    return nil
  end

  local name = raw.name
  if type(name) ~= "string" or vim.trim(name) == "" then
    name = fallback_name
  end
  if type(name) ~= "string" or vim.trim(name) == "" then
    return nil
  end
  name = vim.trim(name)

  local description = ""
  if type(raw.description) == "string" then
    description = vim.trim(raw.description)
  end

  local raw_projects = raw.projects
  if raw_projects == nil and vim.islist(raw) then
    raw_projects = raw
  end

  local projects = {}
  if type(raw_projects) == "table" then
    for _, item in ipairs(raw_projects) do
      if type(item) == "string" and vim.trim(item) ~= "" then
        projects[#projects + 1] = vim.trim(item)
      elseif type(item) == "table" and type(item.repository) == "string" and vim.trim(item.repository) ~= "" then
        local repo = vim.trim(item.repository)
        if item.provider and type(item.provider) == "string" and vim.trim(item.provider) ~= "" then
          projects[#projects + 1] = vim.trim(item.provider) .. ":" .. repo
        else
          projects[#projects + 1] = repo
        end
      end
    end
  end

  return {
    name = name,
    description = description,
    projects = projects,
  }
end

-- Returns an array of normalized workspaces configured in `config.workspaces`.
function M.list(config)
  config = config or {}
  local raw_workspaces = config.workspaces
  if type(raw_workspaces) ~= "table" then
    return {}
  end

  local result = {}
  if vim.islist(raw_workspaces) then
    for _, item in ipairs(raw_workspaces) do
      local ws = M.normalize_entry(item)
      if ws then
        result[#result + 1] = ws
      end
    end
  else
    local keys = vim.tbl_keys(raw_workspaces)
    table.sort(keys)
    for _, key in ipairs(keys) do
      local ws = M.normalize_entry(raw_workspaces[key], tostring(key))
      if ws then
        result[#result + 1] = ws
      end
    end
  end

  return result
end

-- Finds a workspace by name (case-insensitive).
function M.find(config, name)
  if type(name) ~= "string" or vim.trim(name) == "" then
    return nil
  end

  local target = vim.trim(name):lower()
  for _, ws in ipairs(M.list(config)) do
    if ws.name:lower() == target then
      return ws
    end
  end

  return nil
end

-- Gets the active workspace table, or nil if no workspace is active or found.
function M.get_active(config)
  config = config or {}
  if type(config.active_workspace) ~= "string" or vim.trim(config.active_workspace) == "" then
    return nil
  end

  return M.find(config, config.active_workspace)
end

-- Sets the active workspace by name. Passing nil, empty string, "none", or "clear"
-- deactivates the workspace.
function M.set_active(config, name)
  config = config or {}

  if
    name == nil
    or type(name) ~= "string"
    or vim.trim(name) == ""
    or vim.trim(name):lower() == "none"
    or vim.trim(name):lower() == "clear"
  then
    config.active_workspace = nil
    if config.persist_projects and config.state_file then
      pcall(require("oculus.storage").save, config.state_file, config)
    end
    return true, nil
  end

  local ws = M.find(config, name)
  if not ws then
    return false, "Workspace '" .. name .. "' not found"
  end

  config.active_workspace = ws.name
  if config.persist_projects and config.state_file then
    pcall(require("oculus.storage").save, config.state_file, config)
  end
  return true, ws
end

-- Adds or replaces a workspace definition in `config.workspaces`.
function M.add(config, name, def)
  config = config or {}
  if type(name) ~= "string" or vim.trim(name) == "" then
    return nil, "Workspace name must be a nonempty string"
  end
  name = vim.trim(name)

  config.workspaces = config.workspaces or {}
  local normalized = M.normalize_entry(def or {}, name)
  if not normalized then
    return nil, "Invalid workspace definition"
  end

  if vim.islist(config.workspaces) then
    local replaced = false
    for i, item in ipairs(config.workspaces) do
      local existing_name = type(item) == "table" and item.name
      if existing_name and existing_name:lower() == name:lower() then
        config.workspaces[i] = normalized
        replaced = true
        break
      end
    end
    if not replaced then
      config.workspaces[#config.workspaces + 1] = normalized
    end
  else
    config.workspaces[name] = normalized
  end

  if config.persist_projects and config.state_file then
    pcall(require("oculus.storage").save, config.state_file, config)
  end

  return normalized
end

-- Removes a workspace by name from `config.workspaces`.
function M.remove(config, name)
  config = config or {}
  if type(name) ~= "string" or vim.trim(name) == "" then
    return false
  end
  local target = vim.trim(name):lower()

  local removed = false
  if vim.islist(config.workspaces) then
    local new_list = {}
    for _, item in ipairs(config.workspaces) do
      local item_name = type(item) == "table" and item.name
      if item_name and item_name:lower() == target then
        removed = true
      else
        new_list[#new_list + 1] = item
      end
    end
    config.workspaces = new_list
  elseif type(config.workspaces) == "table" then
    for k, _ in pairs(config.workspaces) do
      if tostring(k):lower() == target then
        config.workspaces[k] = nil
        removed = true
      end
    end
  end

  if config.active_workspace and config.active_workspace:lower() == target then
    config.active_workspace = nil
  end

  if removed and config.persist_projects and config.state_file then
    pcall(require("oculus.storage").save, config.state_file, config)
  end

  return removed
end

-- Checks if a project matches a pattern defined in a workspace.
function M.project_matches(project, pattern)
  if type(project) ~= "table" then
    return false
  end

  if type(pattern) == "table" then
    if type(pattern.repository) == "string" then
      pattern = pattern.repository
    else
      return false
    end
  end

  if type(pattern) ~= "string" or vim.trim(pattern) == "" then
    return false
  end

  local pat = vim.trim(pattern):lower()
  local repo = type(project.repository) == "string" and project.repository:lower() or ""
  local name = type(project.name) == "string" and project.name:lower() or ""
  local provider = type(project.provider) == "string" and project.provider:lower() or "github"
  local provider_repo = provider .. ":" .. repo

  if pat == repo or pat == name or pat == provider_repo then
    return true
  end

  local pat_provider, pat_repo = pat:match("^([%w_]+):(.+)$")
  if pat_provider and pat_repo then
    if pat_provider == provider and pat_repo == repo then
      return true
    end
  end

  return false
end

-- Checks if a project matches a workspace definition.
-- If ws is nil or has no projects configured, returns true.
function M.matches_workspace(project, ws)
  if not ws then
    return true
  end
  if not ws.projects or #ws.projects == 0 then
    return true
  end
  for _, pattern in ipairs(ws.projects) do
    if M.project_matches(project, pattern) then
      return true
    end
  end
  return false
end

-- Filters a project list to only those belonging to the active workspace.
-- If no workspace is active (or active workspace has no projects configured),
-- returns the unfiltered list.
function M.filter_projects(config, projects)
  config = config or {}
  projects = projects or config.projects or {}

  local active = M.get_active(config)
  if not active or not active.projects or #active.projects == 0 then
    return projects
  end

  local filtered = {}
  for _, project in ipairs(projects) do
    if M.matches_workspace(project, active) then
      filtered[#filtered + 1] = project
    end
  end

  return filtered
end

-- Returns the active workspace's projects from `config.projects`.
function M.get_active_projects(config)
  return M.filter_projects(config, config.projects or {})
end

return M
