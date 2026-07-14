local M = {}

local defaults = {
  width = 0.90,
  height = 0.80,
  row = 1,
  border = "rounded",
  title = " Pantheon ",
  per_page = 30,
  results_limit = 8,
  contributor_list_limit = 20,
  push_detail_limit = 10,
  cache_ttl = 300,
  request_timeout = 15,
  activity_types = nil,
  user_activity_types = {},
  persist_filters = true,
  state_file = vim.fn.stdpath("state") .. "/pantheon.json",
  browser_command = nil,
  token = nil,

  contributors = {
    {
      name = "Mitchell Hashimoto",
      username = "mitchellh",
      description = "Creator of Ghostty, HashiCorp, Terraform, and Nomad",
    },

    {
      name = "Luke Wagner",
      username = "lukewagner",
      description = "WebAssembly and JavaScript engine engineer",
    },

    {
      name = "Alex Kladov",
      username = "matklad",
      description = "Rust Analyzer co-creator and TigerBeetle engineer",
    },

    {
      name = "Linus Torvalds",
      username = "torvalds",
      description = "Creator of Linux and Git",
    },

    {
      name = "Michael Paulson",
      username = "ThePrimeagen",
      description = "Vim, developer tooling, and performance programming",
    },

    {
      name = "Ryan Fleury",
      username = "ryanfleury",
      description = "Systems programming, debuggers, and data-oriented tools",
    },

    {
      name = "Bill Hall",
      username = "gingerBill",
      description = "Creator of the Odin programming language",
    },

    {
      name = "Jon Gjengset",
      username = "jonhoo",
      description = "Rust educator and distributed systems engineer",
    },

    {
      name = "Jarred Sumner",
      username = "Jarred-Sumner",
      description = "Creator of the Bun JavaScript runtime and toolkit",
    },

    {
      name = "Shadan Ahmed",
      username = "shadcn",
      description = "Creator of shadcn/ui and open-code interface tooling",
    },

    {
      name = "Andrej Karpathy",
      username = "karpathy",
      description = "AI researcher; creator of nanoGPT, llm.c, and micrograd",
    },

    {
      name = "Jake Fitzgerald",
      username = "earthtojake",
      description = "Creator of Text-to-CAD and source-controlled CAD tooling",
    },

    {
      name = "Folke Lemaitre",
      username = "folke",
      description = "Creator of lazy.nvim, LazyVim, and Neovim tooling",
    },

    {
      name = "Tim Culverhouse",
      username = "rockorager",
      description = "Creator of libvaxis and modern Zig tooling",
    },

    {
      name = "Simon Willison",
      username = "simonw",
      description = "Creator of Datasette and practical LLM tooling",
    },

    {
      name = "Steven Arcangeli",
      username = "stevearc",
      description = "Creator of Neovim plugins and developer tooling",
    },

    {
      name = "Charlie Marsh",
      username = "charliermarsh",
      description = "Builder of uv, ruff, and fast Python tooling",
    },

    {
      name = "Andrew Gallant",
      username = "BurntSushi",
      description = "Creator of ripgrep, Rust regex, and jiff",
    },

    {
      name = "Carl Lerche",
      username = "carllerche",
      description = "Rust asynchronous systems engineer and creator of Tokio",
    },

    {
      name = "David Pedersen",
      username = "davidpdrsn",
      description = "Creator and maintainer of the axum web framework",
    },

    {
      name = "Georgi Gerganov",
      username = "ggerganov",
      description = "Creator of llama.cpp, whisper.cpp, and local AI tools",
    },

    {
      name = "David Tolnay",
      username = "dtolnay",
      description = "Maintainer of foundational Rust libraries and macros",
    },

    {
      name = "Justin M. Keyes",
      username = "justinmk",
      description = "Neovim maintainer and influential tooling creator",
    },

    {
      name = "Peter Steinberger",
      username = "steipete",
      description = "Creator of OpenClaw and founder of PSPDFKit",
    },

    {
      name = "Russ Cox",
      username = "rsc",
      description = "Go engineer, writer, and open-source maintainer",
    },

    {
      name = "Brad Fitzpatrick",
      username = "bradfitz",
      description = "Go contributor and open-source infrastructure engineer",
    },

    {
      name = "David H. Hansson",
      username = "dhh",
      description = "Creator of Ruby on Rails and co-owner of 37signals",
    },

    {
      name = "Alex Crichton",
      username = "alexcrichton",
      description = "WebAssembly, Wasmtime, and Rust engineer",
    },

    {
      name = "Andrew Clark",
      username = "acdlite",
      description = "React core engineer and co-creator of Redux",
    },
    {
      name = "Matt Pocock",
      username = "mattpocock",
      description = "TypeScript educator and creator of Total TypeScript",
    },
    {
      name = "Benno Lossin",
      username = "BennoLossin",
      description = "Rust-for-Linux maintainer and Rust contributor",
    },
    {
      name = "Niko Matsakis",
      username = "nikomatsakis",
      description = "Rust language designer and compiler team leader",
    },
    {
      name = "Andrew Gilley",
      username = "andrewgilley",
      description = "Creator of Pantheon and Reliquary Neovim plugins",
    },
  },
}

M.config = vim.deepcopy(defaults)
local randomized_default_contributors

local function shuffle_contributors(contributors)
  local result = vim.deepcopy(contributors)
  math.randomseed(os.time() + vim.uv.hrtime())
  for index = #result, 2, -1 do
    local swap_index = math.random(index)
    result[index], result[swap_index] = result[swap_index], result[index]
  end
  return result
end

local function default_contributors()
  if not randomized_default_contributors then
    randomized_default_contributors = shuffle_contributors(
      defaults.contributors
    )
  end
  return vim.deepcopy(randomized_default_contributors)
end

function M.setup(opts)
  opts = opts or {}
  M.config = vim.tbl_deep_extend("force", vim.deepcopy(defaults), opts)

  if opts.contributors then
    M.config.contributors = vim.deepcopy(opts.contributors)
  else
    M.config.contributors = default_contributors()
  end

  if M.config.persist_filters then
    local saved = require("pantheon.storage").load(M.config.state_file)
    if saved then
      if saved.activity_types ~= nil then
        M.config.activity_types = saved.activity_types
      end
      if type(saved.user_activity_types) == "table" then
        M.config.user_activity_types = saved.user_activity_types
      end
    end
  end
end

function M.open()
  require("pantheon.window").open(M.config)
end

function M.close()
  require("pantheon.window").close()
end

function M.toggle()
  require("pantheon.window").toggle(M.config)
end

return M
