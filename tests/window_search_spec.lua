local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local window = require("pantheon.window")
local contributors = {
  {
    name = "Mitchell Hashimoto",
    username = "mitchellh",
    description = "First result",
  },
  {
    name = "Andrew Kelley",
    username = "andrewrk",
    description = "Second result",
  },
  {
    name = "Michael Paulson",
    username = "ThePrimeagen",
    description = "Third result",
  },
}

local matches = window._fuzzy_contributors(contributors, "mhash")
assert(#matches == 1)
assert(matches[1].username == "mitchellh")

matches = window._fuzzy_contributors(contributors, "prime")
assert(matches[1].username == "ThePrimeagen")

matches = window._fuzzy_contributors(contributors, "@andrk")
assert(matches[1].username == "andrewrk")

window.open({
  width = 0.8,
  height = 0.8,
  border = "rounded",
  contributor_list_limit = 20,
  contributors = contributors,
})

local state = window.state
local search_mapping = vim.fn.maparg("/", "n", false, true)
assert(search_mapping.desc == "Fuzzy-search Pantheon users")
search_mapping.callback()
vim.wait(10)
assert(vim.api.nvim_win_is_valid(state.win))
assert(vim.api.nvim_win_is_valid(state.search_win))
assert(vim.api.nvim_buf_is_valid(state.search_buf))

vim.api.nvim_buf_set_lines(state.search_buf, 0, -1, false, { "m" })
vim.api.nvim_exec_autocmds("TextChangedI", { buffer = state.search_buf })
assert(#state.search_results == 2)
local down_mapping = vim.fn.maparg("<Down>", "i", false, true)
down_mapping.callback()
assert(state.search_index == 2)
assert(state.preview_items[4][1] == state.search_results[2].name)

vim.api.nvim_buf_set_lines(state.search_buf, 0, -1, false, { "mhash" })
vim.api.nvim_exec_autocmds("TextChangedI", { buffer = state.search_buf })
assert(state.search_query == "mhash")
assert(#state.search_results == 1)
assert(state.search_results[1].username == "mitchellh")
assert(state.preview_items[4][1] == "Mitchell Hashimoto")

vim.api.nvim_buf_set_lines(state.search_buf, 0, -1, false, { "zz" })
vim.api.nvim_exec_autocmds("TextChangedI", { buffer = state.search_buf })
assert(#state.search_results == 0)
local main_lines = vim.api.nvim_buf_get_lines(state.buf, 0, -1, false)
assert(table.concat(main_lines, "\n"):find("No matching users.", 1, true))

local cancel_mapping = vim.fn.maparg("<Esc>", "i", false, true)
cancel_mapping.callback()
assert(state.search_query == nil)
assert(state.search_win == nil)
assert(vim.api.nvim_win_is_valid(state.win))

window.close()
assert(state.search_query == nil)
assert(state.search_win == nil)
assert(state.win == nil)
