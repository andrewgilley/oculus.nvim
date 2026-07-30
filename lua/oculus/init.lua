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
  persist_filters = true,
  persist_contributors = true,
  state_file = vim.fn.stdpath("state") .. "/oculus.json",
  browser_command = nil,
  inspect_cache_ttl = 60,
  inspect_repositories = {},
  inspect_search_paths = default_inspect_search_paths,
  inspect_sidebar_toggle = "<leader>oi",
  inspect_sidebar_width = default_inspect_sidebar_width,
  inspect_overview_toggle = "o",
  inspect_version_switch = "<C-s>",
  inspect_next_chunk = "<Tab>",
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
  suggested_contributors = {
    {
      name = "Mitchell Hashimoto",
      username = "mitchellh",
    },

    {
      name = "Luke Wagner",
      username = "lukewagner",
    },

    {
      name = "Robin Freyler",
      username = "Robbepop",
    },

    {
      name = "Alex Kladov",
      username = "matklad",
    },

    {
      name = "Linus Torvalds",
      username = "torvalds",
    },

    {
      name = "Michael Paulson",
      username = "ThePrimeagen",
    },

    {
      name = "Ryan Fleury",
      username = "ryanfleury",
    },

    {
      name = "Bill Hall",
      username = "gingerBill",
    },

    -- AGENT_CHANGE_BEGIN codeberg-andrew-kelley-20260727 1 Add Andrew Kelley as a Codeberg contributor
    {
      name = "Andrew Kelley",
      username = "andrewrk",
      provider = "codeberg",
    },
    -- AGENT_CHANGE_END codeberg-andrew-kelley-20260727 1

    {
      name = "Jon Gjengset",
      username = "jonhoo",
    },

    {
      name = "Jarred Sumner",
      username = "Jarred-Sumner",
    },

    {
      name = "Shadan Ahmed",
      username = "shadcn",
    },

    {
      name = "Andrej Karpathy",
      username = "karpathy",
    },

    {
      name = "Zhiyuan Li",
      username = "zhiyuan1i",
    },

    {
      name = "Jake Fitzgerald",
      username = "earthtojake",
    },

    {
      name = "Folke Lemaitre",
      username = "folke",
    },

    {
      name = "Liam Dyer",
      username = "saghen",
    },

    {
      name = "Tim Culverhouse",
      username = "rockorager",
    },

    {
      name = "Simon Willison",
      username = "simonw",
    },

    {
      name = "Charlie Marsh",
      username = "charliermarsh",
    },

    {
      name = "Andrew Gallant",
      username = "BurntSushi",
    },

    {
      name = "Carl Lerche",
      username = "carllerche",
    },

    {
      name = "David Pedersen",
      username = "davidpdrsn",
    },

    {
      name = "Georgi Gerganov",
      username = "ggerganov",
    },

    {
      name = "Andrey Vasnetsov",
      username = "generall",
    },

    {
      name = "Glauber Costa",
      username = "glommer",
    },

    {
      name = "Pekka Enberg",
      username = "penberg",
    },

    {
      name = "Michael Paquier",
      username = "michaelpq",
    },

    {
      name = "David Tolnay",
      username = "dtolnay",
    },

    {
      name = "Justin M. Keyes",
      username = "justinmk",
    },

    {
      name = "Björn Linse",
      username = "bfredl",
    },

    {
      name = "Christian Clason",
      username = "clason",
    },

    {
      name = "Peter Steinberger",
      username = "steipete",
    },

    {
      name = "Russ Cox",
      username = "rsc",
    },

    {
      name = "Brad Fitzpatrick",
      username = "bradfitz",
    },

    {
      name = "David H. Hansson",
      username = "dhh",
    },

    {
      name = "Alex Crichton",
      username = "alexcrichton",
    },

    {
      name = "Andrew Clark",
      username = "acdlite",
    },

    {
      name = "Matt Pocock",
      username = "mattpocock",
    },

    {
      name = "Benno Lossin",
      username = "BennoLossin",
    },

    {
      name = "Niko Matsakis",
      username = "nikomatsakis",
    },

    {
      name = "Patrick Ohly",
      username = "pohly",
    },

    -- AGENT_CHANGE_BEGIN fil-c-creator-20260726 1 Add Filip Pizlo to default contributors
    {
      name = "Filip Pizlo",
      username = "pizlonator",
    },
    -- AGENT_CHANGE_END fil-c-creator-20260726 1

    -- AGENT_CHANGE_BEGIN sun-yi-name-20260726 1 Set Sun Yi display name
    {
      name = "Sun Yi",
      username = "sunyi0505",
    },
    -- AGENT_CHANGE_END sun-yi-name-20260726 1

    {
      name = "Andrew Gilley",
      username = "andrewgilley",
    },
  },
}

M.config = vim.deepcopy(defaults)
local randomized_suggested_contributors

local function shuffle_contributors(contributors)
  local result = vim.deepcopy(contributors)
  math.randomseed(os.time() + vim.uv.hrtime())
  for index = #result, 2, -1 do
    local swap_index = math.random(index)
    result[index], result[swap_index] = result[swap_index], result[index]
  end
  return result
end

local function default_suggested_contributors()
  if not randomized_suggested_contributors then
    randomized_suggested_contributors = shuffle_contributors(
      defaults.suggested_contributors
    )
  end
  return vim.deepcopy(randomized_suggested_contributors)
end

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
  if opts.suggested_contributors ~= nil then
    M.config.suggested_contributors =
      vim.deepcopy(opts.suggested_contributors)
  else
    M.config.suggested_contributors = default_suggested_contributors()
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
