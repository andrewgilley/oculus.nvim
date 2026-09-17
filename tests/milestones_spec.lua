local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)
local github = require("oculus.github")
local codeberg = require("oculus.codeberg")
local browser = require("oculus.browser")
local window = require("oculus.window")

local function with_fake_curl(body, run)
  local original_system = vim.system
  local urls = {}

  vim.system = function(command, _, on_exit)
    urls[#urls + 1] = command[#command]
    on_exit({ code = 0, stdout = body .. "\n200", stderr = "" })
    return {}
  end

  local ok, err = pcall(run)
  vim.system = original_system
  assert(ok, err)
  return urls
end

local function wait_for(label, predicate)
  assert(vim.wait(5000, predicate, 10), label)
end

-- JSON nulls decode to vim.NIL, which is truthy. Codeberg sends
-- "pull_request": null for plain issues and GitHub sends "assignee": null for
-- unassigned ones; both must read as absent.
do
  local events

  local urls = with_fake_curl(vim.json.encode({
    {
      number = 3,
      title = "Plain issue",
      state = "open",
      pull_request = vim.NIL,
      assignee = vim.NIL,
      assignees = vim.NIL,
      html_url = "https://codeberg.org/owner/repo/issues/3",
    },
    {
      number = 4,
      title = "A pull request",
      state = "closed",
      pull_request = { merged = true },
      html_url = "https://codeberg.org/owner/repo/pulls/4",
    },
  }), function()
    codeberg.repository_issues("owner/repo", { force = true }, function(result)
      events = result
    end)

    wait_for("codeberg issues did not load", function()
      return events ~= nil
    end)
  end)

  assert(urls[1]:find("/repos/owner/repo/issues?", 1, true))
  assert(#events == 1, #events)
  assert(events[1].payload.issue.assignee == nil)
  assert(vim.deep_equal(events[1].payload.issue.assignees, {}))
  assert(events[1].payload.issue.pull_request == nil)
  local items

  urls = with_fake_curl(vim.json.encode({
    {
      number = 3,
      title = "Plain issue",
      state = "open",
      pull_request = vim.NIL,
      html_url = "https://codeberg.org/owner/repo/issues/3",
    },
    {
      number = 4,
      title = "A pull request",
      state = "closed",
      pull_request = { merged = true, merged_at = "2026-01-01T00:00:00Z" },
      html_url = "https://codeberg.org/owner/repo/pulls/4",
    },
  }), function()
    codeberg.milestone_issues("owner/repo", 97, { force = true }, function(result)
      items = result
    end)

    wait_for("codeberg milestone items did not load", function()
      return items ~= nil
    end)
  end)

  assert(urls[1]:find("milestones=97", 1, true))
  assert(#items == 2)
  assert(items[1].payload.issue.pull_request == nil)
  assert(items[2].payload.issue.pull_request.merged == true)
end

do
  local milestones

  local urls = with_fake_curl(vim.json.encode({
    {
      number = 48,
      title = "0.13",
      state = "open",
      description = vim.NIL,
      open_issues = 79,
      closed_issues = 199,
      due_on = "2026-10-01T00:00:00Z",
      closed_at = vim.NIL,
      html_url = "https://github.com/neovim/neovim/milestone/48",
    },
  }), function()
    github.repository_milestones("neovim/neovim", { force = true }, function(result)
      milestones = result
    end)

    wait_for("github milestones did not load", function()
      return milestones ~= nil
    end)
  end)

  assert(urls[1]:find("/repos/neovim/neovim/milestones?state=all", 1, true))

  assert(vim.deep_equal(milestones, {
    {
      id = 48,
      title = "0.13",
      state = "open",
      open_issues = 79,
      closed_issues = 199,
      due_on = "2026-10-01T00:00:00Z",
      html_url = "https://github.com/neovim/neovim/milestone/48",
    },
  }))

  local assigned_issue

  with_fake_curl(vim.json.encode({
    {
      number = 9,
      title = "Unassigned",
      state = "open",
      assignee = vim.NIL,
      html_url = "https://github.com/neovim/neovim/issues/9",
    },
    {
      number = 10,
      title = "A PR in the issues endpoint",
      state = "open",
      pull_request = { merged_at = vim.NIL },
      html_url = "https://github.com/neovim/neovim/pull/10",
    },
  }), function()
    github.repository_issues("neovim/neovim", { force = true }, function(result)
      assigned_issue = result
    end)

    wait_for("github issues did not load", function()
      return assigned_issue ~= nil
    end)
  end)

  assert(#assigned_issue == 1)
  assert(assigned_issue[1].payload.issue.assignee == nil)
end

local project = {
  name = "Neovim",
  repository = "neovim/neovim",
  provider = "github",
  description = "Vim-fork focused on extensibility and usability.",
}

local originals = {}

for _, name in ipairs({
  "repository_events",
  "repository_updates",
  "repository_issues",
  "repository_milestones",
  "milestone_issues",
  "enrich_pull_requests",
  "enrich_pushes",
}) do
  originals[name] = github[name]
end

local original_browser_open = browser.open
local opened_urls = {}
local milestone_requests = {}
local item_requests = {}

browser.open = function(url)
  opened_urls[#opened_urls + 1] = url
  return true
end

github.repository_events = function(repository, _, callback)
  callback({
    {
      id = "push-1",
      type = "PushEvent",
      repo = { name = repository },
      actor = { login = "project-author" },
      created_at = "2026-07-01T12:00:00Z",
      payload = { size = 1 },
    },
  }, nil, false)
end

github.repository_updates = function(_, _, callback)
  callback({}, nil, false)
end

github.enrich_pull_requests = function(events, _, callback)
  callback(events)
end

github.enrich_pushes = function(events, _, callback)
  callback(events)
end

github.repository_issues = function(repository, _, callback)
  callback({
    {
      id = "issue-1",
      type = "IssuesEvent",
      actor = { login = "reporter" },
      repo = { name = repository },
      created_at = "2026-08-01T12:00:00Z",
      url = "https://github.com/neovim/neovim/issues/1",
      payload = {
        action = "opened",
        issue = {
          number = 1,
          title = "Project issue 1",
          state = "open",
          assignees = {},
          html_url = "https://github.com/neovim/neovim/issues/1",
        },
      },
    },
  }, nil, false, true)
end

local fixture_milestones = {
  {
    id = 61,
    title = "1.0",
    state = "open",
    open_issues = 3,
    closed_issues = 1,
    due_on = "2026-12-31T00:00:00Z",
    html_url = "https://github.com/neovim/neovim/milestone/61",
  },
  {
    id = 6,
    title = "backlog",
    state = "open",
    open_issues = 600,
    closed_issues = 800,
    html_url = "https://github.com/neovim/neovim/milestone/6",
  },
  {
    id = 48,
    title = "0.13",
    state = "open",
    description = "Next minor release.",
    open_issues = 3,
    closed_issues = 1,
    due_on = "2026-10-01T00:00:00Z",
    html_url = "https://github.com/neovim/neovim/milestone/48",
  },
}

for index = 1, 40 do
  fixture_milestones[#fixture_milestones + 1] = {
    id = 1000 + index,
    title = ("0.%d"):format(index),
    state = "closed",
    open_issues = 0,
    closed_issues = index,
    closed_at = ("2025-%02d-01T00:00:00Z"):format((index % 12) + 1),
    html_url = "https://github.com/neovim/neovim/milestone/" .. (1000 + index),
  }
end

github.repository_milestones = function(repository, opts, callback)
  milestone_requests[#milestone_requests + 1] = {
    repository = repository,
    force = opts.force,
  }

  callback(vim.deepcopy(fixture_milestones), nil, false)
end

github.milestone_issues = function(repository, milestone_id, opts, callback)
  item_requests[#item_requests + 1] = {
    repository = repository,
    milestone = milestone_id,
    page = opts.page,
    force = opts.force,
  }

  local events = {}

  for number = 1, 5 do
    local pull_request = number % 2 == 0

    events[#events + 1] = {
      id = "milestone-item-" .. number,
      type = "IssuesEvent",
      actor = { login = "author-" .. number },
      repo = { name = repository },
      created_at = ("2026-08-%02dT12:00:00Z"):format(10 - number),
      url = ("https://github.com/neovim/neovim/%s/%d"):format(
        pull_request and "pull" or "issues",
        number
      ),
      payload = {
        action = "opened",
        issue = {
          number = number,
          title = "Milestone item " .. number,
          state = number == 4 and "closed" or "open",
          assignees = {},
          pull_request = pull_request and { merged = number == 4 } or nil,
        },
      },
    }
  end

  callback(events, nil, false, true)
end

local function buffer_text()
  return table.concat(
    vim.api.nvim_buf_get_lines(window.state.buf, 0, -1, false),
    "\n"
  )
end

local function preview_text()
  local items = {}

  for line = 1, 40 do
    local item = (window.state.preview_items or {})[line]

    if item then
      items[#items + 1] = item[1]
    end
  end

  return table.concat(items, "\n")
end

local function press(lhs)
  local mapping = vim.fn.maparg(lhs, "n", false, true)
  assert(mapping.callback, "no mapping for " .. lhs)
  mapping.callback()
end

local function selected_title()
  local state = window.state
  local target = state.line_targets[vim.api.nvim_win_get_cursor(state.win)[1]]
  return target and target.milestone and target.milestone.title
end

vim.o.columns = 160
vim.o.lines = 50

window.open({
  navigation = "ijkl",
  width = 0.8,
  height = 0.8,
  border = "rounded",
  results_limit = 3,
  projects = { project },
})

local state = window.state

for line, target in pairs(state.line_targets) do
  if target.kind == "project" then
    vim.api.nvim_win_set_cursor(state.win, { line, 0 })
  end
end

press("l")
assert(state.activity_project and not state.activity_issue_page)
press("u")
assert(state.activity_issue_page == true)
local issue_events = state.events

local issue_footer = table.concat(
  vim.api.nvim_buf_get_lines(state.footer_buf, 0, -1, false),
  "\n"
)

assert(issue_footer:find("m milestones", 1, true), issue_footer)
-- The issues page opens the milestone list.
press("m")
assert(state.view == "milestones", state.view)
assert(#milestone_requests == 1)
assert(milestone_requests[1].repository == "neovim/neovim")
local text = buffer_text()
assert(text:find("  MILESTONES", 1, true))
assert(text:find("  neovim/neovim · GitHub", 1, true))
assert(text:find("  OPEN (3)", 1, true))
assert(text:find("back  ⏎ open  b browser  r refresh", 1, true))
assert(not state.footer_win or not vim.api.nvim_win_is_valid(state.footer_win))
-- Open milestones come first, soonest due date first and undated last.
local open_order = {}

for line = 1, vim.api.nvim_buf_line_count(state.buf) do
  local target = state.line_targets[line]

  if target and target.milestone.state == "open" then
    open_order[#open_order + 1] = target.milestone.title
  end
end

assert(vim.deep_equal(open_order, { "0.13", "1.0", "backlog" }))
assert(selected_title() == "0.13")
local preview = preview_text()
assert(preview:find("MILESTONE", 1, true))
assert(preview:find("Open · due 2026-10-01", 1, true))
assert(preview:find("3 open · 1 closed · 25% complete", 1, true))
assert(preview:find("Next minor release.", 1, true))

local selection_marks = vim.api.nvim_buf_get_extmarks(
  state.buf,
  -1,
  { vim.api.nvim_win_get_cursor(state.win)[1] - 1, 0 },
  { vim.api.nvim_win_get_cursor(state.win)[1] - 1, -1 },
  { details = true }
)

local highlighted = false

for _, mark in ipairs(selection_marks) do
  if mark[4].hl_group == "OculusContributorSelected" then
    highlighted = true
  end
end

assert(highlighted, "the selected milestone is not highlighted")
press("k")
assert(selected_title() == "1.0")
assert(preview_text():find("Open · due 2026-12-31", 1, true))
-- The list only renders the rows that fit; moving up from the first
-- milestone wraps to the last closed one and keeps it on screen.
press("i")
assert(selected_title() == "0.13")
press("i")
local last_title = selected_title()
assert(last_title, "wrapped selection is not visible")
assert(state.line_targets[vim.api.nvim_win_get_cursor(state.win)[1]].milestone.state == "closed")
assert(state.milestone_offset > 1)
assert(vim.api.nvim_buf_line_count(state.buf) <= vim.api.nvim_win_get_height(state.win))
assert(preview_text():find("Closed 2025-", 1, true))
press("k")
assert(selected_title() == "0.13")
press("b")
assert(opened_urls[#opened_urls] == "https://github.com/neovim/neovim/milestone/48")
press("r")
assert(#milestone_requests == 2 and milestone_requests[2].force == true)
assert(state.view == "milestones" and selected_title() == "0.13")
-- Selecting a milestone lists its issues and pull requests.
press("l")
assert(state.view == "activity")
assert(state.activity_milestone and state.activity_milestone.id == 48)
assert(item_requests[1].milestone == 48)
assert(#state.events == 3)
text = buffer_text()
assert(text:find("  MILESTONE\n", 1, true))
assert(text:find("  0.13 · neovim/neovim", 1, true), text)
assert(text:find("@author-1 · open issue #1", 1, true), text)
assert(text:find("@author-2 · open pull request #2", 1, true), text)
assert(text:find("Milestone item 3", 1, true))

local item_footer = table.concat(
  vim.api.nvim_buf_get_lines(state.footer_buf, 0, -1, false),
  "\n"
)

assert(not item_footer:find("u issues", 1, true), item_footer)
assert(not item_footer:find("m milestones", 1, true), item_footer)
press("p")
assert(state.activity_page == 2)
assert(#state.events == 2)
text = buffer_text()
assert(text:find("@author-4 · merged pull request #4", 1, true), text)
press("j")
assert(state.activity_page == 1 and state.activity_milestone)
-- Back returns to the milestone list with the same selection, then to the
-- issues page, then to the project feed.
press("j")
assert(state.view == "milestones")
assert(selected_title() == "0.13")
press("j")
assert(state.view == "activity")
assert(state.activity_issue_page == true)
assert(state.activity_milestone == nil)
assert(state.events == issue_events)
press("j")
assert(state.view == "activity")
assert(state.activity_issue_page == false)
assert(state.activity_milestone == nil)
-- Esc also leaves the milestone list.
press("u")
press("m")
assert(state.view == "milestones")
press("<Esc>")
assert(state.view == "activity" and state.activity_issue_page == true)
window.close()
browser.open = original_browser_open

for name, value in pairs(originals) do
  github[name] = value
end

print("milestones_spec: ok")
