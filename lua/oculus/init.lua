local M = {}
local default_inspect_search_paths = {}
local default_inspect_sidebar_width = 28 / math.max(1, vim.o.columns)

local defaults = {
  width = 0.90,
  height = 0.80,
  row = 1,
  border = "rounded",
  per_page = 30,
  results_limit = 8,
  contributor_list_limit = 20,
  push_detail_limit = 10,
  cache_ttl = 300,
  request_timeout = 15,
  activity_types = nil,
  user_activity_types = {},
  project_activity_types = {
    "push",
    "merged_pull_request",
    "assigned_issue",
  },
  project_issue_filters = {},
  search_history = {},
  sidebar = false,
  sidebar_width = 26,
  navigation = {
    up = "k",
    down = "j",
    left = "h",
    right = "l",
    inspect = "i",
    inspect_id = "I",
  },
  project_directories = {},
  project_order = {},
  projects = {},
  workspaces = {},
  active_workspace = nil,
  project_descriptions = {},
  -- Devlog feed URLs by repository ("owner/repo" or "codeberg:owner/repo"),
  -- and blog feed URLs by user ("@login" or "codeberg:@login"), or false to
  -- turn one off. See "Devlogs".
  devlogs = {},
  devlog_feeds = {},
  persist_filters = true,
  persist_contributors = true,
  persist_projects = true,
  removed_contributors = {},
  removed_projects = {},
  persist_inspect_overviews = true,
  inspect_overviews = {},
  state_file = vim.fn.stdpath("state") .. "/oculus.json",
  browser_command = nil,
  inspect_cache_ttl = 60,
  inspect_repositories = {},
  inspect_search_paths = default_inspect_search_paths,
  inspect_discovery_roots = { vim.uv.os_homedir() },
  inspect_remote_context = 20,
  inspect_remote_cache = vim.fs.joinpath(
    vim.fn.stdpath("cache"),
    "oculus",
    "remote"
  ),
  inspect_sidebar_toggle = "<leader>oi",
  inspect_sidebar_width = default_inspect_sidebar_width,
  inspect_overview_toggle = "<leader>op",
  inspect_old_version = "<C-s>",
  inspect_new_version = "<C-d>",
  inspect_next_chunk = "<C-Tab>",
  inspect_previous_chunk = "<S-Tab>",
  inspect_next_thread = "]r",
  inspect_previous_thread = "[r",
  inspect_thread = "<leader>oc",
  inspect_chunk_threads = "<C-r>",
  inspect_treesitter_context = true,
  inspect_treesitter_context_multiwindow = true,
  inspect_treesitter_context_mode = "topline",
  -- A per-filetype colorscheme plugin to colour inspected buffers with and to
  -- pause while Oculus opens its own windows; nil detects reliquary.nvim,
  -- false turns it off. See "Per-filetype colorschemes" in :h oculus-usage.
  inspect_colorscheme = nil,
  telemetry = {
    enabled = false,
    endpoint = nil,
    headers = {},
    service_name = "oculus.nvim",
    -- service_version defaults to the plugin's version, and the deployment
    -- environment is only reported when you set one.
    service_version = nil,
    environment = nil,
    resource_attributes = {},
    timeout = 5,
    exporter = nil,
    on_error = nil,
  },
  opinion = {
    provider = nil,
    width = 0.64,
    height = 0.70,
    border = "rounded",
    title = " Oculus opinion ",
    filetype = "markdown",
  },
  token = nil,
  gh_token_fallback = true,
  contributors = {},
}

M.config = vim.deepcopy(defaults)

local function contributor_key(contributor)
  if type(contributor) ~= "table" or not contributor.username then
    return nil
  end

  return ("%s:%s"):format(
    contributor.provider == "codeberg" and "codeberg" or "github",
    contributor.username:lower()
  )
end

