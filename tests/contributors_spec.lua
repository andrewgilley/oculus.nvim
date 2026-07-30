local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local oculus = require("oculus")
local storage = require("oculus.storage")
local window = require("oculus.window")

oculus.setup({
  persist_filters = false,
  persist_contributors = false,
})
assert(#oculus.config.contributors == 0)
assert(oculus.config.suggested_contributors == nil)

local state_file = vim.fn.tempname()
assert(storage.save(state_file, {
  contributors = {
    {
      username = "saved-user",
      provider = "github",
    },
  },
  user_activity_types = {},
}))
local saved = storage.load(state_file)
assert(#saved.contributors == 1)
assert(saved.contributors[1].username == "saved-user")
oculus.setup({
  state_file = state_file,
  persist_filters = false,
  persist_contributors = true,
})
assert(#oculus.config.contributors == 1)
assert(oculus.config.contributors[1].username == "saved-user")
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
  contributors = {},
})

local state = window.state
local empty_lines = table.concat(
  vim.api.nvim_buf_get_lines(state.buf, 0, -1, false),
  "\n"
)
assert(empty_lines:find("No users added.", 1, true))
assert(empty_lines:find("a add account", 1, true))
assert(vim.fn.maparg("g", "n", false, true).desc == nil)

local original_select = vim.ui.select
local original_input = vim.ui.input
vim.ui.select = function(items, _, callback)
  callback(items[2])
end
vim.ui.input = function(_, callback)
  callback("@custom-codeberg")
end
local add_mapping = vim.fn.maparg("a", "n", false, true)
add_mapping.callback()
vim.ui.select = original_select
vim.ui.input = original_input
assert(#state.contributors == 1)
assert(state.contributors[1].username == "custom-codeberg")
assert(state.contributors[1].provider == "codeberg")

window.close()

local restart_state_file = vim.fn.tempname()
oculus.setup({
  state_file = restart_state_file,
  persist_filters = false,
  persist_contributors = true,
  contributors = {},
})
window.open(oculus.config)
vim.ui.select = function(items, _, callback)
  callback(items[1])
end
vim.ui.input = function(_, callback)
  callback("@remember-me")
end
vim.fn.maparg("a", "n", false, true).callback()
vim.ui.select = original_select
vim.ui.input = original_input
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
window.open(oculus.config)
local restarted_lines = table.concat(
  vim.api.nvim_buf_get_lines(window.state.buf, 0, -1, false),
  "\n"
)
assert(restarted_lines:find("@remember-me", 1, true))
window.close()
vim.fn.delete(restart_state_file)
