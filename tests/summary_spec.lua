local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local summary = require("pantheon.summary")

local inspections = {
  {
    repository = root,
    parent = "aaaaaaaa",
    commit = "bbbbbbbb",
    parent_file = "lua/one.lua",
    change_file = "lua/one.lua",
  },
  {
    repository = root,
    parent = "bbbbbbbb",
    commit = "cccccccc",
    parent_file = "lua/two.lua",
    change_file = "lua/two.lua",
  },
  {
    repository = root,
    parent = "bbbbbbbb",
    commit = "cccccccc",
    parent_file = "lua/one.lua",
    change_file = "lua/one.lua",
  },
}

local prompt = summary._prompt(inspections, {
  kind = "pull_request",
  number = 42,
  title = "Keep inspection context visible",
})
assert(prompt:find(
  "Pull request #42: Keep inspection context visible",
  1,
  true
))
assert(prompt:find("Base revision: aaaaaaaa", 1, true))
assert(prompt:find("Changed revision: cccccccc", 1, true))
local _, one_count = prompt:gsub("%- lua/one%.lua", "")
assert(one_count == 1)
assert(prompt:find("- lua/two.lua", 1, true))

local message = summary._final_message(table.concat({
  vim.json.encode({
    type = "item.completed",
    item = {
      type = "command_execution",
      text = "ignored",
    },
  }),
  vim.json.encode({
    type = "item.completed",
    item = {
      type = "agent_message",
      text = "The change keeps inspection context visible.",
    },
  }),
}, "\n"))
assert(message == "The change keeps inspection context visible.")
assert(summary._normalize(" First sentence.\n\nSecond sentence. ")
  == "First sentence. Second sentence.")

local first_tab = vim.api.nvim_get_current_tabpage()
local first_win = vim.api.nvim_get_current_win()
local first_buf = vim.api.nvim_get_current_buf()
vim.cmd("tabnew")
local second_tab = vim.api.nvim_get_current_tabpage()
local second_win = vim.api.nvim_get_current_win()
local second_buf = vim.api.nvim_get_current_buf()
vim.api.nvim_set_current_tabpage(first_tab)
vim.api.nvim_set_current_win(first_win)

local group = {
  {
    parent = {
      tab = first_tab,
      win = first_win,
      buf = first_buf,
    },
    change = {
      tab = second_tab,
      win = second_win,
      buf = second_buf,
    },
  },
}
local runner_repository
local runner_prompt
summary.start(group, inspections, {
  kind = "pull_request",
  number = 42,
  title = "Keep inspection context visible",
}, {
  inspect_summary_runner = function(repository, request, _, callback)
    runner_repository = repository
    runner_prompt = request
    callback(
      "The change keeps context visible.\nIt improves inspection flow."
    )
  end,
})
assert(runner_repository == root)
assert(runner_prompt == prompt)
assert(vim.api.nvim_get_current_win() == first_win)
assert(vim.api.nvim_buf_get_lines(
  group.summary_buf,
  0,
  -1,
  false
)[1] == "The change keeps context visible. It improves inspection flow.")
assert(vim.tbl_count(group.summary_windows) == 2)
for _, view in pairs(group.summary_windows) do
  assert(vim.api.nvim_win_is_valid(view.win))
  local config = vim.api.nvim_win_get_config(view.win)
  assert(config.relative == "win")
  assert(config.anchor == "NE")
  assert(config.row == 1)
  assert(config.focusable == false)
  assert(config.col
    == vim.api.nvim_win_get_width(view.endpoint.win) - 1)
end

vim.api.nvim_set_current_tabpage(first_tab)
vim.cmd("tabonly")
