local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local window = require("oculus.window")
local inspect = require("oculus.inspect")
local browser = require("oculus.browser")
local contributors = {
  {
    name = "Mitchell Hashimoto",
    username = "mitchellh",
  },
  {
    name = "Andrew Kelley",
    username = "andrewrk",
  },
  {
    name = "Michael Paulson",
    username = "ThePrimeagen",
  },
}

local matches = window._fuzzy_contributors(contributors, "mhash")
assert(#matches == 1)
assert(matches[1].username == "mitchellh")

matches = window._fuzzy_contributors(contributors, "prime")
assert(matches[1].username == "ThePrimeagen")

matches = window._fuzzy_contributors(contributors, "@andrk")
assert(matches[1].username == "andrewrk")
local project_matches = window._fuzzy_projects({
  { name = "Neovim", repository = "neovim/neovim" },
  { name = "lazy.nvim", repository = "folke/lazy.nvim" },
}, "folkelazy")
assert(#project_matches == 1)
assert(project_matches[1].repository == "folke/lazy.nvim")

local origin_win = vim.api.nvim_get_current_win()
local origin_tab = vim.api.nvim_get_current_tabpage()
local origin_buf = vim.api.nvim_win_get_buf(origin_win)
vim.api.nvim_buf_set_lines(
  origin_buf,
  0,
  -1,
  false,
  vim.tbl_map(function(index)
    return ("origin line %d with enough text"):format(index)
  end, vim.fn.range(1, 40))
)
vim.bo[origin_buf].modified = false
vim.api.nvim_win_set_cursor(origin_win, { 20, 5 })
vim.api.nvim_win_call(origin_win, function()
  vim.fn.winrestview({ topline = 10, lnum = 20, col = 5 })
end)
local origin_view = vim.api.nvim_win_call(origin_win, vim.fn.winsaveview)
vim.wo[origin_win].number = true
vim.wo[origin_win].relativenumber = true
local retained_title_color = 0x315b8a
local retained_normal_fg = 0xd8dee9
local retained_normal_bg = 0x20242c
local retained_border_fg = 0x81a1c1
local retained_border_bg = 0x2e3440
vim.api.nvim_set_hl(0, "Normal", {
  fg = retained_normal_fg,
  bg = retained_normal_bg,
})
vim.api.nvim_set_hl(0, "Title", {
  fg = retained_title_color,
  bold = true,
})
vim.api.nvim_set_hl(0, "FloatBorder", {
  fg = retained_border_fg,
  bg = retained_border_bg,
})
local source_highlight_ns = vim.api.nvim_create_namespace(
  "oculus_test_source_window"
)
local source_normal_bg = 0x343a46
vim.api.nvim_set_hl(source_highlight_ns, "Normal", {
  fg = retained_normal_fg,
  bg = 0x111318,
})
vim.api.nvim_set_hl(source_highlight_ns, "OculusTestSourceNormal", {
  fg = retained_normal_fg,
  bg = source_normal_bg,
})
vim.api.nvim_win_set_hl_ns(origin_win, source_highlight_ns)
vim.wo[origin_win].winhighlight = "Normal:OculusTestSourceNormal"
window.open({
  width = 0.8,
  height = 0.8,
  border = "rounded",
  contributor_list_limit = 20,
  contributors = contributors,
  projects = {
    {
      name = "Test project",
      repository = "example/project",
      provider = "github",
      description = "A project used by the startup list test.",
    },
    {
      name = "Other fixture",
      repository = "another/fixture",
      provider = "github",
      description = "Another project used by the startup list test.",
    },
  },
})

local state = window.state
local window_highlight_ns = assert(
  vim.api.nvim_get_namespaces().oculus_window_highlights
)
assert(vim.api.nvim_get_hl_ns({ winid = state.win }) == window_highlight_ns)
local retained_title = vim.api.nvim_get_hl(window_highlight_ns, {
  name = "Title",
  link = false,
})
assert(retained_title.fg == retained_title_color)
assert(retained_title.bold)
local retained_normal = vim.api.nvim_get_hl(window_highlight_ns, {
  name = "OculusNormal",
  link = false,
})
assert(retained_normal.fg == retained_normal_fg)
assert(retained_normal.bg == source_normal_bg)
assert(vim.api.nvim_get_hl(window_highlight_ns, {
  name = "NormalFloat",
  link = false,
}).bg == source_normal_bg)
local retained_border = vim.api.nvim_get_hl(window_highlight_ns, {
  name = "OculusBorder",
  link = false,
})
assert(retained_border.fg == retained_border_fg)
assert(retained_border.bg == source_normal_bg)
assert(vim.api.nvim_get_hl(window_highlight_ns, {
  name = "FloatBorder",
  link = false,
}).bg == source_normal_bg)
local newer_normal_bg = 0x454d5c
window.refresh_window_highlights(origin_win)
vim.api.nvim_set_hl(window_highlight_ns, "OculusNormal", {
  fg = retained_normal_fg,
  bg = newer_normal_bg,
})
window.apply_window_highlights(state.win, state.win)
vim.wait(20, function()
  return false
end)
assert(vim.api.nvim_get_hl(window_highlight_ns, {
  name = "OculusNormal",
  link = false,
}).bg == newer_normal_bg)
window.apply_window_highlights(state.win, origin_win)
assert(vim.api.nvim_get_hl(window_highlight_ns, {
  name = "OculusNormal",
  link = false,
}).bg == source_normal_bg)
vim.api.nvim_set_hl(0, "Title", { fg = 0xc46b8a })
vim.api.nvim_set_hl(0, "Normal", {
  fg = 0xf0c674,
  bg = 0x101010,
})
vim.api.nvim_set_hl(0, "FloatBorder", {
  fg = 0xff0000,
  bg = 0x000000,
})
vim.api.nvim_exec_autocmds("ColorScheme", {})
assert(vim.api.nvim_get_hl(0, {
  name = "Title",
  link = false,
}).fg == 0xc46b8a)
assert(vim.api.nvim_get_hl(window_highlight_ns, {
  name = "Title",
  link = false,
}).fg == 0xc46b8a)
local changed_normal = vim.api.nvim_get_hl(window_highlight_ns, {
  name = "OculusNormal",
  link = false,
})
assert(changed_normal.fg == retained_normal_fg)
assert(changed_normal.bg == source_normal_bg)
local changed_border = vim.api.nvim_get_hl(window_highlight_ns, {
  name = "OculusBorder",
  link = false,
})
assert(changed_border.fg == 0xff0000)
assert(changed_border.bg == source_normal_bg)
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
local initial_project_text = table.concat(
  vim.api.nvim_buf_get_lines(state.buf, 0, -1, false),
  "\n"
)
assert(initial_project_text:find("  PROJECTS", 1, true))
assert(initial_project_text:find("  ACTIVITY", 1, true))
assert(not initial_project_text:find("COMMUNITY ACTIVITY", 1, true))
assert(initial_project_text:find("example/project", 1, true))
assert(not initial_project_text:find("  USERS", 1, true))
assert(not initial_project_text:find("@mitchellh", 1, true))
assert(initial_project_text:find("t users", 1, true))
assert(initial_project_text:find("a add", 1, true))
assert(initial_project_text:find("/ search", 1, true))
do
  local first_project_line
  local last_project_line
  for line, target in pairs(state.line_targets) do
    if type(target) == "table" and target.kind == "project" then
      first_project_line = math.min(first_project_line or line, line)
      last_project_line = math.max(last_project_line or line, line)
    end
  end
  assert(first_project_line and last_project_line)
  assert(first_project_line ~= last_project_line)
  vim.api.nvim_win_set_cursor(state.win, { first_project_line, 0 })
  local project_up_mapping = vim.fn.maparg("i", "n", false, true)
  assert(project_up_mapping.desc == "Move up in Oculus")
  project_up_mapping.callback()
  assert(vim.api.nvim_win_get_cursor(state.win)[1] == last_project_line)
  assert(state.selected_project.repository == "another/fixture")
end
do
  local project_search = vim.fn.maparg("/", "n", false, true)
  assert(project_search.desc == "Fuzzy-search Oculus projects or users")
  project_search.callback()
  vim.api.nvim_buf_set_lines(
    state.search_buf,
    0,
    -1,
    false,
    { "exampleproject" }
  )
  vim.api.nvim_exec_autocmds("TextChangedI", {
    buffer = state.search_buf,
  })
  assert(state.search_kind == "projects")
  assert(#state.search_results == 1)
  assert(state.search_results[1].repository == "example/project")
  assert(vim.fn.maparg("<CR>", "i", false, true).desc
    == "Open searched Oculus project")
  vim.fn.maparg("<Esc>", "n", false, true).callback()
  assert(state.community_view == "projects")
end
local community_view_mapping = vim.fn.maparg("t", "n", false, true)
assert(community_view_mapping.desc
  == "Switch Oculus project and user lists")
assert(vim.fn.maparg("v", "n", false, true).desc == nil)
community_view_mapping.callback()
local initial_user_lines =
  vim.api.nvim_buf_get_lines(state.buf, 0, -1, false)
local initial_user_text = table.concat(initial_user_lines, "\n")
assert(initial_user_lines[5]:find("USERS", 1, true))
assert(initial_user_text:find("@mitchellh", 1, true))
assert(initial_user_text:find("@andrewrk", 1, true))
assert(not initial_user_text:find("HANDLE", 1, true))
assert(not initial_user_text:find("Mitchell Hashimoto", 1, true))
assert(not initial_user_text:find("Andrew Kelley", 1, true))
assert(initial_user_lines[initial_window_height]
  == "  t projects  a add  / search  ?: help  q quit")
local main_down_mapping =
  vim.fn.maparg("<Down>", "n", false, true)
local main_up_mapping =
  vim.fn.maparg("<Up>", "n", false, true)
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
for line = 1, vim.api.nvim_buf_line_count(state.buf) do
  if type(state.line_targets[line]) ~= "table" then
    vim.api.nvim_win_set_cursor(state.win, { line, 0 })
    vim.api.nvim_exec_autocmds("CursorMoved", { buffer = state.buf })
    local landed_line = vim.api.nvim_win_get_cursor(state.win)[1]
    assert(type(state.line_targets[landed_line]) == "table")
  end
end
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
main_down_mapping.callback()
assert(state.selected_username == contributors[1].username)
main_up_mapping.callback()
assert(state.selected_username == contributors[#contributors].username)

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
assert(search_mapping.desc == "Fuzzy-search Oculus projects or users")
local slash_search_mapping = vim.fn.maparg("/", "n", false, true)
assert(slash_search_mapping.desc == "Fuzzy-search Oculus projects or users")
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
local expected_search_width = math.max(1, expected_left_width - 6)
assert(search_config.col == main_position[2] + 2)
assert(search_config.width == expected_search_width)
assert(
  search_config.col - main_position[2]
    == main_position[2] + expected_left_width
      - (search_config.col + search_config.width + 2)
)
assert(search_config.title == nil or search_config.title == "")
local initial_search_lines = table.concat(
  vim.api.nvim_buf_get_lines(state.buf, 0, -1, false),
  "\n"
)
assert(initial_search_lines:find("  esc cancel", 1, true))
assert(not initial_search_lines:find("  SEARCH", 1, true))
assert(not initial_search_lines:find("  ACTIVITY", 1, true))
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
assert(populated_search_lines:find("  esc cancel", 1, true))
assert(not populated_search_lines:find("  SEARCH", 1, true))
assert(not populated_search_lines:find("Keep typing to refine", 1, true))
assert(not populated_search_lines:find("  COMMUNITY FIGURES", 1, true))
local search_down_mapping =
  vim.fn.maparg("<C-k>", "i", false, true)
local search_up_mapping =
  vim.fn.maparg("<C-p>", "i", false, true)
assert(search_down_mapping.desc
  == "Move down in Oculus user search results")
assert(search_up_mapping.desc
  == "Preview previous Oculus user search result")
assert(vim.fn.maparg("<C-i>", "i", false, true).desc == nil)
assert(vim.fn.maparg("<Tab>", "i", false, true).buffer ~= 1)
search_down_mapping.callback()
assert(state.search_index == 2)
assert(state.preview_items[4][1]
  == "@" .. state.search_results[2].username)
search_up_mapping.callback()
assert(state.search_index == 1)
assert(state.preview_items[4][1]
  == "@" .. state.search_results[1].username)
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
assert(cleared_search_lines:find("  esc cancel", 1, true))
assert(not cleared_search_lines:find("  SEARCH", 1, true))
assert(not cleared_search_lines:find("  COMMUNITY FIGURES", 1, true))

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
assert(state.preview_items[2][1] == "USER")
assert(state.preview_items[4][1] == "@mitchellh")
assert(state.preview_items[5][1] == "GitHub")

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
assert(state.preview_items[2][1] == "USER")
assert(state.preview_items[4][1] == "@mitchellh")
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
vim.api.nvim_buf_set_lines(
  state.search_buf,
  0,
  -1,
  false,
  { "m" }
)
vim.api.nvim_exec_autocmds("TextChangedI", { buffer = state.search_buf })
assert(state.search_query == "m")
local deleting_backspace_mapping =
  vim.fn.maparg("<BS>", "i", false, true)
assert(deleting_backspace_mapping.callback() == "<BS>")
vim.api.nvim_buf_set_lines(
  state.search_buf,
  0,
  -1,
  false,
  { "" }
)
vim.api.nvim_exec_autocmds("TextChangedI", { buffer = state.search_buf })
vim.wait(10)
assert(state.search_query == nil)
assert(state.search_win == nil)

search_mapping.callback()
vim.wait(10)
local empty_backspace_mapping =
  vim.fn.maparg("<BS>", "i", false, true)
assert(empty_backspace_mapping.desc
  == "Close empty Oculus user search")
assert(empty_backspace_mapping.callback() == "")
assert(state.search_query == nil)
assert(state.search_win == nil)
assert(vim.api.nvim_win_is_valid(state.win))

local github = require("oculus.github")
local direct_commit = github._project_commit_event("folke/lazy.nvim", {
  sha = "directcommit",
  author = { login = "folke" },
  commit = {
    message = "fix: receive project updates",
    author = {
      name = "folke",
      date = "2026-08-01T12:00:00Z",
    },
  },
})
assert(direct_commit.type == "PushEvent")
assert(direct_commit.repo.name == "folke/lazy.nvim")
assert(direct_commit.actor.login == "folke")
assert(direct_commit.payload.commits[1].sha == "directcommit")
assert(github._push_needs_enrichment({
  type = "PushEvent",
  payload = {
    size = 10,
    commits = {
      { sha = "one" },
      { sha = "two" },
      { sha = "three" },
      { sha = "four" },
      { sha = "five" },
    },
  },
}))
assert(not github._push_needs_enrichment({
  type = "PushEvent",
  payload = { size = 5, commits = { {}, {}, {}, {}, {} } },
}))
local direct_pull_request = github._project_pull_request_event(
  "folke/lazy.nvim",
  {
    number = 123,
    title = "Fix project updates",
    user = { login = "contributor" },
    merged_at = "2026-08-02T12:00:00Z",
    html_url = "https://github.com/folke/lazy.nvim/pull/123",
  }
)
assert(direct_pull_request.type == "PullRequestEvent")
assert(direct_pull_request.payload.action == "merged")
assert(direct_pull_request.payload.pull_request.number == 123)
do
  local enriched_pull_request = github.apply_pull_request({
    type = "PullRequestEvent",
    repo = { name = "example/repository" },
    actor = { login = "merge-maintainer" },
    payload = {
      action = "merged",
      pull_request = { number = 42 },
    },
  }, {
    number = 42,
    title = "Preserve project identities",
    html_url = "https://github.com/example/repository/pull/42",
    user = { login = "pull-author" },
    merged_by = { login = "merge-maintainer" },
  })
  assert(enriched_pull_request.payload.pull_request.user.login
    == "pull-author")
  assert(enriched_pull_request.payload.pull_request.merged_by.login
    == "merge-maintainer")
  assert(window._project_pull_request_title(
    enriched_pull_request,
    "merged pull request #42 in example/repository"
  ) == "@merge-maintainer merged pr #42 from @pull-author "
    .. "in example/repository")
  enriched_pull_request.payload.pull_request.user.login =
    "Merge-Maintainer"
  assert(window._project_pull_request_title(
    enriched_pull_request,
    "merged pull request #42 in example/repository"
  ) == "@merge-maintainer merged pr #42 in example/repository")
end
do
  local codeberg = require("oculus.codeberg")
  local merged_pull_request = codeberg.normalize_activity({
    id = 42,
    op_type = "merge_pull_request",
    act_user = { login = "codeberg-merger" },
    repo = {
      full_name = "ziglang/zig",
      html_url = "https://codeberg.org/ziglang/zig",
    },
    content = vim.json.encode({ 123, "Merge parser update" }),
    created = "2026-08-01T12:00:00Z",
  })
  assert(merged_pull_request.payload.pull_request.merged_by.login
    == "codeberg-merger")
  local partial_push = codeberg.normalize_activity({
    id = 43,
    op_type = "commit_repo",
    act_user = { login = "codeberg-author" },
    repo = {
      full_name = "ziglang/zig",
      html_url = "https://codeberg.org/ziglang/zig",
    },
    content = vim.json.encode({
      Len = 10,
      CompareURL = "/ziglang/zig/compare/old...new",
      HeadCommit = { Sha1 = "commit10", Message = "Commit 10" },
      Commits = {
        { Sha1 = "commit1", Message = "Commit 1" },
        { Sha1 = "commit2", Message = "Commit 2" },
        { Sha1 = "commit3", Message = "Commit 3" },
        { Sha1 = "commit4", Message = "Commit 4" },
        { Sha1 = "commit5", Message = "Commit 5" },
      },
    }),
    created = "2026-08-01T12:00:00Z",
  })
  assert(codeberg._push_needs_enrichment(partial_push))
  local comparison_commits = {}
  for index = 1, 10 do
    comparison_commits[index] = {
      sha = "commit" .. index,
      commit = { message = "Commit " .. index },
    }
  end
  assert(codeberg._apply_push_comparison(partial_push, {
    total_commits = 10,
    commits = comparison_commits,
  }))
  assert(#partial_push.payload.commits == 10)
  assert(not codeberg._push_needs_enrichment(partial_push))
end
local original_events = github.events
local original_enrich_pull_requests = github.enrich_pull_requests
local original_enrich_pushes = github.enrich_pushes
local original_pull_request_commits = github.pull_request_commits
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
  } or index == 2 and {
    id = tostring(index),
    type = "PushEvent",
    created_at = "2026-07-02T12:00:00Z",
    actor = { login = "mitchellh" },
    repo = { name = "example/repository" },
    payload = {
      ref = "refs/heads/main",
      before = "00000000",
      head = "44444444",
      size = 10,
      commits = {
        { sha = "aaaaaaaa", message = "First grouped commit" },
        { sha = "bbbbbbbb", message = "Second grouped commit" },
        { sha = "cccccccc", message = "Third grouped commit" },
        { sha = "dddddddd", message = "Fourth grouped commit" },
        { sha = "eeeeeeee", message = "Fifth grouped commit" },
        { sha = "ffffffff", message = "Sixth grouped commit" },
        { sha = "11111111", message = "Seventh grouped commit" },
        { sha = "22222222", message = "Eighth grouped commit" },
        { sha = "33333333", message = "Ninth grouped commit" },
        { sha = "44444444", message = "Tenth grouped commit" },
      },
    },
    url = "https://github.com/example/repository/commit/44444444",
    group_url =
      "https://github.com/example/repository/compare/aaaaaaaa...eeeeeeee",
  } or index == 3 and {
    id = tostring(index),
    type = "PullRequestEvent",
    created_at = "2026-07-03T12:00:00Z",
    actor = { login = "mitchellh" },
    repo = { name = "example/repository" },
    payload = {
      action = "opened",
      number = 42,
      pull_request = {
        number = 42,
        title = "List pull request commits",
        html_url = "https://github.com/example/repository/pull/42",
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
local deferred_activity_request
local requested_force = {}
github.events = function(_, opts, callback)
  requested_per_page[#requested_per_page + 1] = opts.per_page
  requested_force[#requested_force + 1] = opts.force
  if deferred_activity_request == true then
    deferred_activity_request = {
      callback = callback,
      events = vim.deepcopy(activity_events),
    }
    return
  end
  callback(vim.deepcopy(activity_events), nil, false)
end
github.enrich_pull_requests = function(events, _, callback)
  callback(events)
end
github.enrich_pushes = function(events, _, callback)
  callback(events)
end
github.pull_request_commits = function(repo, number, _, callback)
  assert(repo == "example/repository")
  assert(number == 42)
  local commits = {}
  for index = 1, 3 do
    commits[index] = {
      sha = "prcommit" .. index,
      html_url = "https://github.com/example/repository/commit/prcommit"
        .. index,
      author = { login = "pr-author-" .. index },
      commit = {
        message = "PR commit " .. index,
        author = {
          name = "PR Author " .. index,
          date = ("2026-07-%02dT12:00:00Z"):format(index),
        },
      },
    }
  end
  callback(commits)
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
local first_activity_text = table.concat(
  vim.api.nvim_buf_get_lines(state.buf, 0, -1, false),
  "\n"
)
assert(first_activity_text:find("  USER", 1, true))
assert(first_activity_text:find(
  "@" .. state.contributor.username,
  1,
  true
))
assert(not first_activity_text:find(state.contributor.name, 1, true))
local expansion_line
local expansion_count = 0
for line, event in pairs(state.activity_expansion_targets) do
  if event.id == "2" then
    expansion_count = expansion_count + 1
    if state.activity_title_lines[line] == line then
      expansion_line = line
    end
  end
end
assert(expansion_line)
assert(expansion_count == 5)
local listed_commit_urls = {}
for line, title_line in pairs(state.activity_title_lines) do
  if title_line == expansion_line then
    assert(state.activity_expansion_targets[line].id == "2")
    local url = state.line_targets[line]
    if type(url) == "string" and url:find("/commit/", 1, true) then
      listed_commit_urls[url] = true
    end
  end
end
for _, sha in ipairs({ "aaaaaaaa", "bbbbbbbb", "cccccccc" }) do
  assert(listed_commit_urls[
    "https://github.com/example/repository/commit/" .. sha
  ])
end
assert(not listed_commit_urls[
  "https://github.com/example/repository/commit/dddddddd"
])
local expansion_detail_line
for line, title_line in pairs(state.activity_title_lines) do
  if title_line == expansion_line and line ~= expansion_line then
    expansion_detail_line = line
    break
  end
end
assert(expansion_detail_line)
vim.api.nvim_win_set_cursor(state.win, { expansion_detail_line, 0 })
vim.fn.maparg("l", "n", false, true).callback()
assert(state.activity_commit_page == true)
assert(#state.events == 10)
vim.fn.maparg("j", "n", false, true).callback()
assert(state.activity_commit_page == false)
assert(vim.api.nvim_win_get_cursor(state.win)[1] == expansion_detail_line)
vim.api.nvim_win_set_cursor(state.win, { expansion_line, 0 })
vim.fn.maparg("<Right>", "n", false, true).callback()
assert(state.activity_commit_page == true)
assert(#state.events == 10)
vim.fn.maparg("j", "n", false, true).callback()
assert(state.activity_commit_page == false)
assert(vim.api.nvim_win_get_cursor(state.win)[1] == expansion_line)
vim.api.nvim_win_set_cursor(state.win, { expansion_line, 0 })
select_mapping.callback()
assert(state.view == "activity")
assert(state.activity_commit_page == true)
assert(#state.events == 10)
local commit_page_lines = table.concat(
  vim.api.nvim_buf_get_lines(state.buf, 0, -1, false),
  "\n"
)
assert(not commit_page_lines:find("10 commits", 1, true))
assert(not commit_page_lines:find("pushed 1 commit", 1, true))
assert(commit_page_lines:find(
  "pushed commit to example/repository",
  1,
  true
))
for index, event in ipairs(state.events) do
  assert(event.type == "PushEvent")
  assert(event.payload.size == 1)
  assert(#event.payload.commits == 1)
  assert(event.payload.head
    == ({
      "aaaaaaaa",
      "bbbbbbbb",
      "cccccccc",
      "dddddddd",
      "eeeeeeee",
      "ffffffff",
      "11111111",
      "22222222",
      "33333333",
      "44444444",
    })[index])
  local found_url = false
  for _, url in pairs(state.line_targets) do
    if
      url
      == "https://github.com/example/repository/commit/"
        .. event.payload.head
    then
      found_url = true
      break
    end
  end
  assert(found_url)
end
local commit_footer_lines = table.concat(
  vim.api.nvim_buf_get_lines(state.footer_buf, 0, -1, false),
  "\n"
)
assert(vim.api.nvim_get_hl_ns({ winid = state.footer_win })
  == window_highlight_ns)
assert(not commit_footer_lines:find("p past", 1, true))
assert(not commit_footer_lines:find("l/→ past", 1, true))
assert(not commit_footer_lines:find("j/←", 1, true))
assert(not commit_footer_lines:find("? shortcuts", 1, true))
vim.fn.maparg("j", "n", false, true).callback()
assert(state.activity_commit_page == false)
assert(#state.events == 8)
assert(state.events[2].id == "2")
assert(vim.api.nvim_win_get_cursor(state.win)[1] == expansion_line)
local pull_request_line
for line, event in pairs(state.activity_expansion_targets) do
  if event.id == "3" and state.activity_title_lines[line] == line then
    pull_request_line = line
    break
  end
end
assert(pull_request_line)
vim.api.nvim_win_set_cursor(state.win, { pull_request_line, 0 })
select_mapping.callback()
assert(state.activity_commit_page == true)
assert(#state.events == 3)
local pull_request_commit_text = table.concat(
  vim.api.nvim_buf_get_lines(state.buf, 0, -1, false),
  "\n"
)
for index, event in ipairs(state.events) do
  assert(event.type == "PushEvent")
  assert(event.payload.size == 1)
  assert(event.payload.head == "prcommit" .. index)
  assert(event.payload.commits[1].message == "PR commit " .. index)
  assert(pull_request_commit_text:find("PR commit " .. index, 1, true))
end
assert(pull_request_commit_text:find(
  "pushed commit to example/repository",
  1,
  true
))
vim.fn.maparg("j", "n", false, true).callback()
assert(state.activity_commit_page == false)
assert(vim.api.nvim_win_get_cursor(state.win)[1] == pull_request_line)
local review_context
for _, context in pairs(state.inspect_targets) do
  review_context = context or review_context
end
assert(review_context)
assert(review_context.body == "Please keep this branch explicit.")
assert(review_context.path == "lua/example.lua")
assert(review_context.line == 15)
assert(review_context.side == "change")
assert(vim.trim(vim.api.nvim_buf_get_lines(
  state.buf,
  state.activity_scroll_limit_line - 1,
  state.activity_scroll_limit_line,
  false
)[1]) ~= "")
assert(vim.api.nvim_buf_line_count(state.buf)
  == state.activity_scroll_limit_line)
vim.api.nvim_win_set_cursor(
  state.win,
  { vim.api.nvim_buf_line_count(state.buf), 0 }
)
vim.api.nvim_exec_autocmds("CursorMoved", { buffer = state.buf })
assert(vim.api.nvim_win_get_cursor(state.win)[1]
  == state.activity_scroll_limit_line)
main_down_mapping.callback()
assert(vim.api.nvim_win_get_cursor(state.win)[1]
  == state.activity_scroll_limit_line)
local inspect_source_line
for line, title_line in pairs(state.activity_title_lines) do
  if
    line ~= title_line
    and state.inspect_targets[line] == review_context
  then
    inspect_source_line = line
    break
  end
end
assert(inspect_source_line)
vim.api.nvim_win_set_cursor(state.win, { inspect_source_line, 0 })
local inspect_description_text = vim.api.nvim_buf_get_lines(
  state.buf,
  inspect_source_line - 1,
  inspect_source_line,
  false
)[1]

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
local inspect_activity_line = state.activity_title_lines[inspect_source_line]
assert(inspect_activity_line ~= inspect_source_line)
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
assert(vim.api.nvim_buf_get_lines(
  state.buf,
  inspect_source_line - 1,
  inspect_source_line,
  false
)[1] == inspect_description_text)
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
local older_mapping = vim.fn.maparg("l", "n", false, true)
local older_arrow_mapping = vim.fn.maparg("<Right>", "n", false, true)
local newer_mapping = vim.fn.maparg("j", "n", false, true)
local newer_arrow_mapping = vim.fn.maparg("<Left>", "n", false, true)
assert(older_mapping.desc == "Move right in Oculus")
assert(older_arrow_mapping.desc == "Move right in Oculus")
assert(newer_mapping.desc == "Move left in Oculus")
assert(newer_arrow_mapping.desc == "Move left in Oculus")
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
local activity_before_page_load =
  vim.api.nvim_buf_get_lines(state.buf, 0, -1, false)
deferred_activity_request = true
past_mapping.callback()
assert(state.view == "activity")
assert(state.activity_page == 2)
assert(state.events[1].id == "1")
assert(vim.deep_equal(
  vim.api.nvim_buf_get_lines(state.buf, 0, -1, false),
  activity_before_page_load
))
assert(not table.concat(activity_before_page_load, "\n"):find(
  "Loading",
  1,
  true
))
assert(activity_before_page_load[3]:find(
  "@" .. state.contributor.username,
  1,
  true
))
local activity_page_loading_namespace =
  vim.api.nvim_get_namespaces().oculus_activity_page_loading
local activity_page_loading_marks = vim.api.nvim_buf_get_extmarks(
  state.buf,
  activity_page_loading_namespace,
  0,
  -1,
  { details = true }
)
assert(#activity_page_loading_marks == 1)
assert(activity_page_loading_marks[1][2] == 2)
assert(activity_page_loading_marks[1][4].virt_text[1][1]:match("^ "))
local pending_activity_request = deferred_activity_request
deferred_activity_request = nil
pending_activity_request.callback(
  pending_activity_request.events,
  nil,
  false
)
assert(#state.events == 8)
assert(state.events[1].id == "9")
assert(state.events[8].id == "16")
assert(requested_per_page[2] == 38)
assert(#vim.api.nvim_buf_get_extmarks(
  state.buf,
  activity_page_loading_namespace,
  0,
  -1,
  {}
) == 0)
local activity_text = table.concat(
  vim.api.nvim_buf_get_lines(state.buf, 0, -1, false),
  "\n"
)
assert(activity_text:find("GitHub (2/2)", 1, true))
assert(not activity_text:find("page 2", 1, true))
assert(vim.api.nvim_win_get_cursor(state.win)[1]
  == state.activity_cursor_min_line)
local footer_text = table.concat(
  vim.api.nvim_buf_get_lines(state.footer_buf, 0, -1, false),
  "\n"
)
assert(not footer_text:find("l/→", 1, true))
assert(not footer_text:find("j/←", 1, true))
assert(not footer_text:find("? shortcuts", 1, true))
assert(footer_text:find("b browser", 1, true))
assert(footer_text:find("p past", 1, true))
assert(footer_text:find("f forward", 1, true))
assert(footer_text:find("r refresh", 1, true))
assert(not footer_text:find("r recent", 1, true))
assert(not footer_text:find("u refresh", 1, true))
assert(footer_text:find("q close", 1, true))

older_mapping.callback()
assert(state.view == "activity")
assert(state.activity_page == 3)
assert(#state.events == 4)
assert(state.events[1].id == "17")
assert(requested_per_page[3] == 46)
local last_activity_text = table.concat(
  vim.api.nvim_buf_get_lines(state.buf, 0, -1, false),
  "\n"
)
assert(last_activity_text:find("GitHub (3/3)", 1, true))

local recent_mapping = vim.fn.maparg("f", "n", false, true)
assert(recent_mapping.desc
  == "Move forward or edit Oculus activity categories")
newer_mapping.callback()
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
assert(not recent_footer_text:find("l/→", 1, true))
assert(not recent_footer_text:find("j/←", 1, true))
assert(not recent_footer_text:find("? shortcuts", 1, true))
local recent_activity_text = table.concat(
  vim.api.nvim_buf_get_lines(state.buf, 0, -1, false),
  "\n"
)
assert(recent_activity_text:find("GitHub (2/3)", 1, true))

older_arrow_mapping.callback()
assert(state.activity_page == 3)
assert(requested_per_page[5] == 46)
newer_arrow_mapping.callback()
assert(state.activity_page == 2)
assert(requested_per_page[6] == 38)
recent_mapping.callback()
assert(state.activity_page == 1)
assert(requested_per_page[7] == 30)
local page_one_activity_text = table.concat(
  vim.api.nvim_buf_get_lines(state.buf, 0, -1, false),
  "\n"
)
assert(page_one_activity_text:find("GitHub (1/3)", 1, true))
local page_one_footer_text = table.concat(
  vim.api.nvim_buf_get_lines(state.footer_buf, 0, -1, false),
  "\n"
)
assert(not page_one_footer_text:find("l/→", 1, true))
assert(not page_one_footer_text:find("j/←", 1, true))
assert(not page_one_footer_text:find("? shortcuts", 1, true))
local user_refresh_mapping = vim.fn.maparg("r", "n", false, true)
assert(user_refresh_mapping.desc == "Refresh Oculus activity")
assert(vim.fn.maparg("R", "n", false, true).desc == nil)
user_refresh_mapping.callback()
assert(requested_force[#requested_force] == true)
assert(state.activity_page == 1)

newer_mapping.callback()
assert(state.view == "contributors")
assert(state.footer_win == nil)
assert(state.footer_buf == nil)
local returned_window_height = vim.api.nvim_win_get_height(state.win)
local returned_user_lines =
  vim.api.nvim_buf_get_lines(state.buf, 0, -1, false)
assert(returned_user_lines[returned_window_height]
  == "  t projects  a add  / search  ?: help  q quit")

do
  vim.cmd("tabnew")
  local inspect_tab_one = vim.api.nvim_get_current_tabpage()
  vim.cmd("tabnew")
  local inspect_tab_two = vim.api.nvim_get_current_tabpage()
  vim.api.nvim_set_current_tabpage(origin_tab)
  vim.api.nvim_set_current_win(state.win)
  local inspect_tabs_before_close = vim.api.nvim_list_tabpages()
  vim.api.nvim_win_set_cursor(origin_win, { 30, 0 })
  vim.api.nvim_win_call(origin_win, function()
    vim.fn.winrestview({ topline = 20, lnum = 30, col = 0 })
  end)
  vim.api.nvim_set_current_tabpage(inspect_tab_two)
  window.close()
  assert(vim.deep_equal(
    vim.api.nvim_list_tabpages(),
    inspect_tabs_before_close
  ))
  assert(vim.api.nvim_tabpage_is_valid(inspect_tab_one))
  assert(vim.api.nvim_tabpage_is_valid(inspect_tab_two))
  assert(vim.api.nvim_get_current_tabpage() == origin_tab)
  assert(vim.api.nvim_get_current_win() == origin_win)
  local restored_view = vim.api.nvim_win_call(
    origin_win,
    vim.fn.winsaveview
  )
  assert(restored_view.lnum == origin_view.lnum)
  assert(restored_view.col == origin_view.col)
  assert(restored_view.topline == origin_view.topline)
  assert(restored_view.leftcol == origin_view.leftcol)
end
do
  local original_repository_events = github.repository_events
  local original_repository_updates = github.repository_updates
  local original_repository_issues = github.repository_issues
  local repository_forces = {}
  local repository_per_page
  local repository_pages = {}
  local repository_update_pages = {}
  local project_pushes_enriched = false
  local deferred_project_request
  local repository_issue_requests = {}
  github.repository_events = function(repository, opts, callback)
    assert(repository == "neovim/neovim")
    repository_forces[#repository_forces + 1] = opts.force
    repository_per_page = opts.per_page
    repository_pages[#repository_pages + 1] = opts.page
    if opts.page == 2 then
      local events = {}
      for index = 1, 4 do
        events[#events + 1] = {
          type = "PushEvent",
          repo = { name = repository },
          created_at = "2026-07-05T12:00:00Z",
          payload = { size = 1 },
        }
      end
      for index = 5, 100 do
        events[#events + 1] = {
          type = "CreateEvent",
          repo = { name = repository },
          created_at = "2026-07-05T12:00:00Z",
          payload = { ref_type = "branch", ref = "ignored" },
        }
      end
      callback(events, nil, false)
      return
    end
    if opts.page == 3 then
      local events = {}
      for index = 1, 8 do
        events[#events + 1] = {
          id = "page-3-push-" .. index,
          type = "PushEvent",
          repo = { name = repository },
          created_at = "2026-07-06T12:00:00Z",
          payload = { size = 1 },
        }
      end
      if deferred_project_request == true then
        deferred_project_request = {
          callback = callback,
          events = events,
        }
        return
      end
      callback(events, nil, false)
      return
    end
    if opts.page == 4 then
      callback({}, nil, false)
      return
    end
    local events = {
      {
        type = "PushEvent",
        repo = { name = repository },
        actor = { login = "project-author" },
        created_at = "2026-07-01T12:00:00Z",
        payload = { size = 2 },
      },
      {
        type = "PullRequestEvent",
        repo = { name = repository },
        actor = { login = "merge-maintainer" },
        created_at = "2026-07-02T12:00:00Z",
        payload = {
          action = "merged",
          pull_request = {
            number = 10,
            title = "Improve startup",
            user = { login = "pull-author" },
          },
        },
      },
      {
        type = "PullRequestEvent",
        repo = { name = repository },
        actor = { login = "self-maintainer" },
        created_at = "2026-07-02T13:00:00Z",
        payload = {
          action = "merged",
          pull_request = {
            number = 12,
            title = "Refine defaults",
            user = { login = "self-maintainer" },
          },
        },
      },
      {
        type = "IssuesEvent",
        repo = { name = repository },
        created_at = "2026-07-03T12:00:00Z",
        payload = {
          action = "assigned",
          issue = { number = 11, title = "Track startup" },
        },
      },
      {
        type = "CreateEvent",
        repo = { name = repository },
        created_at = "2026-07-04T12:00:00Z",
        payload = { ref_type = "branch", ref = "ignored" },
      },
    }
    -- GitHub's Neovim feed can return 99 rows for per_page=100 even though a
    -- second page exists. Keep this fixture short by one row to guard against
    -- treating that response as end-of-history.
    for index = 5, 99 do
      events[#events + 1] = {
        id = "page-1-ignored-" .. index,
        type = "CreateEvent",
        repo = { name = repository },
        created_at = "2026-07-04T12:00:00Z",
        payload = { ref_type = "branch", ref = "ignored" },
      }
    end
    callback(events, nil, false)
  end
  github.repository_updates = function(repository, opts, callback)
    assert(repository == "neovim/neovim")
    repository_update_pages[#repository_update_pages + 1] = opts.page
    callback({}, nil, false)
  end
  github.repository_issues = function(repository, opts, callback)
    assert(repository == "neovim/neovim")
    repository_issue_requests[#repository_issue_requests + 1] = {
      state = opts.issue_state,
      page = opts.page,
      force = opts.force,
    }
    local state_name = opts.issue_state == "closed" and "closed" or "open"
    local events = {}
    for index = 1, 10 do
      events[#events + 1] = {
        id = "project-issue-" .. state_name .. "-" .. index,
        type = "IssuesEvent",
        actor = { login = "issue-author-" .. index },
        repo = { name = repository },
        created_at = ("2026-08-%02dT12:00:00Z"):format(11 - index),
        url = ("https://github.com/%s/issues/%d"):format(
          repository,
          index
        ),
        payload = {
          action = state_name == "closed" and "closed" or "opened",
          issue = {
            number = index,
            title = "Project issue " .. index,
            body = "Issue body " .. index,
            state = state_name,
            assignees = { { login = "issue-owner" } },
            html_url = ("https://github.com/%s/issues/%d"):format(
              repository,
              index
            ),
            created_at = "2026-08-01T12:00:00Z",
          },
        },
      }
    end
    callback(events, nil, false, true)
  end
  github.enrich_pull_requests = function(events, _, callback)
    callback(events)
  end
  github.enrich_pushes = function(events, _, callback)
    project_pushes_enriched = true
    events[1].payload.commits = {
      { sha = "projectcommit1", message = "First project commit" },
      { sha = "projectcommit2", message = "Second project commit" },
    }
    callback(events)
  end
  window.open({
    width = 0.8,
    height = 0.8,
    border = "rounded",
    results_limit = 8,
    projects = {
      {
        name = "Neovim",
        repository = "neovim/neovim",
        provider = "github",
        description = "Vim-fork focused on extensibility and usability.",
      },
    },
  })
  state = window.state
  assert(vim.api.nvim_get_hl_ns({ winid = state.win })
    == window_highlight_ns)
  assert(vim.api.nvim_get_hl(window_highlight_ns, {
    name = "Title",
    link = false,
  }).fg == 0xc46b8a)
  local reopened_normal = vim.api.nvim_get_hl(window_highlight_ns, {
    name = "OculusNormal",
    link = false,
  })
  assert(reopened_normal.fg == retained_normal_fg)
  assert(reopened_normal.bg == source_normal_bg)
  local startpage_text = table.concat(
    vim.api.nvim_buf_get_lines(state.buf, 0, -1, false),
    "\n"
  )
  assert(startpage_text:find("  PROJECTS", 1, true))
  assert(not startpage_text:find("  USERS", 1, true))
  assert(not startpage_text:find("PROJECT ACTIVITY", 1, true))
  assert(startpage_text:find("neovim/neovim", 1, true))
  assert(startpage_text:find("t users", 1, true))
  local preview_text = {}
  for _, item in pairs(state.preview_items) do
    preview_text[#preview_text + 1] = item[1]
  end
  preview_text = table.concat(preview_text, " ")
  assert(preview_text:find(
    "Vim%-fork focused on extensibility and usability%."
  ))
  assert(not preview_text:find("pushes", 1, true))
  assert(not preview_text:find("merged PRs", 1, true))
  assert(not preview_text:find("assigned issues", 1, true))
  local project_line
  for line, target in pairs(state.line_targets) do
    if target.kind == "project" then
      project_line = line
      break
    end
  end
  assert(project_line)
  vim.api.nvim_win_set_cursor(state.win, { project_line, 0 })
  vim.fn.maparg("<CR>", "n", false, true).callback()
  assert(state.activity_scope == "project")
  assert(state.activity_project.repository == "neovim/neovim")
  assert(#state.events == 8)
  local project_activity_items = 0
  for line, title_line in pairs(state.activity_title_lines) do
    if line == title_line then
      project_activity_items = project_activity_items + 1
    end
  end
  assert(project_activity_items == 8)
  assert(#state.events[1].payload.commits == 2)
  assert(project_pushes_enriched)
  assert(repository_per_page == 100)
  assert(vim.deep_equal(repository_pages, { 1, 2 }))
  local project_activity_text = table.concat(
    vim.api.nvim_buf_get_lines(state.buf, 0, -1, false),
    "\n"
  )
  assert(project_activity_text:find("  PROJECT", 1, true))
  assert(project_activity_text:find("neovim/neovim", 1, true))
  assert(project_activity_text:find("@project-author pushed", 1, true))
  assert(project_activity_text:find(
    "@merge%-maintainer merged pr #10"
  ))
  assert(project_activity_text:find(
    "@self%-maintainer merged pr #12 in "
  ))
  assert(not project_activity_text:find("pr #12 from", 1, true))
  assert(not project_activity_text:find("• Merged by", 1, true))
  assert(project_activity_text:find("First project commit", 1, true))
  assert(project_activity_text:find("Second project commit", 1, true))
  local project_footer_text = table.concat(
    vim.api.nvim_buf_get_lines(state.footer_buf, 0, -1, false),
    "\n"
  )
  assert(project_footer_text:find("u issues", 1, true))
  local project_cursor = vim.api.nvim_win_get_cursor(state.win)
  local project_issues_mapping = vim.fn.maparg("u", "n", false, true)
  assert(project_issues_mapping.desc == "Open Oculus project issues")
  project_issues_mapping.callback()
  assert(state.view == "activity")
  assert(state.activity_issue_page == true)
  assert(state.activity_project.repository == "neovim/neovim")
  assert(#state.events == 8)
  assert(repository_issue_requests[1].state == "open")
  assert(repository_issue_requests[1].page == 1)
  local issue_activity_text = table.concat(
    vim.api.nvim_buf_get_lines(state.buf, 0, -1, false),
    "\n"
  )
  assert(issue_activity_text:find("  ISSUES", 1, true))
  assert(
    issue_activity_text:find("Project issue 1", 1, true),
    issue_activity_text
  )
  local issue_footer_text = table.concat(
    vim.api.nvim_buf_get_lines(state.footer_buf, 0, -1, false),
    "\n"
  )
  assert(issue_footer_text:find("f filters", 1, true))
  assert(not issue_footer_text:find("f forward", 1, true))
  vim.fn.maparg("f", "n", false, true).callback()
  assert(state.view == "issue_filters")
  local issue_filter_text = table.concat(
    vim.api.nvim_buf_get_lines(state.buf, 0, -1, false),
    "\n"
  )
  assert(issue_filter_text:find("ISSUE FILTERS", 1, true))
  assert(issue_filter_text:find("Open issues", 1, true))
  assert(issue_filter_text:find("Closed issues", 1, true))
  assert(issue_filter_text:find("Assigned issues", 1, true))
  assert(issue_filter_text:find("Unassigned issues", 1, true))
  local closed_filter_line
  local assigned_filter_line
  for line, target in pairs(state.line_targets) do
    if target.issue_filter
      and target.dimension == "state"
      and target.value == "closed"
    then
      closed_filter_line = line
    elseif target.issue_filter
      and target.dimension == "assignment"
      and target.value == "assigned"
    then
      assigned_filter_line = line
    end
  end
  assert(closed_filter_line and assigned_filter_line)
  vim.api.nvim_win_set_cursor(state.win, { closed_filter_line, 0 })
  vim.fn.maparg("<CR>", "n", false, true).callback()
  vim.api.nvim_win_set_cursor(state.win, { assigned_filter_line, 0 })
  vim.fn.maparg("<Space>", "n", false, true).callback()
  local issue_filter_key = "github:neovim/neovim"
  assert(state.opts.project_issue_filters[issue_filter_key].state == "closed")
  assert(state.opts.project_issue_filters[issue_filter_key].assignment
    == "assigned")
  vim.fn.maparg("j", "n", false, true).callback()
  assert(state.view == "activity")
  assert(state.activity_issue_page == true)
  assert(#state.events == 8)
  assert(repository_issue_requests[#repository_issue_requests].state
    == "closed")
  vim.fn.maparg("p", "n", false, true).callback()
  assert(state.activity_page == 2)
  assert(#state.events == 2)
  vim.fn.maparg("j", "n", false, true).callback()
  assert(state.activity_page == 1)
  vim.fn.maparg("j", "n", false, true).callback()
  assert(state.view == "activity")
  assert(state.activity_issue_page == false)
  assert(#state.events == 8)
  assert(vim.deep_equal(
    vim.api.nvim_win_get_cursor(state.win),
    project_cursor
  ))
  local project_past_mapping = vim.fn.maparg("p", "n", false, true)
  local project_older_mapping = vim.fn.maparg("l", "n", false, true)
  local project_older_arrow_mapping =
    vim.fn.maparg("<Right>", "n", false, true)
  project_older_mapping.callback()
  assert(state.activity_commit_page == true)
  vim.fn.maparg("j", "n", false, true).callback()
  assert(state.activity_commit_page == false)
  assert(state.activity_page == 1)
  assert(vim.deep_equal(repository_pages, { 1, 2 }))
  project_older_arrow_mapping.callback()
  assert(state.activity_commit_page == true)
  vim.fn.maparg("j", "n", false, true).callback()
  assert(state.activity_commit_page == false)
  assert(state.activity_page == 1)
  assert(vim.deep_equal(repository_pages, { 1, 2 }))
  deferred_project_request = true
  project_past_mapping.callback()
  assert(state.activity_page == 2)
  assert(#state.events == 8)
  local project_title_line = vim.api.nvim_buf_get_lines(
    state.buf,
    2,
    3,
    false
  )[1]
  assert(project_title_line:find("neovim/neovim", 1, true))
  local project_loading_marks = vim.api.nvim_buf_get_extmarks(
    state.buf,
    activity_page_loading_namespace,
    0,
    -1,
    { details = true }
  )
  assert(#project_loading_marks == 1)
  assert(project_loading_marks[1][2] == 2)
  assert(project_loading_marks[1][4].virt_text[1][1]:match("^ "))
  local pending_project_request = deferred_project_request
  deferred_project_request = nil
  pending_project_request.callback(
    pending_project_request.events,
    nil,
    false
  )
  assert(state.activity_has_past == true)
  assert(vim.deep_equal(repository_pages, { 1, 2, 3 }))
  assert(#vim.api.nvim_buf_get_extmarks(
    state.buf,
    activity_page_loading_namespace,
    0,
    -1,
    {}
  ) == 0)
  project_past_mapping.callback()
  assert(state.activity_page == 2)
  assert(state.activity_has_past == false)
  assert(vim.deep_equal(repository_pages, { 1, 2, 3, 4 }))
  assert(vim.deep_equal(repository_update_pages, { 1 }))
  vim.fn.maparg("<Left>", "n", false, true).callback()
  assert(state.activity_page == 1)
  assert(#state.events == 8)
  assert(vim.deep_equal(repository_pages, { 1, 2, 3, 4 }))
  local ordinary_project_line
  for line, title_line in pairs(state.activity_title_lines) do
    if line == title_line and not state.activity_expansion_targets[line] then
      ordinary_project_line = line
      break
    end
  end
  assert(ordinary_project_line)
  vim.api.nvim_win_set_cursor(state.win, { ordinary_project_line, 0 })
  project_older_mapping.callback()
  assert(state.activity_page == 2)
  assert(vim.deep_equal(repository_pages, { 1, 2, 3, 4 }))
  local refresh_mapping = vim.fn.maparg("r", "n", false, true)
  assert(refresh_mapping.desc == "Refresh Oculus activity")
  refresh_mapping.callback()
  assert(repository_forces[#repository_forces] == true)
  local preserved_project_line
  for line, title_line in pairs(state.activity_title_lines) do
    if line == title_line then
      preserved_project_line = math.max(
        preserved_project_line or line,
        line
      )
    end
  end
  assert(preserved_project_line)
  vim.api.nvim_win_set_cursor(
    state.win,
    { preserved_project_line, 0 }
  )
  vim.api.nvim_win_call(state.win, function()
    vim.fn.winrestview({
      lnum = preserved_project_line,
      col = 0,
      topline = math.max(1, preserved_project_line - 3),
    })
  end)
  local preserved_project_view = vim.api.nvim_win_call(
    state.win,
    vim.fn.winsaveview
  )
  local preserved_project_opts = state.opts
  window.close()
  window.open(preserved_project_opts)
  state = window.state
  assert(state.view == "activity")
  assert(state.activity_project.repository == "neovim/neovim")
  assert(state.activity_page == 2)
  local reopened_project_view = vim.api.nvim_win_call(
    state.win,
    vim.fn.winsaveview
  )
  assert(reopened_project_view.lnum == preserved_project_view.lnum)
  assert(reopened_project_view.col == preserved_project_view.col)
  assert(reopened_project_view.topline == preserved_project_view.topline)
  local project_filter_mapping = vim.fn.maparg("f", "n", false, true)
  project_filter_mapping.callback()
  assert(state.view == "activity")
  assert(state.activity_page == 1)
  vim.fn.maparg("j", "n", false, true).callback()
  assert(state.view == "contributors")
  project_filter_mapping.callback()
  assert(state.view == "filters")
  assert(state.filter_scope.project.repository == "neovim/neovim")
  local project_filter_text = table.concat(
    vim.api.nvim_buf_get_lines(state.buf, 0, -1, false),
    "\n"
  )
  assert(project_filter_text:find("Merged pull requests", 1, true))
  vim.fn.maparg("j", "n", false, true).callback()
  assert(state.view == "contributors")
  window.close()

  local lazy_repository_pages = {}
  local lazy_update_pages = {}
  github.repository_events = function(repository, opts, callback)
    assert(repository == "folke/lazy.nvim")
    lazy_repository_pages[#lazy_repository_pages + 1] = opts.page
    if opts.page == 1 then
      callback({
        {
          id = "lazy-watch",
          type = "WatchEvent",
          repo = { name = repository },
          created_at = "2026-08-03T12:00:00Z",
          payload = { action = "started" },
        },
      }, nil, false)
    else
      callback({}, nil, false)
    end
  end
  github.repository_updates = function(repository, opts, callback)
    assert(repository == "folke/lazy.nvim")
    assert(vim.deep_equal(opts.activity_types, {
      "assigned_issue",
      "merged_pull_request",
      "push",
    }))
    lazy_update_pages[#lazy_update_pages + 1] = opts.page
    local events = {}
    if opts.page == 1 then
      for index = 1, 8 do
        events[#events + 1] = {
          id = "lazy-direct-" .. index,
          type = "PushEvent",
          actor = { login = "folke" },
          repo = { name = repository },
          created_at = ("2026-08-%02dT12:00:00Z"):format(9 - index),
          payload = {
            size = 1,
            head = "lazycommit" .. index,
            commits = {
              {
                sha = "lazycommit" .. index,
                message = "Lazy update " .. index,
              },
            },
          },
        }
      end
    end
    callback(events, nil, false)
  end
  github.enrich_pushes = function(events, _, callback)
    callback(events)
  end
  window.open({
    width = 0.8,
    height = 0.8,
    border = "rounded",
    results_limit = 8,
    projects = {
      {
        name = "lazy.nvim",
        repository = "folke/lazy.nvim",
        provider = "github",
      },
    },
  })
  state = window.state
  for line, target in pairs(state.line_targets) do
    if target.kind == "project" then
      vim.api.nvim_win_set_cursor(state.win, { line, 0 })
      break
    end
  end
  vim.fn.maparg("<CR>", "n", false, true).callback()
  assert(state.activity_project.repository == "folke/lazy.nvim")
  assert(#state.events == 8)
  assert(vim.deep_equal(lazy_repository_pages, { 1 }))
  assert(vim.deep_equal(lazy_update_pages, { 1 }))
  local lazy_activity_text = table.concat(
    vim.api.nvim_buf_get_lines(state.buf, 0, -1, false),
    "\n"
  )
  assert(lazy_activity_text:find(
    "@folke pushed commit",
    1,
    true
  ))
  assert(not lazy_activity_text:find("pushed 1 commit", 1, true))
  assert(lazy_activity_text:find("Lazy update 1", 1, true))
  window.close()
  github.repository_events = original_repository_events
  github.repository_updates = original_repository_updates
  github.repository_issues = original_repository_issues
end
github.events = original_events
github.enrich_pull_requests = original_enrich_pull_requests
github.enrich_pushes = original_enrich_pushes
github.pull_request_commits = original_pull_request_commits
assert(state.search_query == nil)
assert(state.search_win == nil)
assert(state.win == nil)
