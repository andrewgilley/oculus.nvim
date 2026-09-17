local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)
local workspace = vim.fn.tempname()
assert(vim.fn.mkdir(workspace, "p") == 1)
local state_file = vim.fs.joinpath(workspace, "oculus.json")
vim.env.GITHUB_TOKEN = nil
vim.env.CODEBERG_TOKEN = nil
local auth = require("oculus.auth")
local github = require("oculus.github")
local codeberg = require("oculus.codeberg")

local function wait_for(label, predicate)
  assert(vim.wait(5000, predicate, 10), label)
end

-- Replies to each curl call with the next body, recording the URL and the
-- Authorization header sent on stdin.
local function with_fake_curl(bodies, run)
  local original_system = vim.system
  local requests = {}

  vim.system = function(command, options, on_exit)
    requests[#requests + 1] = { url = command[#command], stdin = options and options.stdin }
    local body = bodies[math.min(#requests, #bodies)]
    on_exit({ code = 0, stdout = vim.json.encode(body) .. "\n200", stderr = "" })
    return {}
  end

  local ok, err = pcall(run)
  vim.system = original_system
  assert(ok, err)
  return requests
end

-- Tokens come from the option, then the environment, then gh.
do
  local original_executable = vim.fn.executable
  local original_jobstart = vim.fn.jobstart
  local original_jobwait = vim.fn.jobwait
  local gh_calls = 0

  vim.fn.executable = function(name)
    return name == "gh" and 1 or original_executable(name)
  end

  vim.fn.jobstart = function(command, options)
    assert(command[1] == "gh" and command[2] == "auth" and command[3] == "token")
    gh_calls = gh_calls + 1
    options.on_stdout(1, { "gho_from_gh", "" })
    return 1
  end

  vim.fn.jobwait = function()
    return { 0 }
  end

  auth.reset()
  assert(select(2, auth.github_token({ token = "opt" })) == "option")
  vim.env.GITHUB_TOKEN = "env-token"
  assert(auth.github_token({}) == "env-token")
  vim.env.GITHUB_TOKEN = nil
  assert(auth.github_token({ gh_token_fallback = false }) == nil)
  assert(gh_calls == 0)
  local token, source = auth.github_token({})
  assert(token == "gho_from_gh" and source == "gh", tostring(token))
  auth.github_token({})
  assert(gh_calls == 1, "gh is asked once per session")
  assert(auth.codeberg_token({ codeberg_token = " cb " }) == "cb")
  assert(auth.codeberg_token({}) == nil)
  vim.fn.executable = original_executable
  vim.fn.jobstart = original_jobstart
  vim.fn.jobwait = original_jobwait
  auth.reset()
end

local opts = { token = "secret", gh_token_fallback = false, force = true }

-- The viewer lookup parses the account, shares in-flight requests and caches
-- successes.
do
  local results = {}

  local requests = with_fake_curl({
    { login = "octo", name = vim.NIL, html_url = "https://github.com/octo" },
  }, function()
    auth.viewer("github", opts, function(viewer)
      results[#results + 1] = viewer
    end)

    auth.viewer("github", opts, function(viewer)
      results[#results + 1] = viewer
    end)

    wait_for("viewer did not load", function()
      return #results == 2
    end)

    auth.viewer("github", { token = "secret", gh_token_fallback = false }, function(viewer, _, cached)
      assert(cached)
      results[#results + 1] = viewer
    end)

    wait_for("cached viewer did not load", function()
      return #results == 3
    end)
  end)

  assert(#requests == 1, #requests)
  assert(requests[1].url == "https://api.github.com/user")
  assert(requests[1].stdin:find("Bearer secret", 1, true))
  assert(results[1].login == "octo" and results[1].name == nil)
  assert(results[3].login == "octo")
  assert(auth.cached_viewer("github", opts).login == "octo")
  local err

  auth.viewer("codeberg", { gh_token_fallback = false }, function(viewer, message)
    assert(viewer == nil)
    err = message
  end)

  wait_for("codeberg sign-in error", function()
    return err ~= nil
  end)

  assert(err:find("CODEBERG_TOKEN", 1, true), err)
end

local function search_item(repository, number, title, extra)
  return vim.tbl_extend("force", {
    number = number,
    title = title,
    state = "open",
    user = { login = "author" },
    assignee = vim.NIL,
    updated_at = ("2026-09-%02dT12:00:00Z"):format(number),
    html_url = ("https://github.com/%s/pull/%d"):format(repository, number),
    repository_url = "https://api.github.com/repos/" .. repository,
    pull_request = { merged_at = vim.NIL },
  }, extra or {})
end

-- GitHub work items come from issue search, across repositories.
do
  local events, total, complete

  local requests = with_fake_curl({
    {
      total_count = 2,
      incomplete_results = false,
      items = {
        search_item("a/one", 7, "First"),
        search_item("b/two", 7, "Same number elsewhere"),
      },
    },
  }, function()
    github.work_items("review_requested", opts, function(result, _, _, is_complete, count)
      events, complete, total = result, is_complete, count
    end)

    wait_for("github work items did not load", function()
      return events ~= nil
    end)
  end)

  local url = requests[1].url
  assert(url:find("https://api.github.com/search/issues?q=", 1, true), url)
  assert(url:find("review-requested:@me", 1, true), url)
  assert(url:find("is:pr%20", 1, true), url)
  assert(url:find("sort=updated", 1, true) and url:find("advanced_search=true", 1, true), url)
  assert(#events == 2 and total == 2 and complete == true)
  assert(events[1].repo.name == "a/one" and events[2].repo.name == "b/two")
  assert(events[1].id ~= events[2].id)
  assert(events[2].payload.issue.pull_request.merged == false)
  local err

  github.work_items("nonsense", opts, function(result, message)
    assert(result == nil)
    err = message
  end)

  wait_for("unknown category error", function()
    return err ~= nil
  end)

  err = nil

  github.work_items("assigned", { gh_token_fallback = false }, function(result, message)
    assert(result == nil)
    err = message
  end)

  wait_for("github sign-in error", function()
    return err ~= nil
  end)

  assert(err:find("gh auth login", 1, true), err)
end

-- Codeberg work items come from the repository issue search.
do
  local events, total

  local requests = with_fake_curl({
    {
      {
        number = 3,
        title = "Codeberg PR",
        state = "open",
        updated_at = "2026-09-01T00:00:00Z",
        html_url = "https://codeberg.org/forgejo/forgejo/pulls/3",
        repository = { full_name = "forgejo/forgejo" },
        pull_request = { merged = false },
      },
      { number = 4, title = "No repository" },
    },
  }, function()
    codeberg.work_items(
      "review_requested",
      { codeberg_token = "cb", force = true },
      function(result, _, _, _, count)
        events, total = result, count
      end
    )

    wait_for("codeberg work items did not load", function()
      return events ~= nil
    end)
  end)

  assert(requests[1].url:find(
    "/api/v1/repos/issues/search?state=open&type=pulls&review_requested=true",
    1,
    true
  ), requests[1].url)

  assert(requests[1].stdin:find("token cb", 1, true))
  assert(#events == 1 and events[1].repo.name == "forgejo/forgejo" and total == nil)
end

-- The My work view.
local window = require("oculus.window")
local browser = require("oculus.browser")
local original_viewer = github.viewer
local original_work_items = github.work_items
local original_browser_open = browser.open
local work_requests = {}
local opened_urls = {}

github.viewer = function(_, callback)
  callback({ provider = "github", login = "octo", name = "Octo Cat" })
end

local review_items = {}

for index, repository in ipairs({ "a/one", "b/two", "c/three" }) do
  review_items[index] = {
    id = ("project-issue:%s:7"):format(repository),
    type = "IssuesEvent",
    actor = { login = "author" },
    repo = { name = repository },
    created_at = ("2026-09-0%dT12:00:00Z"):format(4 - index),
    url = ("https://github.com/%s/pull/7"):format(repository),
    payload = {
      action = "opened",
      issue = {
        number = 7,
        title = "Review " .. repository,
        state = "open",
        assignees = {},
        pull_request = { merged = false },
        html_url = ("https://github.com/%s/pull/7"):format(repository),
      },
    },
  }
end

github.work_items = function(category, request_opts, callback)
  work_requests[#work_requests + 1] = { category = category, page = request_opts.page }

  if category == "review_requested" then
    callback(vim.deepcopy(review_items), nil, false, true, 3)
  elseif category == "mentioned" then
    callback(nil, "GitHub: Validation Failed")
  else
    callback({}, nil, false, true, 0)
  end
end

browser.open = function(url)
  opened_urls[#opened_urls + 1] = url
  return true
end

local function press(lhs)
  local mapping = vim.fn.maparg(lhs, "n", false, true)
  assert(mapping.callback, "no mapping for " .. lhs)
  mapping.callback()
end

local state

local function buffer_text()
  return table.concat(vim.api.nvim_buf_get_lines(state.buf, 0, -1, false), "\n")
end

local function preview_text()
  local parts = {}

  for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(state.buf, -1, 0, -1, { details = true })) do
    local text = mark[4].virt_text

    if text and text[2] then
      parts[#parts + 1] = text[2][1]
    end
  end

  return table.concat(parts, "\n")
end

vim.o.columns = 160
vim.o.lines = 50

window.open({
  width = 0.8,
  height = 0.8,
  border = "rounded",
  results_limit = 2,
  state_file = state_file,
  token = "secret",
  gh_token_fallback = false,
  projects = {},
  contributors = {},
})

state = window.state
assert(buffer_text():find("w work", 1, true))
-- The signed-in accounts appear only in the sidebar, never on the list.
press("?")
assert(window._is_sidebar_visible())

wait_for("signed-in account not shown", function()
  local sidebar_lines = vim.api.nvim_buf_get_lines(state.sidebar_buf, 0, -1, false)

  return sidebar_lines[#sidebar_lines - 1] == "  SIGNED IN AS"
    and sidebar_lines[#sidebar_lines] == "  GitHub: @octo"
end)

local function list_mentions_account()
  if buffer_text():find("@octo", 1, true) then
    return true
  end

  for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(state.buf, -1, 0, -1, { details = true })) do
    for _, chunk in ipairs(mark[4].virt_text or {}) do
      if chunk[1]:find("@octo", 1, true) then
        return true
      end
    end
  end
end

assert(not list_mentions_account())
press("?")
assert(not window._is_sidebar_visible())
assert(not list_mentions_account())
press("w")
assert(state.view == "work", state.view)
local text = buffer_text()
assert(text:find("MY WORK", 1, true))
assert(text:find("GITHUB · @octo", 1, true), text)
assert(text:find("Review requests%s+3"), text)
assert(text:find("Your pull requests%s+0"), text)
assert(text:find("Mentions%s+!"), text)
assert(not text:find("CODEBERG", 1, true), "Codeberg is hidden when unused")
assert(#work_requests == 4)
assert(state.selected_work == "github:review_requested")
local preview = preview_text()
assert(preview:find("@octo on GitHub", 1, true), preview)
assert(preview:find("a/one#7 Review a/one", 1, true), preview)
press("b")
assert(opened_urls[1] == "https://github.com/pulls/review-requested")
press("?")
assert(state.view == "work" and window._is_sidebar_visible())
assert(buffer_text():find("Review requests", 1, true))
press("?")
assert(state.view == "work" and not window._is_sidebar_visible())
-- The selection wraps and the preview follows it.
press("i")
assert(state.selected_work == "github:mentioned")
assert(preview_text():find("Validation Failed", 1, true))
press("k")
assert(state.selected_work == "github:review_requested")
-- Opening a category shows its items as a feed across repositories.
press("<CR>")
assert(state.view == "activity" and state.activity_work.key == "github:review_requested")
text = buffer_text()
assert(text:find("Review requests · @octo · GitHub", 1, true), text)
assert(text:find("open pull request #7 in a/one", 1, true), text)
assert(text:find("open pull request #7 in b/two", 1, true), text)
assert(not text:find("c/three", 1, true), "results_limit pages the feed")
press("p")
assert(state.activity_page == 2)
assert(buffer_text():find("open pull request #7 in c/three", 1, true))
assert(buffer_text():find("GitHub (2/2)", 1, true), buffer_text())
press("f")
assert(state.activity_page == 1)
-- Saving remembers each item's own repository.
local store = require("oculus.saved")
store.load({})
local second_line

for line, title in pairs(state.activity_title_lines) do
  if line == title and state.activity_events[line].repo.name == "b/two" then
    second_line = line
  end
end

vim.api.nvim_win_set_cursor(state.win, { second_line, 0 })
press("s")
assert(store.items()[1].source.repository == "b/two", vim.inspect(store.items()[1]))
assert(store.items()[1].source.provider == "github")
store.load({})
-- Closing and reopening restores the feed; back returns to the list, then to
-- the start screen.
window.close()
window.open(state.opts)
state = window.state
assert(state.view == "activity" and state.activity_work, state.view)
assert(buffer_text():find("in a/one", 1, true))
press("j")
assert(state.view == "work" and state.selected_work == "github:review_requested")
press("j")
assert(state.view == "contributors", state.view)
-- A Codeberg project without a token shows a sign-in hint instead of rows.
state.opts.projects = { { repository = "forgejo/forgejo", provider = "codeberg" } }
press("w")
text = buffer_text()
assert(text:find("CODEBERG", 1, true), text)
assert(text:find("Not signed in: set $CODEBERG_TOKEN", 1, true), text)
press("r")
assert(state.view == "work")
window.close()
-- @me opens the signed-in account's own feed.
local original_events = github.events

github.events = function(username, _, callback)
  callback({}, nil, false, nil, true)
  assert(username == "octo")
end

window.open_user("@me", state.opts)

wait_for("@me did not resolve", function()
  return state.contributor ~= nil
end)

assert(state.contributor.username == "octo" and state.contributor.provider == "github")
window.close()
github.events = original_events
github.viewer = original_viewer
github.work_items = original_work_items
browser.open = original_browser_open
assert(vim.fn.delete(workspace, "rf") == 0)
print("work_spec: ok")
