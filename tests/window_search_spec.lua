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
  navigation_delay = 50,
  contributors = contributors,
})

local state = window.state
local main_down_mapping =
  vim.fn.maparg("<Down>", "n", false, true)
local first_username = state.selected_username
main_down_mapping.callback()
local second_username = state.selected_username
assert(second_username ~= first_username)
main_down_mapping.callback()
assert(state.selected_username == second_username)
vim.wait(70, function()
  return false
end)
main_down_mapping.callback()
assert(state.selected_username ~= second_username)

local page_events = {}
for index = 1, 20 do
  page_events[index] = { id = tostring(index) }
end
local second_page = window._activity_page(page_events, 2, 8)
assert(#second_page == 8)
assert(second_page[1].id == "9")
assert(second_page[8].id == "16")
local third_page = window._activity_page(page_events, 3, 8)
assert(#third_page == 4)
assert(third_page[1].id == "17")
local search_mapping = vim.fn.maparg("/", "n", false, true)
assert(search_mapping.desc == "Fuzzy-search Pantheon users")
search_mapping.callback()
vim.wait(10)
assert(vim.api.nvim_win_is_valid(state.win))
assert(vim.api.nvim_win_is_valid(state.search_win))
assert(vim.api.nvim_buf_is_valid(state.search_buf))
local prompt = vim.fn.prompt_getprompt(state.search_buf)
assert(prompt == "")
assert(window._prompt_query(state.search_buf) == "")
local main_position = vim.api.nvim_win_get_position(state.win)
local main_width = vim.api.nvim_win_get_width(state.win)
local expected_left_width = math.max(
  30,
  math.min(
    math.max(40, math.floor(main_width * 0.46)),
    main_width - 22
  )
)
local search_config = vim.api.nvim_win_get_config(state.search_win)
local expected_right_width = main_width - expected_left_width - 1
local expected_midpoint = math.floor(expected_right_width / 2)
local expected_outer_width =
  expected_right_width - expected_midpoint - 1
assert(search_config.col
  == main_position[2]
    + expected_left_width
    + 1
    + expected_midpoint)
assert(search_config.width
  == expected_outer_width - 2)
assert(
  search_config.col + search_config.width + 2
    == main_position[2] + main_width - 1
)
assert(search_config.title == nil or search_config.title == "")
local initial_search_lines = table.concat(
  vim.api.nvim_buf_get_lines(state.buf, 0, -1, false),
  "\n"
)
assert(initial_search_lines:find("  SEARCH", 1, true))
assert(not initial_search_lines:find("arrows preview", 1, true))
assert(not initial_search_lines:find("enter open", 1, true))
assert(not initial_search_lines:find("matching user", 1, true))

vim.api.nvim_buf_set_lines(
  state.search_buf,
  0,
  -1,
  false,
  { prompt .. "m" }
)
vim.api.nvim_exec_autocmds("TextChangedI", { buffer = state.search_buf })
assert(state.search_query == "m")
assert(#state.search_results == 2)
local search_down_mapping =
  vim.fn.maparg("<C-k>", "i", false, true)
local search_up_mapping =
  vim.fn.maparg("<C-i>", "i", false, true)
local search_up_tab_mapping =
  vim.fn.maparg("<Tab>", "i", false, true)
assert(search_down_mapping.desc
  == "Move down in Pantheon user search results")
assert(search_up_mapping.desc
  == "Move up in Pantheon user search results")
assert(search_up_tab_mapping.desc
  == "Move up in Pantheon user search results")
search_down_mapping.callback()
assert(state.search_index == 2)
assert(state.preview_items[4][1] == state.search_results[2].name)
search_up_mapping.callback()
assert(state.search_index == 2)
vim.wait(70, function()
  return false
end)
search_up_mapping.callback()
assert(state.search_index == 1)
assert(state.preview_items[4][1] == state.search_results[1].name)
vim.wait(70, function()
  return false
end)
search_down_mapping.callback()
assert(state.search_index == 2)

vim.api.nvim_buf_set_lines(
  state.search_buf,
  0,
  -1,
  false,
  { prompt .. "mhash" }
)
vim.api.nvim_exec_autocmds("TextChangedI", { buffer = state.search_buf })
assert(state.search_query == "mhash")
assert(#state.search_results == 1)
assert(state.search_results[1].username == "mitchellh")
assert(state.preview_items[4][1] == "Mitchell Hashimoto")

vim.api.nvim_buf_set_lines(
  state.search_buf,
  0,
  -1,
  false,
  { prompt .. "zz" }
)
vim.api.nvim_exec_autocmds("TextChangedI", { buffer = state.search_buf })
assert(#state.search_results == 0)
local main_lines = vim.api.nvim_buf_get_lines(state.buf, 0, -1, false)
assert(table.concat(main_lines, "\n"):find("No matching users.", 1, true))

local cancel_mapping = vim.fn.maparg("<Esc>", "i", false, true)
cancel_mapping.callback()
assert(state.search_query == nil)
assert(state.search_win == nil)
assert(vim.api.nvim_win_is_valid(state.win))

local github = require("pantheon.github")
local original_events = github.events
local original_enrich_pull_requests = github.enrich_pull_requests
local original_enrich_pushes = github.enrich_pushes
local requested_per_page = {}
local activity_events = {}
for index = 1, 20 do
  activity_events[index] = {
    id = tostring(index),
    type = "CreateEvent",
    created_at = ("2026-07-%02dT12:00:00Z"):format(index),
    actor = { login = "mitchellh" },
    repo = { name = "example/repository" },
    payload = {
      ref_type = "branch",
      ref = "page-" .. index,
    },
  }
end
github.events = function(_, opts, callback)
  requested_per_page[#requested_per_page + 1] = opts.per_page
  callback(vim.deepcopy(activity_events), nil, false)
end
github.enrich_pull_requests = function(events, _, callback)
  callback(events)
end
github.enrich_pushes = function(events, _, callback)
  callback(events)
end

local select_mapping = vim.fn.maparg("<CR>", "n", false, true)
select_mapping.callback()
assert(state.view == "activity")
assert(state.activity_page == 1)
assert(#state.events == 8)
assert(state.events[1].id == "1")
assert(state.events[8].id == "8")
assert(requested_per_page[1] == 30)

local past_mapping = vim.fn.maparg("p", "n", false, true)
assert(past_mapping.desc == "Load past Pantheon activity")
past_mapping.callback()
assert(state.view == "activity")
assert(state.activity_page == 2)
assert(#state.events == 8)
assert(state.events[1].id == "9")
assert(state.events[8].id == "16")
assert(requested_per_page[2] == 38)
local activity_text = table.concat(
  vim.api.nvim_buf_get_lines(state.buf, 0, -1, false),
  "\n"
)
assert(activity_text:find("GitHub · page 2", 1, true))
assert(vim.api.nvim_win_get_cursor(state.win)[1]
  == state.activity_cursor_min_line)
local footer_text = table.concat(
  vim.api.nvim_buf_get_lines(state.footer_buf, 0, -1, false),
  "\n"
)
assert(footer_text:find("p past", 1, true))
assert(footer_text:find("r recent", 1, true))

past_mapping.callback()
assert(state.view == "activity")
assert(state.activity_page == 3)
assert(#state.events == 4)
assert(state.events[1].id == "17")
assert(requested_per_page[3] == 46)

local recent_mapping = vim.fn.maparg("r", "n", false, true)
assert(recent_mapping.desc == "Load more recent Pantheon activity")
recent_mapping.callback()
assert(state.view == "activity")
assert(state.activity_page == 2)
assert(#state.events == 8)
assert(state.events[1].id == "9")
assert(state.events[8].id == "16")
assert(requested_per_page[4] == 38)
local recent_footer_text = table.concat(
  vim.api.nvim_buf_get_lines(state.footer_buf, 0, -1, false),
  "\n"
)
assert(recent_footer_text:find("p past", 1, true))
assert(recent_footer_text:find("r recent", 1, true))

recent_mapping.callback()
assert(state.activity_page == 1)
assert(requested_per_page[5] == 30)
local page_one_footer_text = table.concat(
  vim.api.nvim_buf_get_lines(state.footer_buf, 0, -1, false),
  "\n"
)
assert(page_one_footer_text:find("p past", 1, true))
assert(not page_one_footer_text:find("r recent", 1, true))

window.close()
github.events = original_events
github.enrich_pull_requests = original_enrich_pull_requests
github.enrich_pushes = original_enrich_pushes
assert(state.search_query == nil)
assert(state.search_win == nil)
assert(state.win == nil)
