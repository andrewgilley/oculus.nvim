local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local inspect = require("pantheon.inspect")

local parsed = inspect._parse_commit_url(
  "https://github.com/neovim/neovim/commit/"
    .. "0123456789abcdef0123456789abcdef01234567#diff"
)
assert(parsed)
assert(parsed.owner == "neovim")
assert(parsed.repo == "neovim")
assert(parsed.sha == "0123456789abcdef0123456789abcdef01234567")
assert(parsed.remote_url == "https://github.com/neovim/neovim.git")

assert(inspect._parse_commit_url("https://codeberg.org/a/b/commit/0123456")
  == nil)
assert(inspect._parse_commit_url("https://github.com/a/b/issues/1") == nil)
assert(inspect._parse_commit_url("https://github.com/a/b/commit/123") == nil)
assert(inspect._parse_commit_url(
  "https://github.com/a/b/commit/01234567890123456789012345678901234567890"
) == nil)
assert(inspect._parse_commit_url(
  "https://github.com/../b/commit/0123456"
) == nil)

assert(inspect._github_repository(
  "https://github.com/neovim/neovim.git"
) == "neovim/neovim")
assert(inspect._github_repository(
  "git@github.com:Neovim/Neovim.git"
) == "neovim/neovim")
assert(inspect._github_repository(
  "ssh://git@github.com/neovim/neovim.git"
) == "neovim/neovim")
assert(inspect._github_repository("https://codeberg.org/a/b.git") == nil)

local parent, change = inspect._first_changed_paths("M\tlua/pantheon/init.lua")
assert(parent == "lua/pantheon/init.lua")
assert(change == "lua/pantheon/init.lua")

parent, change = inspect._first_changed_paths(
  "R100\tlua/pantheon/old.lua\tlua/pantheon/new.lua"
)
assert(parent == "lua/pantheon/old.lua")
assert(change == "lua/pantheon/new.lua")

parent, change = inspect._first_changed_paths("")
assert(parent == nil)
assert(change == nil)

local integration_root = vim.env.PANTHEON_INSPECT_TEST_ROOT
local integration_sha = vim.env.PANTHEON_INSPECT_TEST_SHA
if integration_root and integration_sha then
  local integration_repository =
    vim.env.PANTHEON_INSPECT_TEST_REPOSITORY or "pantheon/test"
  local integration_source = vim.env.PANTHEON_INSPECT_TEST_SOURCE
  local integration_search_root =
    vim.env.PANTHEON_INSPECT_TEST_SEARCH_ROOT
  local integration_cwd = vim.env.PANTHEON_INSPECT_TEST_CWD
  local repositories = {}
  if integration_source then
    repositories[integration_repository] = integration_source
  end
  if integration_cwd then
    vim.api.nvim_set_current_dir(integration_cwd)
  end
  local ok, err = inspect.open(
    "https://github.com/" .. integration_repository
      .. "/commit/" .. integration_sha,
    {
      inspect_root = integration_root,
      inspect_repositories = repositories,
      inspect_search_paths = integration_search_root
          and { integration_search_root }
        or {},
    }
  )
  assert(ok, err)
  assert(vim.wait(30000, function()
    return #vim.api.nvim_list_tabpages() == 3
  end), "inspection tabs were not opened")

  local tabs = vim.api.nvim_list_tabpages()
  local parent_state = vim.api.nvim_tabpage_get_var(
    tabs[2],
    "pantheon_inspect"
  )
  local change_state = vim.api.nvim_tabpage_get_var(
    tabs[3],
    "pantheon_inspect"
  )
  assert(parent_state.role == "parent")
  assert(change_state.role == "change")
  assert(change_state.commit == integration_sha)
end
