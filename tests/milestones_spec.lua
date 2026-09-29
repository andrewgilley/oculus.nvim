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
  -- The pulls endpoint lists pull requests themselves, which read as issue
  -- events marked as pull requests.
  local pulls

  urls = with_fake_curl(vim.json.encode({
    {
      number = 11,
      title = "Draft change",
      state = "open",
      draft = true,
      merged_at = vim.NIL,
      assignee = vim.NIL,
      html_url = "https://github.com/neovim/neovim/pull/11",
    },
    {
      number = 12,
      title = "Merged change",
      state = "closed",
      merged_at = "2026-08-01T00:00:00Z",
      html_url = "https://github.com/neovim/neovim/pull/12",
    },
  }), function()
    github.repository_pulls("neovim/neovim", { force = true, issue_state = "all" }, function(result)
      pulls = result
    end)

    wait_for("github pull requests did not load", function()
      return pulls ~= nil
    end)
  end)

  assert(urls[1]:find("/repos/neovim/neovim/pulls?state=all&sort=updated", 1, true), urls[1])
  assert(#pulls == 2)
  assert(pulls[1].payload.issue.pull_request.draft == true)
  assert(pulls[1].payload.issue.pull_request.merged == false)
  assert(pulls[2].payload.issue.pull_request.merged == true)
  assert(pulls[2].url == "https://github.com/neovim/neovim/pull/12")
  pulls = nil

  urls = with_fake_curl(vim.json.encode({
    {
      number = 4,
      title = "A pull request",
      state = "open",
      pull_request = { merged = false, draft = true },
      html_url = "https://codeberg.org/owner/repo/pulls/4",
    },
  }), function()
    codeberg.repository_pulls("owner/repo", { force = true }, function(result)
      pulls = result
    end)

    wait_for("codeberg pull requests did not load", function()
      return pulls ~= nil
    end)
  end)

  assert(urls[1]:find("type=pulls", 1, true), urls[1])
  assert(#pulls == 1 and pulls[1].payload.issue.pull_request.draft == true)
  -- Directory listings put directories first, and paths are encoded.
  local entries

  urls = with_fake_curl(vim.json.encode({
    { name = "README.md", path = "src/README.md", type = "file", size = 2048, html_url = "https://github.com/neovim/neovim/blob/master/src/README.md" },
    { name = "nvim", path = "src/nvim", type = "dir", size = 0, html_url = "https://github.com/neovim/neovim/tree/master/src/nvim" },
    { name = "a b.txt", path = "src/a b.txt", type = "file", size = 1 },
  }), function()
    github.repository_contents("neovim/neovim", "/src/", { force = true }, function(result)
      entries = result
    end)

    wait_for("github contents did not load", function()
      return entries ~= nil
    end)
  end)

  assert(urls[1]:find("/repos/neovim/neovim/contents/src", 1, true), urls[1])
  assert(vim.deep_equal(vim.tbl_map(function(entry) return entry.name end, entries), { "nvim", "a b.txt", "README.md" }))
  assert(entries[1].type == "dir" and entries[3].size == 2048)
  entries = nil

  urls = with_fake_curl(vim.json.encode({ { name = "x y", path = "docs/x y", type = "dir" } }), function()
    codeberg.repository_contents("owner/repo", "docs/x y", { force = true }, function(result)
      entries = result
    end)

    wait_for("codeberg contents did not load", function()
      return entries ~= nil
    end)
  end)

  assert(urls[1]:find("/api/v1/repos/owner/repo/contents/docs/x%20y", 1, true), urls[1])
  assert(#entries == 1 and entries[1].type == "dir")
  -- Discussions come from GraphQL and read as discussion events.
  local discussions

  urls = with_fake_curl(vim.json.encode({
    data = {
      repository = {
        hasDiscussionsEnabled = true,
        discussions = {
          pageInfo = { hasNextPage = false, endCursor = vim.NIL },
          nodes = {
            {
              number = 5,
              title = "How do I configure this?",
              url = "https://github.com/neovim/neovim/discussions/5",
              closed = false,
              answerChosenAt = "2026-08-02T00:00:00Z",
              createdAt = "2026-08-01T00:00:00Z",
              updatedAt = "2026-08-03T00:00:00Z",
              author = { login = "asker" },
              category = { name = "Q&A" },
              comments = { totalCount = 2 },
            },
          },
        },
      },
    },
  }), function()
    github.repository_discussions("neovim/neovim", { force = true, token = "test-token" }, function(result, err)
      discussions = result or err
    end)

    wait_for("github discussions did not load", function()
      return discussions ~= nil
    end)
  end)

  assert(urls[1] == "https://api.github.com/graphql", urls[1])
  assert(type(discussions) == "table" and #discussions == 1, vim.inspect(discussions))
  assert(discussions[1].type == "DiscussionEvent")
  assert(discussions[1].oculus_text == "@asker · answered discussion #5 in Q&A · 2 comments", discussions[1].oculus_text)
  assert(discussions[1].url == "https://github.com/neovim/neovim/discussions/5")
  local disabled

  with_fake_curl(vim.json.encode({ data = { repository = { hasDiscussionsEnabled = false } } }), function()
    github.repository_discussions("owner/quiet", { force = true, token = "test-token" }, function(result, _, _, complete, notice)
      disabled = { result = result, complete = complete, notice = notice }
    end)

    wait_for("disabled discussions did not load", function()
      return disabled ~= nil
    end)
  end)

  assert(#disabled.result == 0 and disabled.complete == true)
  assert(disabled.notice == "Discussions are turned off for this repository.")
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
  "repository_pulls",
  "repository_discussions",
  "repository_contents",
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

local pull_requests = {}

github.repository_pulls = function(repository, opts, callback)
  pull_requests[#pull_requests + 1] = { repository = repository, state = opts.issue_state }

  callback({
    {
      id = "project-issue:neovim/neovim:7",
      type = "IssuesEvent",
      actor = { login = "contributor" },
      repo = { name = repository },
      created_at = "2026-08-02T12:00:00Z",
      url = "https://github.com/neovim/neovim/pull/7",
      payload = {
        action = "opened",
        issue = {
          number = 7,
          title = "Project pull request 7",
          state = "open",
          assignees = {},
          pull_request = { merged = false, draft = true },
        },
      },
    },
  }, nil, false, true)
end

github.repository_discussions = function(repository, _, callback)
  callback({
    {
      id = "project-discussion:neovim/neovim:5",
      type = "DiscussionEvent",
      actor = { login = "asker" },
      repo = { name = repository },
      created_at = "2026-08-03T12:00:00Z",
      url = "https://github.com/neovim/neovim/discussions/5",
      oculus_text = "@asker · discussion #5 in Q&A",
      oculus_detail = "How do I configure this?",
      payload = { action = "open", discussion = { number = 5 } },
    },
  }, nil, false, true)
end

local content_requests = {}

github.repository_contents = function(repository, path, opts, callback)
  content_requests[#content_requests + 1] = { repository = repository, path = path, force = opts.force }

  local listings = {
    [""] = {
      { name = "src", path = "src", type = "dir", html_url = "https://github.com/neovim/neovim/tree/master/src" },
      { name = "README.md", path = "README.md", type = "file", size = 4096, html_url = "https://github.com/neovim/neovim/blob/master/README.md" },
    },
    src = {
      { name = "nvim", path = "src/nvim", type = "dir" },
      { name = "main.c", path = "src/main.c", type = "file", size = 10 },
    },
  }

  callback(vim.deepcopy(listings[path] or {}), nil, false)
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
  navigation = {
    up = "i",
    down = "k",
    left = "j",
    right = "l",
    inspect = "h",
    inspect_id = "H",
  },
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

-- A project opens on its issues tab.
press("l")
assert(state.activity_project and state.activity_issue_page == true)
assert(state.activity_issue_kind == "issues")

local function footer_text()
  return table.concat(vim.api.nvim_buf_get_lines(state.footer_buf, 0, -1, false), "\n")
end

local function tab_bar()
  return vim.api.nvim_buf_get_lines(state.buf, 1, 2, false)[1]
end

local function active_tab()
  local line = tab_bar()

  for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(state.buf, -1, { 1, 0 }, { 1, -1 }, { details = true })) do
    if mark[4].hl_group == "OculusTabActive" then
      return line:sub(mark[3] + 1, mark[4].end_col)
    end
  end
end

assert(tab_bar() == "  Code   Issues   Pull requests   Discussions   Activity   Milestones", tab_bar())
assert(active_tab() == "Issues", active_tab())
assert(buffer_text():find("Project issue 1", 1, true))
assert(footer_text():find("⇥ tabs", 1, true), footer_text())
assert(footer_text():find("f filters", 1, true), footer_text())
assert(not footer_text():find("m milestones", 1, true), footer_text())
assert(vim.fn.maparg("m", "n", false, true).desc == "Move selected Oculus project or user")
press("?")
local issue_shortcuts = buffer_text()
assert(issue_shortcuts:find("Show the next or previous project tab", 1, true), issue_shortcuts)
assert(issue_shortcuts:find("Filter issues", 1, true), issue_shortcuts)
press("?")
-- <Tab> moves to the pull requests, which filter apart from the issues.
press("<Tab>")
assert(state.view == "activity" and state.activity_issue_kind == "pulls")
assert(active_tab() == "Pull requests", active_tab())
assert(#pull_requests == 1 and pull_requests[1].state == "open")
assert(buffer_text():find("@contributor · draft pull request #7", 1, true), buffer_text())
press("f")
assert(state.view == "issue_filters")
assert(buffer_text():find("PULL REQUEST FILTERS", 1, true))
assert(buffer_text():find("Closed pull requests", 1, true))

for line, target in pairs(state.line_targets) do
  if target.dimension == "state" and target.value == "closed" then
    vim.api.nvim_win_set_cursor(state.win, { line, 0 })
  end
end

press("<Space>")
assert(state.opts.project_issue_filters["github:neovim/neovim:pulls"].state == "closed")
assert(state.opts.project_issue_filters["github:neovim/neovim"].state == "open")
press("j")
assert(state.view == "activity" and state.activity_issue_kind == "pulls")
assert(pull_requests[#pull_requests].state == "closed")
-- Then the discussions, which have no filters.
press("<Tab>")
assert(state.view == "activity" and state.activity_issue_kind == "discussions")
assert(active_tab() == "Discussions", active_tab())
assert(buffer_text():find("@asker · discussion #5 in Q&A", 1, true), buffer_text())
assert(buffer_text():find("How do I configure this?", 1, true), buffer_text())
assert(not footer_text():find("f filters", 1, true), footer_text())
press("f")
assert(state.view == "activity" and state.activity_issue_kind == "discussions")
-- Then the activity feed, then the milestones.
press("<Tab>")
assert(state.view == "activity" and not state.activity_issue_page)
assert(active_tab() == "Activity", active_tab())
assert(buffer_text():find("pushed", 1, true), buffer_text())
press("<Tab>")
assert(state.view == "milestones", state.view)
assert(active_tab() == "Milestones", active_tab())
assert(#milestone_requests == 1)
assert(milestone_requests[1].repository == "neovim/neovim")
local text = buffer_text()
assert(text:find("  neovim/neovim · GitHub", 1, true))
assert(text:find("  OPEN (3)", 1, true))
assert(text:find("back   ⇥ tabs   ⏎ open   b browser", 1, true), text)
press("?")
local ms_shortcuts = buffer_text()
assert(ms_shortcuts:find("Open the selected milestone", 1, true), ms_shortcuts)
assert(ms_shortcuts:find("Show the next or previous project tab", 1, true), ms_shortcuts)
press("?")
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
assert(active_tab() == "Milestones", active_tab())
assert(text:find("  0.13 · neovim/neovim", 1, true), text)
assert(text:find("@author-1 · open issue #1", 1, true), text)
assert(text:find("@author-2 · open pull request #2", 1, true), text)
assert(text:find("Milestone item 3", 1, true))
assert(not footer_text():find("f filters", 1, true), footer_text())
press("p")
assert(state.activity_page == 2)
assert(#state.events == 2)
text = buffer_text()
assert(text:find("@author-4 · merged pull request #4", 1, true), text)
press("j")
assert(state.activity_page == 1 and state.activity_milestone)
-- Back returns to the milestone list with the same selection, then to the
-- project list.
press("j")
assert(state.view == "milestones")
assert(selected_title() == "0.13")
press("j")
assert(state.view == "contributors", state.view)
-- <S-Tab> goes back to the code, which lists the root directory.
press("l")
assert(state.activity_issue_kind == "issues")
press("<S-Tab>")
assert(state.view == "code", state.view)
assert(active_tab() == "Code", active_tab())
assert(content_requests[#content_requests].path == "")
text = buffer_text()
assert(text:find("  src/", 1, true), text)
assert(text:find("  README.md", 1, true), text)
assert(text:find("up   ⇥ tabs   ⏎ open", 1, true), text)
assert(state.line_targets[vim.api.nvim_win_get_cursor(state.win)[1]].entry.name == "src")
assert(preview_text():find("DIRECTORY", 1, true), preview_text())
press("k")
assert(state.line_targets[vim.api.nvim_win_get_cursor(state.win)[1]].entry.name == "README.md")
assert(preview_text():find("4.0 KB", 1, true), preview_text())
press("b")
assert(opened_urls[#opened_urls] == "https://github.com/neovim/neovim/blob/master/README.md")
-- Files have nothing to open in place; directories open in the list.
press("l")
assert(state.view == "code" and state.project_code.path == "")
press("i")
press("l")
assert(state.project_code.path == "src")
text = buffer_text()
assert(text:find("  ..", 1, true) and text:find("  nvim/", 1, true) and text:find("  main.c", 1, true), text)
assert(text:find("/src", 1, true), text)
press("r")
assert(content_requests[#content_requests].force == true and state.project_code.path == "src")
-- Leaving and coming back keeps the directory.
press("<Tab>")
press("<S-Tab>")
assert(state.view == "code" and state.project_code.path == "src")
-- Left climbs to the parent, selecting the directory just left, then leaves.
press("j")
assert(state.project_code.path == "")
assert(state.line_targets[vim.api.nvim_win_get_cursor(state.win)[1]].entry.name == "src")
press("l")
press("l")
assert(state.project_code.path == "")
press("j")
assert(state.view == "contributors", state.view)
-- <S-Tab> wraps from the first tab to the last.
press("l")
press("<S-Tab>")
press("<S-Tab>")
assert(state.view == "milestones")
press("<S-Tab>")
assert(state.view == "activity" and not state.activity_issue_page)
press("<Tab>")
assert(state.view == "milestones")
press("<Tab>")
assert(state.view == "code")
press("<S-Tab>")
assert(state.view == "milestones")
-- Esc also leaves the milestone list.
press("<Esc>")
assert(state.view == "contributors", state.view)
window.close()
browser.open = original_browser_open

for name, value in pairs(originals) do
  github[name] = value
end

print("milestones_spec: ok")