local function merge_contributors(configured, saved)
  if not saved or #saved == 0 then
    return vim.deepcopy(configured or {})
  end

  local configured_map = {}

  for _, contributor in ipairs(configured or {}) do
    local key = contributor_key(contributor)

    if key then
      configured_map[key] = contributor
    end
  end

  local result = {}
  local present = {}

  for _, contributor in ipairs(saved) do
    local key = contributor_key(contributor)

    if key and not present[key] then
      local cfg = configured_map[key]
      local merged

      if cfg then
        merged = vim.tbl_deep_extend(
          "force",
          vim.deepcopy(cfg),
          vim.deepcopy(contributor)
        )
      else
        merged = vim.deepcopy(contributor)
      end

      result[#result + 1] = merged
      present[key] = true
    end
  end

  for _, contributor in ipairs(configured or {}) do
    local key = contributor_key(contributor)

    if key and not present[key] then
      result[#result + 1] = vim.deepcopy(contributor)
      present[key] = true
    end
  end

  return result
end

local function project_key(project)
  if type(project) ~= "table" or not project.repository then
    return nil
  end

  return (project.provider == "codeberg" and "codeberg" or "github")
    .. ":"
    .. project.repository:lower()
    .. (project.path and ("/" .. project.path:lower()) or "")
end

local function merge_projects(configured, saved)
  if not saved or #saved == 0 then
    return vim.deepcopy(configured or {})
  end

  local configured_map = {}

  for _, project in ipairs(configured or {}) do
    local key = project_key(project)

    if key then
      configured_map[key] = project
    end
  end

  local result = {}
  local present = {}

  for _, project in ipairs(saved) do
    local key = project_key(project)

    if key and not present[key] then
      local cfg = configured_map[key]
      local merged

      if cfg then
        merged = vim.tbl_deep_extend("force", vim.deepcopy(cfg), vim.deepcopy(project))

        if project.directory == nil or project.directory == vim.NIL then
          merged.directory = nil
        else
          merged.directory = project.directory
        end

        if cfg.description and cfg.description ~= "" then
          merged.description = cfg.description
        elseif project.description and project.description ~= "" then
          merged.description = project.description
        end
      else
        merged = vim.deepcopy(project)
      end

      result[#result + 1] = merged
      present[key] = true
    end
  end

  for _, project in ipairs(configured or {}) do
    local key = project_key(project)

    if key and not present[key] then
      result[#result + 1] = vim.deepcopy(project)
      present[key] = true
    end
  end

  return result
end

local function merge_project_directories(configured, saved)
  local result = vim.deepcopy(configured or {})
  local seen = {}

  for _, d in ipairs(result) do
    if type(d) == "string" and d ~= "" then
      seen[d:lower()] = true
    end
  end

  for _, d in ipairs(saved or {}) do
    if type(d) == "string" and d ~= "" and not seen[d:lower()] then
      result[#result + 1] = d
      seen[d:lower()] = true
    end
  end

  return result
end

local function without_removed(items, removed, key_fn)
  local removed_set = {}

  for _, key in ipairs(removed or {}) do
    if type(key) == "string" then
      removed_set[key:lower()] = true
    end
  end

  local result = {}

  for _, item in ipairs(items or {}) do
    local key = key_fn(item)

    if not key or not removed_set[key:lower()] then
      result[#result + 1] = item
    end
  end

  return result
end

function M.setup(opts)
  opts = opts or {}
  M.config = vim.tbl_deep_extend("force", vim.deepcopy(defaults), opts)

  if opts.contributors ~= nil then
    M.config.contributors = vim.deepcopy(opts.contributors)
  end

  if opts.projects ~= nil then
    M.config.projects = vim.deepcopy(opts.projects)
  end

  if opts.project_directories ~= nil then
    M.config.project_directories = vim.deepcopy(opts.project_directories)
  end

  if opts.project_order ~= nil then
    M.config.project_order = vim.deepcopy(opts.project_order)
  end

  if opts.workspaces ~= nil then
    M.config.workspaces = vim.deepcopy(opts.workspaces)
  end

  if opts.active_workspace ~= nil then
    M.config.active_workspace = opts.active_workspace
  end

  if M.config.persist_filters
    or M.config.persist_contributors
    or M.config.persist_projects
    or M.config.persist_inspect_overviews
  then
    local saved = require("oculus.storage").load(M.config.state_file)

    if saved then
      if type(saved.removed_contributors) == "table" then
        M.config.removed_contributors = vim.deepcopy(
          saved.removed_contributors
        )
      end

      if type(saved.removed_projects) == "table" then
        M.config.removed_projects = vim.deepcopy(saved.removed_projects)
      end

      if M.config.persist_filters then
        if saved.activity_types ~= nil then
          M.config.activity_types = saved.activity_types
        end

        if type(saved.user_activity_types) == "table" then
          M.config.user_activity_types = saved.user_activity_types
        end

        if type(saved.project_activity_types) == "table" then
          M.config.project_activity_types = saved.project_activity_types
        end

        if type(saved.project_issue_filters) == "table" then
          M.config.project_issue_filters = saved.project_issue_filters
        end
      end

      if
        M.config.persist_contributors
        and type(saved.contributors) == "table"
      then
        M.config.contributors = merge_contributors(
          M.config.contributors,
          saved.contributors
        )
      end

      if M.config.persist_projects and type(saved.projects) == "table" then
        M.config.projects = merge_projects(
          M.config.projects,
          saved.projects
        )
      end

      if M.config.persist_projects and type(saved.project_directories) == "table" then
        M.config.project_directories = merge_project_directories(
          M.config.project_directories,
          saved.project_directories
        )
      end

      if M.config.persist_projects and opts.project_order == nil and type(saved.project_order) == "table" then
        M.config.project_order = vim.deepcopy(saved.project_order)
      end

      if M.config.persist_contributors then
        M.config.contributors = without_removed(
          M.config.contributors,
          M.config.removed_contributors,
          contributor_key
        )
      end

      if M.config.persist_projects then
        M.config.projects = without_removed(
          M.config.projects,
          M.config.removed_projects,
          project_key
        )
      end

      if M.config.persist_inspect_overviews
        and type(saved.inspect_overviews) == "table"
      then
        M.config.inspect_overviews = vim.deepcopy(saved.inspect_overviews)
      end

      if type(saved.project_descriptions) == "table" then
        M.config.project_descriptions = vim.deepcopy(
          saved.project_descriptions
        )
      end

      if type(saved.search_history) == "table" then
        M.config.search_history = vim.deepcopy(saved.search_history)
      end

      if type(saved.devlog_feeds) == "table" then
        M.config.devlog_feeds = vim.deepcopy(saved.devlog_feeds)
      end

      if opts.workspaces == nil and type(saved.workspaces) == "table" then
        M.config.workspaces = vim.deepcopy(saved.workspaces)
      end

      if opts.active_workspace == nil and saved.active_workspace ~= nil then
        M.config.active_workspace = saved.active_workspace
      end
    end
  end

  -- Saved items always load, whatever the persist_* options, so later state
  -- writes never replace the list on disk with a partial one.
  require("oculus.saved").load(
    (require("oculus.storage").load(M.config.state_file) or {}).saved_items
  )

  if M.config.tracking_file then
    local ok, err = require("oculus.tracking").load(M.config)
    if not ok then vim.notify(err, vim.log.levels.ERROR) end
    local window = require("oculus.window")
    window.state.opts = M.config
    window.state.tracking_paths = nil
    window.state.tracking_move = nil
  else
    M.load_project_descriptions(M.config)
  end
end

function M.reload_tracking()
  if not M.config.tracking_file then
    return nil, "No tracking_file configured"
  end

  local ok, err = require("oculus.tracking").load(M.config)
  local window = require("oculus.window")

  if ok then
    window.state.tracking_paths = nil
    window.state.tracking_move = nil
    window.state.request_id = (window.state.request_id or 0) + 1
    window.state.opts = M.config
  else
    vim.notify(err, vim.log.levels.ERROR)
  end

  window.refresh_tracking()
  return ok, err
end

function M.load_project_descriptions(config, callback)
  config = config or M.config or defaults
  local projects = config.projects or {}
  local github = require("oculus.github")
  local codeberg = require("oculus.codeberg")
  local pending = 0
  local updated_any = false

  for _, project in ipairs(projects) do
    if
      type(project) == "table"
      and type(project.repository) == "string"
      and project.repository ~= ""
      and (config.force or not project.description or project.description == "")
    then
      local provider = project.provider == "codeberg" and codeberg or github

      if provider and type(provider.repository_info) == "function" then
        pending = pending + 1

        provider.repository_info(project.repository, config, function(info)
          pending = pending - 1

          if
            info
            and type(info.description) == "string"
            and info.description ~= ""
          then
            if project.description ~= info.description then
              project.description = info.description
              updated_any = true
            end
          end

          if pending == 0 then
            if updated_any and config.persist_projects and config.state_file then
              pcall(require("oculus.storage").save, config.state_file, config)
            end

            if callback then
              callback(projects)
            end
          end
        end)
      end
    end
  end

  if pending == 0 and callback then
    callback(projects)
  end
end

function M.open()
  require("oculus.window").open(M.config)
end

function M.close()
  require("oculus.window").close()
end

function M.toggle()
  require("oculus.window").toggle(M.config)
end

function M.open_project(target)
  return require("oculus.window").open_project(target, M.config)
end

function M.open_user(target)
  return require("oculus.window").open_user(target, M.config)
end

function M.open_devlog(target)
  return require("oculus.window").open_devlog(target, M.config)
end

function M.open_work()
  return require("oculus.window").open_work(M.config)
end

-- Look up the account signed in on "github" (the default) or "codeberg".
-- `callback(viewer, err)` gets { provider, login, name?, html_url?, avatar_url? }.
function M.viewer(provider, callback)
  if type(provider) == "function" then
    provider, callback = nil, provider
  end

  require("oculus.auth").viewer(provider or "github", M.config, callback)
end

function M.inspect(target, opts, context, callback, lifecycle)
  local inspect = require("oculus.inspect")

  local effective_opts = vim.tbl_deep_extend(
    "force",
    vim.deepcopy(M.config or {}),
    opts or {}
  )

  return inspect.inspect_by_id(
    target,
    effective_opts,
    context,
    callback,
    lifecycle
  )
end

function M.consult(request)
  return require("oculus.opinion").consult(request, M.config.opinion)
end

function M.show_opinion(value, opts)
  return require("oculus.opinion").show(
    value,
    vim.tbl_deep_extend(
      "force",
      vim.deepcopy(M.config.opinion),
      opts or {}
    )
  )
end

function M.create_project_directory(name)
  return require("oculus.window").create_project_directory(name)
end

function M.remove_project_directory(name)
  return require("oculus.window").remove_project_directory(name)
end

function M.move_project_to_directory(project, dir_name)
  return require("oculus.window").move_project_to_directory(project, dir_name)
end

function M.move_to_parent_directory(project)
  return require("oculus.window").move_to_parent_directory(project)
end

function M.open_project_directory(name)
  return require("oculus.window").open_project_directory(name)
end

function M.set_workspace(name)
  return require("oculus.workspace").set_active(M.config, name)
end

function M.get_workspace()
  return require("oculus.workspace").get_active(M.config)
end

function M.workspaces()
  return require("oculus.workspace").list(M.config)
end

function M.add_workspace(name, def)
  return require("oculus.workspace").add(M.config, name, def)
end

function M.remove_workspace(name)
  return require("oculus.workspace").remove(M.config, name)
end

function M.filter_projects(projects)
  return require("oculus.workspace").filter_projects(M.config, projects)
end

function M.toggle_workspace_filter()
  return require("oculus.window").toggle_workspace_filter()
end

function M.prompt_select_workspace()
  return require("oculus.window").prompt_select_workspace()
end

function M.refresh_project_descriptions(target, callback)
  return require("oculus.window").refresh_project_descriptions(target, callback)
end

function M.reset_to_initial_page()
  return require("oculus.window").reset_to_initial_page()
end

return M
