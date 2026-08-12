local M = {}

local default_inspect_search_paths = {}
local default_inspect_sidebar_width = 28 / math.max(1, vim.o.columns)
if vim.env.USERPROFILE and vim.env.USERPROFILE ~= "" then
  default_inspect_search_paths[1] = vim.fs.joinpath(
    vim.env.USERPROFILE,
    "Desktop",
    "Dev",
    "code",
    "source"
  )
end

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
  activity_search_max_pages = 5,
  activity_types = nil,
  user_activity_types = {},
  project_activity_types = {
    "push",
    "merged_pull_request",
    "assigned_issue",
  },
  project_issue_filters = {},
  projects = {
    {
      name = "Neovim",
      repository = "neovim/neovim",
      provider = "github",
      description = "Vim-fork focused on extensibility and usability.",
    },
    {
      name = "Ghostty",
      repository = "ghostty-org/ghostty",
      provider = "github",
      description = "Ghostty is a fast, feature-rich, and cross-platform terminal emulator that uses platform-native UI and GPU acceleration.",
    },
    {
      name = "Zig",
      repository = "ziglang/zig",
      provider = "codeberg",
      description = "A general-purpose programming language and toolchain for maintaining robust, optimal, and reusable software.",
    },
    {
      name = "Fil-C",
      repository = "pizlonator/fil-c",
      provider = "github",
      description = "Fil-C provides completely compatible memory safety for C and C++.",
    },
    {
      name = "WebAssembly Component Model",
      repository = "WebAssembly/component-model",
      provider = "github",
      description = "Repository for design and specification of the Component Model.",
    },
    {
      name = "Wasmtime",
      repository = "bytecodealliance/wasmtime",
      provider = "github",
      description = "A fast and secure runtime for WebAssembly.",
    },
    {
      name = "lazy.nvim",
      repository = "folke/lazy.nvim",
      provider = "github",
      description = "A modern plugin manager for Neovim.",
    },
    {
      name = "oculus.nvim",
      repository = "andrewgilley/oculus.nvim",
      provider = "github",
      description = "Neovim browser for public GitHub activity of community members.",
    },
    {
      name = "Zug",
      repository = "andrewgilley/zug",
      provider = "github",
      description = "WebAssembly runtime.",
    },
    {
      name = "Odin",
      repository = "odin-lang/Odin",
      provider = "github",
      description = "The data-oriented language for sane software development.",
    },
    {
      name = "Stockfish",
      repository = "official-stockfish/Stockfish",
      provider = "github",
      description = "A free and strong UCI chess engine.",
    },
  },
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
  inspect_sidebar_toggle = "<leader>oi",
  inspect_sidebar_width = default_inspect_sidebar_width,
  inspect_overview_toggle = "<leader>op",
  inspect_old_version = "<C-s>",
  inspect_new_version = "<C-d>",
  inspect_next_chunk = "<C-Tab>",
  inspect_previous_chunk = "<S-Tab>",
  telemetry = {
    enabled = false,
    endpoint = nil,
    headers = {},
    service_name = "oculus.nvim",
    service_version = "0.1.0",
    environment = "dev",
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

  contributors = {
    {
      name = "Luke Wagner",
      username = "lukewagner",
      provider = "github",
    },
    {
      name = "Alex Crichton",
      username = "alexcrichton",
      provider = "github",
    },
    {
      name = "folke",
      username = "folke",
      provider = "github",
    },
    {
      name = "Andrew Gilley",
      username = "andrewgilley",
      provider = "github",
    },
    {
      name = "Bill Hall",
      username = "gingerBill",
      provider = "github",
    },
    {
      name = "vondele",
      username = "vondele",
      provider = "github",
    },
  },
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
  local result = vim.deepcopy(configured or {})
  local present = {}
  for _, contributor in ipairs(result) do
    local key = contributor_key(contributor)
    if key then
      present[key] = true
    end
  end
  for _, contributor in ipairs(saved or {}) do
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
end

local function merge_projects(configured, saved)
  local result = vim.deepcopy(configured or {})
  local present = {}
  for _, project in ipairs(result) do
    local key = project_key(project)
    if key then
      present[key] = true
    end
  end
  for _, project in ipairs(saved or {}) do
    local key = project_key(project)
    if key and not present[key] then
      result[#result + 1] = vim.deepcopy(project)
      present[key] = true
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
    end
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

return M
