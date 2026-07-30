local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local window = require("oculus.window")
local inspect = require("oculus.inspect")
local browser = require("oculus.browser")
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

local origin_win = vim.api.nvim_get_current_win()
vim.wo[origin_win].number = true
vim.wo[origin_win].relativenumber = true
window.open({
  width = 0.8,
  height = 0.8,
  border = "rounded",
  contributor_list_limit = 20,
  contributors = contributors,
})

local state = window.state
local main_window_config = vim.api.nvim_win_get_config(state.win)
assert(
  main_window_config.title == nil or main_window_config.title == ""
)
local inspection_window_options = window.inspection_window_options()
assert(inspection_window_options.number == true)
assert(inspection_window_options.relativenumber == true)
assert(
  inspection_window_options.winhighlight
    == vim.wo[origin_win].winhighlight
)
assert(vim.wo[state.win].cursorline == false)
assert(vim.wo[state.win].cursorlineopt == "line")
assert(not vim.wo[state.win].winhighlight:find(
  "CursorLine:OculusCursorLine",
  1,
  true
))
assert(vim.wo[state.win].number == false)
assert(vim.wo[state.win].relativenumber == false)
local initial_window_height = vim.api.nvim_win_get_height(state.win)
local initial_user_lines =
  vim.api.nvim_buf_get_lines(state.buf, 0, -1, false)
assert(initial_user_lines[initial_window_height]
  == "  a add  g suggested  / search  ?: help  q quit")
local main_down_mapping =
  vim.fn.maparg("<Down>", "n", false, true)
local first_list_line
local last_list_line
for line, target in pairs(state.line_targets) do
  if type(target) == "table" then
    first_list_line = math.min(first_list_line or line, line)
    last_list_line = math.max(last_list_line or line, line)
  end
end
assert(first_list_line and last_list_line)
vim.api.nvim_win_set_cursor(state.win, { 1, 0 })
vim.api.nvim_exec_autocmds("CursorMoved", { buffer = state.buf })
assert(vim.api.nvim_win_get_cursor(state.win)[1] == first_list_line)
vim.api.nvim_win_set_cursor(
  state.win,
  { vim.api.nvim_buf_line_count(state.buf), 0 }
)
vim.api.nvim_exec_autocmds("CursorMoved", { buffer = state.buf })
assert(vim.api.nvim_win_get_cursor(state.win)[1] == last_list_line)
local first_username = state.selected_username
main_down_mapping.callback()
local second_username = state.selected_username
assert(second_username ~= first_username)
main_down_mapping.callback()
assert(state.selected_username ~= second_username)
local third_username = state.selected_username
main_down_mapping.callback()
assert(state.selected_username ~= third_username)
assert(state.selected_username == first_username)

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
local search_mapping = vim.fn.maparg("s", "n", false, true)
assert(search_mapping.desc == "Fuzzy-search Oculus users")
local slash_search_mapping = vim.fn.maparg("/", "n", false, true)
assert(slash_search_mapping.desc == "Fuzzy-search Oculus users")
assert(slash_search_mapping.callback == search_mapping.callback)
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
    math.max(40, math.floor(main_width * 0.52)),
    main_width - 22
  )
)
local search_config = vim.api.nvim_win_get_config(state.search_win)
local search_title_width = vim.fn.strdisplaywidth("  COMMUNITY FIGURES")
local expected_search_width = math.max(
  1,
  math.min(18, expected_left_width - search_title_width - 4)
)
assert(search_config.col
  == main_position[2] + expected_left_width
    - expected_search_width - 3)
assert(search_config.width == expected_search_width)
assert(
  search_config.col + search_config.width + 2
    == main_position[2] + expected_left_width - 1
)
assert(search_config.title == nil or search_config.title == "")
local initial_search_lines = table.concat(
  vim.api.nvim_buf_get_lines(state.buf, 0, -1, false),
  "\n"
)
assert(initial_search_lines:find("  COMMUNITY FIGURES", 1, true))
assert(initial_search_lines:find(
  "  a add  g suggested  / search  ?: help  q quit",
  1,
  true
))
assert(not initial_search_lines:find("  SEARCH", 1, true))
assert(not initial_search_lines:find("Keep typing to refine", 1, true))
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
local populated_search_lines = table.concat(
  vim.api.nvim_buf_get_lines(state.buf, 0, -1, false),
  "\n"
)
assert(populated_search_lines:find("  SEARCH", 1, true))
assert(populated_search_lines:find("  esc cancel", 1, true))
assert(not populated_search_lines:find("Keep typing to refine", 1, true))
assert(not populated_search_lines:find("  COMMUNITY FIGURES", 1, true))
local search_down_mapping =
  vim.fn.maparg("<C-k>", "i", false, true)
