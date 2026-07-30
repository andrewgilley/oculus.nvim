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
assert(#oculus.config.suggested_contributors > 0)
local found_codeberg_suggestion = false
for _, contributor in ipairs(oculus.config.suggested_contributors) do
  if
    contributor.username == "andrewrk"
    and contributor.provider == "codeberg"
  then
    found_codeberg_suggestion = true
    break
  end
end
assert(found_codeberg_suggestion)

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
  suggested_contributors = {
    {
      name = "Suggested GitHub",
      username = "suggested-user",
      provider = "github",
      description = "Suggested account",
    },
    {
      name = "Suggested Codeberg",
      username = "suggested-codeberg",
      provider = "codeberg",
      description = "Suggested account",
    },
  },
})

local state = window.state
local empty_lines = table.concat(
  vim.api.nvim_buf_get_lines(state.buf, 0, -1, false),
  "\n"
)
assert(empty_lines:find("No users added.", 1, true))
assert(empty_lines:find("a add account · g browse suggestions", 1, true))

local suggestions_mapping = vim.fn.maparg("g", "n", false, true)
assert(suggestions_mapping.desc == "Browse suggested Oculus users")
suggestions_mapping.callback()
assert(state.view == "suggestions")
assert(state.selected_suggestion == "github:suggested-user")

local toggle_mapping = vim.fn.maparg("<Space>", "n", false, true)
toggle_mapping.callback()
assert(#state.contributors == 1)
assert(state.contributors[1].username == "suggested-user")
local suggested_lines = table.concat(
  vim.api.nvim_buf_get_lines(state.buf, 0, -1, false),
  "\n"
)
assert(suggested_lines:find("[x]", 1, true))

local select_mapping = vim.fn.maparg("<CR>", "n", false, true)
select_mapping.callback()
assert(state.view == "contributors")
assert(#state.contributors == 1)

local remove_mapping = vim.fn.maparg("x", "n", false, true)
remove_mapping.callback()
assert(#state.contributors == 0)

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
local restart_suggestions = {
  {
    name = "Remembered Suggestion",
    username = "remember-me",
    provider = "github",
    description = "Persisted suggested account",
  },
}
oculus.setup({
  state_file = restart_state_file,
  persist_filters = false,
  persist_contributors = true,
  contributors = {},
  suggested_contributors = restart_suggestions,
})
window.open(oculus.config)
vim.fn.maparg("g", "n", false, true).callback()
vim.fn.maparg("<Space>", "n", false, true).callback()
assert(#window.state.contributors == 1)
assert(window.state.contributors[1].username == "remember-me")
window.close()

oculus.setup({
  state_file = restart_state_file,
  persist_filters = false,
  persist_contributors = true,
  contributors = {},
  suggested_contributors = restart_suggestions,
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
