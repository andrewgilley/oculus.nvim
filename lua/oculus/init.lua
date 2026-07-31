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
  activity_types = nil,
  user_activity_types = {},
  project_activity_types = {
    "push",
    "merged_pull_request",
    "assigned_issue",
  },
  projects = {
    {
      name = "Neovim",
      repository = "neovim/neovim",
      provider = "github",
    },
  },
  persist_filters = true,
  persist_contributors = true,
  state_file = vim.fn.stdpath("state") .. "/oculus.json",
  browser_command = nil,
  inspect_cache_ttl = 60,
  inspect_repositories = {},
  inspect_search_paths = default_inspect_search_paths,
  inspect_sidebar_toggle = "<leader>oi",
  inspect_sidebar_width = default_inspect_sidebar_width,
  inspect_overview_toggle = "<leader>ow",
  inspect_version_switch = "<C-s>",
  inspect_next_chunk = "<Tab>",
  inspect_previous_chunk = "<S-Tab>",
  opinion = {
    provider = nil,
    width = 0.64,
    height = 0.70,
    border = "rounded",
    title = " Oculus opinion ",
    filetype = "markdown",
  },
  token = nil,

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

function M.setup(opts)
  opts = opts or {}
  M.config = vim.tbl_deep_extend("force", vim.deepcopy(defaults), opts)

  if opts.contributors ~= nil then
    M.config.contributors = vim.deepcopy(opts.contributors)
  else
    M.config.contributors = {}
  end

  if M.config.persist_filters or M.config.persist_contributors then
    local saved = require("oculus.storage").load(M.config.state_file)
    if saved then
      if M.config.persist_filters then
        if saved.activity_types ~= nil then
          M.config.activity_types = saved.activity_types
        end
        if type(saved.user_activity_types) == "table" then
          M.config.user_activity_types = saved.user_activity_types
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