local search_up_mapping =
  vim.fn.maparg("<C-i>", "i", false, true)
local search_up_tab_mapping =
  vim.fn.maparg("<Tab>", "i", false, true)
assert(search_down_mapping.desc
  == "Move down in Oculus user search results")
assert(search_up_mapping.desc
  == "Move up in Oculus user search results")
assert(search_up_tab_mapping.desc
  == "Move up in Oculus user search results")
search_down_mapping.callback()
assert(state.search_index == 2)
assert(state.preview_items[4][1] == state.search_results[2].name)
search_up_mapping.callback()
assert(state.search_index == 1)
assert(state.preview_items[4][1] == state.search_results[1].name)
search_up_mapping.callback()
assert(state.search_index == 2)
search_down_mapping.callback()
assert(state.search_index == 1)

vim.api.nvim_buf_set_lines(
  state.search_buf,
  0,
  -1,
  false,
  { prompt }
)
vim.api.nvim_exec_autocmds("TextChangedI", { buffer = state.search_buf })
assert(state.search_query == "")
local cleared_search_lines = table.concat(
  vim.api.nvim_buf_get_lines(state.buf, 0, -1, false),
  "\n"
)
assert(cleared_search_lines:find("  COMMUNITY FIGURES", 1, true))
assert(cleared_search_lines:find(
  "  a add  g suggested  / search  ?: help  q quit",
  1,
  true
))
assert(not cleared_search_lines:find("  SEARCH", 1, true))

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
assert(state.preview_items[2][1] == "PREVIEW")
assert(state.preview_items[4][1] == "Mitchell Hashimoto")
local preview_marks = vim.api.nvim_buf_get_extmarks(
  state.buf,
  vim.api.nvim_create_namespace("oculus_preview"),
  0,
  -1,
  { details = true }
)
assert(#preview_marks == #main_lines)
for _, mark in ipairs(preview_marks) do
  assert(mark[4].virt_text[1][1] == "│")
end

local cancel_mapping = vim.fn.maparg("<Esc>", "i", false, true)
cancel_mapping.callback()
assert(state.search_query == nil)
assert(state.search_win == nil)
assert(vim.api.nvim_win_is_valid(state.win))

search_mapping.callback()
vim.wait(10)
assert(window._prompt_query(state.search_buf) == "")
local empty_backspace_mapping =
  vim.fn.maparg("<BS>", "i", false, true)
assert(empty_backspace_mapping.desc
  == "Close empty Oculus user search")
assert(empty_backspace_mapping.callback() == "")
assert(state.search_query == nil)
assert(state.search_win == nil)
assert(vim.api.nvim_win_is_valid(state.win))

local github = require("oculus.github")
local original_events = github.events
local original_enrich_pull_requests = github.enrich_pull_requests
local original_enrich_pushes = github.enrich_pushes
local requested_per_page = {}
local activity_events = {}
for index = 1, 20 do
  activity_events[index] = index == 1 and {
    id = tostring(index),
    type = "PullRequestReviewCommentEvent",
    created_at = "2026-07-01T12:00:00Z",
    actor = { login = "mitchellh" },
    repo = { name = "example/repository" },
    payload = {
      pull_request = {
        number = 42,
        title = "Keep review comments visible",
        html_url = "https://github.com/example/repository/pull/42",
      },
      comment = {
        body = "Please keep this branch explicit.",
        path = "lua/example.lua",
        line = 15,
        side = "RIGHT",
        commit_id = "aaaaaaaa",
        html_url =
          "https://github.com/example/repository/pull/42#discussion_r1",
      },
    },
  } or {
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
assert(vim.wo[state.win].cursorline == true)
assert(state.activity_page == 1)
assert(#state.events == 8)
assert(state.events[1].id == "1")
assert(state.events[8].id == "8")
assert(requested_per_page[1] == 30)
local review_context
for _, context in pairs(state.inspect_targets) do
  review_context = context or review_context
end
assert(review_context)
assert(review_context.body == "Please keep this branch explicit.")
assert(review_context.path == "lua/example.lua")
assert(review_context.line == 15)
assert(review_context.side == "change")

local original_inspect_open = inspect.open
local inspect_lifecycle
inspect.open = function(url, _, context, lifecycle)
  assert(url:find(
    "https://github.com/example/repository/pull/42",
    1,
    true
  ) == 1)
  assert(context == review_context)
  inspect_lifecycle = lifecycle
  lifecycle.on_progress("⠋")
  return true
end
local inspect_mapping = vim.fn.maparg("h", "n", false, true)
assert(inspect_mapping.desc
  == "Inspect Oculus change or issue")
local inspect_activity_line =
  vim.api.nvim_win_get_cursor(state.win)[1]
local inspect_activity_text = vim.api.nvim_buf_get_lines(
  state.buf,
  inspect_activity_line - 1,
  inspect_activity_line,
  false
)[1]
inspect_mapping.callback()
local inspect_loading_namespace =
  vim.api.nvim_get_namespaces().oculus_inspect_activity_loading
assert(inspect_loading_namespace)
local first_loading_text = vim.api.nvim_buf_get_lines(
  state.buf,
  inspect_activity_line - 1,
  inspect_activity_line,
  false
)[1]
assert(
  vim.fn.strdisplaywidth(first_loading_text)
    == vim.fn.strdisplaywidth(inspect_activity_text),
  ("%d ~= %d (%q / %q)"):format(
    vim.fn.strdisplaywidth(first_loading_text),
    vim.fn.strdisplaywidth(inspect_activity_text),
    first_loading_text,
    inspect_activity_text
  )
)
assert(first_loading_text:find(" ⠋", 1, true))
assert(first_loading_text:sub(-21)
  == inspect_activity_text:sub(-21))
inspect_lifecycle.on_progress("⠙")
local second_loading_text = vim.api.nvim_buf_get_lines(
  state.buf,
  inspect_activity_line - 1,
  inspect_activity_line,
  false
)[1]
assert(vim.fn.strdisplaywidth(second_loading_text)
  == vim.fn.strdisplaywidth(inspect_activity_text))
assert(second_loading_text:find(" ⠙", 1, true))
assert(second_loading_text:sub(-21)
  == inspect_activity_text:sub(-21))
inspect_lifecycle.on_complete()
assert(vim.api.nvim_buf_get_lines(
  state.buf,
  inspect_activity_line - 1,
  inspect_activity_line,
  false
)[1] == inspect_activity_text)
assert(#vim.api.nvim_buf_get_extmarks(
  state.buf,
  inspect_loading_namespace,
  0,
  -1,
  {}
) == 0)
inspect.open = original_inspect_open

local past_mapping = vim.fn.maparg("p", "n", false, true)
assert(past_mapping.desc == "Load past Oculus activity")
local browser_mapping = vim.fn.maparg("b", "n", false, true)
assert(browser_mapping.desc == "Open Oculus activity in browser")
local original_browser_open = browser.open
local opened_activity_url
browser.open = function(url)
  opened_activity_url = url
  return true
end
browser_mapping.callback()
assert(opened_activity_url:find(
  "https://github.com/example/repository/pull/42",
  1,
  true
) == 1)
opened_activity_url = nil
local profile_mapping = vim.fn.maparg("o", "n", false, true)
assert(profile_mapping.desc == "Open Oculus contributor profile")
profile_mapping.callback()
select_mapping.callback()
assert(opened_activity_url == nil)
browser.open = original_browser_open
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
assert(footer_text:find("b browser", 1, true))

past_mapping.callback()
assert(state.view == "activity")
assert(state.activity_page == 3)
assert(#state.events == 4)
assert(state.events[1].id == "17")
assert(requested_per_page[3] == 46)

local recent_mapping = vim.fn.maparg("r", "n", false, true)
assert(recent_mapping.desc == "Load more recent Oculus activity")
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

local back_mapping = vim.fn.maparg("j", "n", false, true)
back_mapping.callback()
assert(state.view == "contributors")
assert(state.footer_win == nil)
assert(state.footer_buf == nil)
local returned_window_height = vim.api.nvim_win_get_height(state.win)
local returned_user_lines =
  vim.api.nvim_buf_get_lines(state.buf, 0, -1, false)
assert(returned_user_lines[returned_window_height]
  == "  a add  g suggested  / search  ?: help  q quit")

window.close()
github.events = original_events
github.enrich_pull_requests = original_enrich_pull_requests
github.enrich_pushes = original_enrich_pushes
assert(state.search_query == nil)
assert(state.search_win == nil)
assert(state.win == nil)
