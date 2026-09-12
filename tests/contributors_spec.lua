local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)
local oculus = require("oculus")
local storage = require("oculus.storage")
local window = require("oculus.window")

oculus.setup({
  persist_filters = false,
  persist_contributors = false,
  persist_projects = false,
})

assert(#oculus.config.contributors == 0)
assert(#oculus.config.projects == 0)
assert(oculus.config.suggested_contributors == nil)
assert(oculus.config.persist_projects == false)
assert(oculus.config.persist_inspect_overviews == true)
local state_file = vim.fn.tempname()

assert(storage.save(state_file, {
  contributors = {
    {
      username = "saved-user",
      provider = "github",
    },
  },
  user_activity_types = {},
  inspect_overviews = {
    ["github:example/repository:issue:42"] = {
      explanation = "Persisted inspect explanation.",
    },
  },
}))

local saved = storage.load(state_file)
assert(#saved.contributors == 1)
assert(saved.contributors[1].username == "saved-user")
assert(vim.deep_equal(saved.projects, {}))

assert(saved.inspect_overviews["github:example/repository:issue:42"]
  .explanation == "Persisted inspect explanation.")

oculus.setup({
  state_file = state_file,
  persist_filters = false,
  persist_contributors = true,
})

assert(#oculus.config.contributors == 1)
assert(oculus.config.contributors[1].username == "saved-user")

assert(oculus.config.inspect_overviews[
  "github:example/repository:issue:42"
].explanation == "Persisted inspect explanation.")

oculus.setup({
  state_file = state_file,
  persist_filters = false,
  persist_contributors = true,
  contributors = {},
})

assert(#oculus.config.contributors == 1)
assert(oculus.config.contributors[1].username == "saved-user")
vim.fn.delete(state_file)

window.open({
  width = 0.8,
  height = 0.8,
  border = "rounded",
  persist_contributors = false,
  persist_projects = false,
  contributors = {},
})

local state = window.state

local project_start_lines = table.concat(
  vim.api.nvim_buf_get_lines(state.buf, 0, -1, false),
  "\n"
)

assert(project_start_lines:find("PROJECTS", 1, true))
assert(not project_start_lines:find("No users added.", 1, true))
assert(project_start_lines:find("u users", 1, true))
local add_mapping = vim.fn.maparg("a", "n", false, true)
add_mapping.callback()
vim.fn.maparg("<CR>", "n", false, true).callback() -- Confirm provider before entering text.
vim.api.nvim_buf_set_lines(state.add_input_buf, 0, -1, false, { "example/new-project" })
vim.fn.maparg("<CR>", "n", false, true).callback()
assert(#state.opts.projects == 1)
assert(state.opts.projects[1].repository == "example/new-project")
assert(state.opts.projects[1].provider == "github")

assert(table.concat(
  vim.api.nvim_buf_get_lines(state.buf, 0, -1, false),
  "\n"
):find("example/new-project", 1, true))

local remove_mapping = vim.fn.maparg("r", "n", false, true)

assert(remove_mapping.desc
  == "Remove selected Oculus item or refresh activity")

assert(vim.fn.maparg("x", "n", false, true).desc == nil)
remove_mapping.callback()
assert(#state.opts.projects == 0)

assert(not table.concat(
  vim.api.nvim_buf_get_lines(state.buf, 0, -1, false),
  "\n"
):find("example/new-project", 1, true))

vim.fn.maparg("v", "n", false, true).callback()

local empty_lines = table.concat(
  vim.api.nvim_buf_get_lines(state.buf, 0, -1, false),
  "\n"
)

assert(empty_lines:find("No users added.", 1, true))
assert(empty_lines:find("a add account", 1, true))
assert(vim.fn.maparg("g", "n", false, true).desc == nil)
add_mapping.callback()
vim.fn.maparg("<Tab>", "n", false, true).callback()
vim.fn.maparg("<CR>", "n", false, true).callback() -- Confirm provider before entering text.
vim.api.nvim_buf_set_lines(state.add_input_buf, 0, -1, false, { "@custom-codeberg" })
vim.fn.maparg("<CR>", "n", false, true).callback()
assert(#state.contributors == 1)
assert(state.contributors[1].username == "custom-codeberg")
assert(state.contributors[1].provider == "codeberg")
remove_mapping.callback()
assert(#state.contributors == 0)
window.close()
local restart_state_file = vim.fn.tempname()

oculus.setup({
  state_file = restart_state_file,
  persist_filters = false,
  persist_contributors = true,
  contributors = {},
})

window.open(oculus.config)
vim.fn.maparg("a", "n", false, true).callback()
vim.fn.maparg("<Tab>", "n", false, true).callback()
vim.fn.maparg("<CR>", "n", false, true).callback() -- Confirm provider before entering text.
vim.api.nvim_buf_set_lines(window.state.add_input_buf, 0, -1, false, { "example/persisted-project" })
vim.fn.maparg("<CR>", "n", false, true).callback()
vim.fn.maparg("v", "n", false, true).callback()
vim.fn.maparg("a", "n", false, true).callback()
vim.fn.maparg("<CR>", "n", false, true).callback() -- Confirm provider before entering text.
vim.api.nvim_buf_set_lines(window.state.add_input_buf, 0, -1, false, { "@remember-me" })
vim.fn.maparg("<CR>", "n", false, true).callback()
assert(#window.state.contributors == 1)
assert(window.state.contributors[1].username == "remember-me")
window.close()

oculus.setup({
  state_file = restart_state_file,
  persist_filters = false,
  persist_contributors = true,
  contributors = {},
})

assert(#oculus.config.contributors == 1)
assert(oculus.config.contributors[1].username == "remember-me")

assert(oculus.config.projects[#oculus.config.projects].repository
  == "example/persisted-project")

assert(oculus.config.projects[#oculus.config.projects].provider
  == "codeberg")

window.open(oculus.config)
vim.fn.maparg("v", "n", false, true).callback()

local restarted_lines = table.concat(
  vim.api.nvim_buf_get_lines(window.state.buf, 0, -1, false),
  "\n"
)

assert(restarted_lines:find("@remember-me", 1, true))
window.close()
vim.fn.delete(restart_state_file)
local removal_state_file = vim.fn.tempname()

local removable_contributors = {
  {
    name = "Removable user",
    username = "remove-me",
    provider = "github",
  },
}

local removable_projects = {
  {
    name = "Removable project",
    repository = "example/remove-me",
    provider = "github",
  },
}

oculus.setup({
  state_file = removal_state_file,
  persist_filters = false,
  persist_contributors = true,
  persist_projects = true,
  contributors = removable_contributors,
  projects = removable_projects,
})

window.open(oculus.config)
vim.fn.maparg("r", "n", false, true).callback()
assert(#window.state.opts.projects == 0)
vim.fn.maparg("v", "n", false, true).callback()
vim.fn.maparg("r", "n", false, true).callback()
assert(#window.state.contributors == 0)
window.close()
local removal_state = assert(storage.load(removal_state_file))

assert(vim.deep_equal(
  removal_state.removed_projects,
  { "github:example/remove-me" }
))

assert(vim.deep_equal(
  removal_state.removed_contributors,
  { "github:remove-me" }
))

oculus.setup({
  state_file = removal_state_file,
  persist_filters = false,
  persist_contributors = true,
  persist_projects = true,
  contributors = removable_contributors,
  projects = removable_projects,
})

assert(#oculus.config.projects == 0)
assert(#oculus.config.contributors == 0)
vim.fn.delete(removal_state_file)
