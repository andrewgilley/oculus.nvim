local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)
local workspace = vim.fn.tempname()
assert(vim.fn.mkdir(workspace, "p") == 1)
local state_file = vim.fs.joinpath(workspace, "oculus.json")

local function read_state()
  return require("oculus.storage").load(state_file) or {}
end

local function fresh_store()
  package.loaded["oculus.saved"] = nil
  return require("oculus.saved")
end

-- The store keeps one entry per key, newest first.
do
  local store = fresh_store()
  assert(not store.loaded())

  store.load({
    { key = "a", event = { id = 1 } },
    { key = "broken" },
    "not an entry",
    { key = "b", event = { id = 2 } },
  })

  assert(store.loaded())
  assert(#store.items() == 2)
  store.add({ key = "b", event = { id = 2 } })
  assert(store.items()[1].key == "b" and #store.items() == 2)
  assert(store.remove("a") and not store.remove("a"))
  assert(#store.items() == 1)
end

-- State writes take saved items from the store, not from the (possibly stale)
-- config they were handed, and never wipe items before the store has loaded.
do
  local storage = require("oculus.storage")

  assert(vim.fn.writefile({ vim.json.encode({
    saved_items = { { key = "disk", event = { id = "disk" } } },
  }) }, state_file) == 0)

  fresh_store()
  assert(storage.save(state_file, { saved_items = {} }))
  assert(read_state().saved_items[1].key == "disk")
  local store = fresh_store()
  store.load(read_state().saved_items)
  store.add({ key = "newer", event = { id = "newer" } })
  local stale_config = { saved_items = { { key = "stale", event = {} } } }
  assert(storage.save(state_file, stale_config))
  local keys = vim.tbl_map(function(entry) return entry.key end, read_state().saved_items)
  assert(vim.deep_equal(keys, { "newer", "disk" }), vim.inspect(keys))
end

-- setup() loads saved items from the state file.
do
  local store = fresh_store()
  require("oculus").setup({ state_file = state_file, projects = {}, contributors = {} })
  assert(store.loaded())
  assert(#store.items() == 2 and store.items()[1].key == "newer")
  store.load({})
  assert(require("oculus.storage").save(state_file, {}))
end

local github = require("oculus.github")
local codeberg = require("oculus.codeberg")
local window = require("oculus.window")
local store = require("oculus.saved")
local originals = {}

for _, provider in ipairs({ github, codeberg }) do
  originals[provider] = {}

  for _, name in ipairs({
    "repository_issues",
    "repository_pulls",
    "repository_discussions",
    "enrich_pull_requests",
    "enrich_pushes",
    "pull_request_commits",
  }) do
    originals[provider][name] = provider[name]
  end

  provider.repository_issues = function(_, _, callback)
    callback({}, nil, false, true)
  end

  provider.repository_pulls = function(_, _, callback)
    callback({}, nil, false, true)
  end

  provider.repository_discussions = function(_, _, callback)
    callback({}, nil, false, true)
  end

  provider.enrich_pull_requests = function(events, _, callback)
    callback(events)
  end

  provider.enrich_pushes = function(events, _, callback)
    callback(events)
  end
end

local function project_issue(repository, number, title, url, pull_request)
  return {
    id = ("project-issue:%s:%d"):format(repository, number),
    type = "IssuesEvent",
    actor = { login = "reporter" },
    repo = { name = repository },
    created_at = ("2026-08-%02dT12:00:00Z"):format(number),
    url = url,
    payload = {
      action = "opened",
      issue = {
        number = number,
        title = title,
        state = "open",
        assignees = {},
        html_url = url,
        pull_request = pull_request,
      },
    },
  }
end

github.repository_issues = function(repository, _, callback)
  callback({
    project_issue(repository, 6, "Second issue", "https://github.com/neovim/neovim/issues/6"),
    project_issue(repository, 5, "Saved issue", "https://github.com/neovim/neovim/issues/5"),
  }, nil, false, true)
end

github.repository_pulls = function(repository, _, callback)
  callback({
    project_issue(repository, 12, "Refine defaults", "https://github.com/neovim/neovim/pull/12", { merged = false }),
  }, nil, false, true)
end

github.repository_discussions = function(repository, _, callback)
  callback({
    {
      id = "project-discussion:neovim/neovim:3",
      type = "DiscussionEvent",
      actor = { login = "asker" },
      repo = { name = repository },
      created_at = "2026-08-03T12:00:00Z",
      url = "https://github.com/neovim/neovim/discussions/3",
      oculus_text = "@asker · discussion #3 in Q&A",
      oculus_detail = "How do I start?",
      payload = { action = "open", discussion = { number = 3 } },
    },
  }, nil, false, true)
end

codeberg.repository_issues = function(repository, _, callback)
  callback({
    project_issue(repository, 1, "Codeberg issue", "https://codeberg.org/forgejo/forgejo/issues/1"),
  }, nil, false, true)
end

-- Saved Codeberg pushes and pull requests keep their provider in the saved
-- feed; these come from a user feed in practice.
local codeberg_saved = {
  {
    id = "cb-pr",
    type = "PullRequestEvent",
    repo = { name = "forgejo/forgejo" },
    url = "https://codeberg.org/forgejo/forgejo/pulls/42",
    actor = { login = "merger" },
    created_at = "2026-07-03T12:00:00Z",
    payload = {
      action = "merged",
      number = 42,
      pull_request = { number = 42, title = "Codeberg change", html_url = "https://codeberg.org/forgejo/forgejo/pulls/42" },
    },
  },
  {
    id = "cb-push",
    type = "PushEvent",
    repo = { name = "forgejo/forgejo" },
    url = "https://codeberg.org/forgejo/forgejo/compare/abc...def456",
    actor = { login = "pusher" },
    created_at = "2026-07-02T12:00:00Z",
    payload = {
      size = 2,
      head = "def456",
      commits = {
        { sha = "c0ffee1", message = "First" },
        { sha = "c0ffee2", message = "Second" },
      },
    },
  },
}

local commit_requests = {}

codeberg.pull_request_commits = function(repo, number, _, callback)
  commit_requests[#commit_requests + 1] = { provider = "codeberg", repo = repo, number = number }
  callback({ { sha = "feedbee", commit = { message = "PR commit" } } })
end

github.pull_request_commits = function(repo, number, _, callback)
  commit_requests[#commit_requests + 1] = { provider = "github", repo = repo, number = number }
  callback({})
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

local function shortcuts_text()
  press("?")
  local text = buffer_text()
  press("?")
  return text
end

local function title_lines()
  local lines = {}

  for line, title in pairs(state.activity_title_lines) do
    if line == title then
      lines[#lines + 1] = line
    end
  end

  table.sort(lines)
  return lines
end

local function starred(line)
  local marks = vim.api.nvim_buf_get_extmarks(
    state.buf,
    -1,
    { line - 1, 0 },
    { line - 1, -1 },
    { details = true }
  )

  for _, mark in ipairs(marks) do
    local text = mark[4].virt_text

    if text and text[1] and text[1][1] == "★" then
      return true
    end
  end

  return false
end

local function open_project(repository)
  for _ = 1, 4 do
    if state.view == "contributors" then
      break
    end

    press("j")
  end

  assert(state.view == "contributors", state.view)

  for line, target in pairs(state.line_targets) do
    if target.kind == "project" and target.project.repository == repository then
      vim.api.nvim_win_set_cursor(state.win, { line, 0 })
    end
  end

  -- Projects open on their issues.
  press("l")
  assert(state.activity_project.repository == repository)
  assert(state.view == "activity" and state.activity_issue_kind == "issues")
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
  results_limit = 2,
  state_file = state_file,
  projects = {
    { name = "Neovim", repository = "neovim/neovim", provider = "github" },
    { name = "Forgejo", repository = "forgejo/forgejo", provider = "codeberg" },
  },
})

state = window.state
assert(buffer_text():find("s saved", 1, true))
assert(shortcuts_text():find("Open saved activity items", 1, true))
open_project("neovim/neovim")
assert(shortcuts_text():find("Save activity item", 1, true))
local lines = title_lines()
vim.api.nvim_win_set_cursor(state.win, { lines[2], 0 })
press("s")
assert(#store.items() == 1)
assert(store.items()[1].source.kind == "project")
assert(store.items()[1].source.repository == "neovim/neovim")
assert(store.items()[1].event.id == "project-issue:neovim/neovim:5")
assert(starred(lines[2]) and not starred(lines[1]))
assert(read_state().saved_items[1].event.id == "project-issue:neovim/neovim:5")
-- Saving toggles.
press("s")
assert(#store.items() == 0 and not starred(lines[2]))
press("s")
vim.api.nvim_win_set_cursor(state.win, { lines[1], 0 })
press("s")
assert(#store.items() == 2 and store.items()[1].event.id == "project-issue:neovim/neovim:6")
-- Pull requests and discussions save from their tabs too.
press("<Tab>")
assert(state.activity_issue_kind == "pulls")
vim.api.nvim_win_set_cursor(state.win, { title_lines()[1], 0 })
press("s")
assert(store.items()[1].event.id == "project-issue:neovim/neovim:12")
press("<Tab>")
assert(state.activity_issue_kind == "discussions")
vim.api.nvim_win_set_cursor(state.win, { title_lines()[1], 0 })
press("s")
assert(store.items()[1].event.id == "project-discussion:neovim/neovim:3")
assert(starred(title_lines()[1]))
open_project("forgejo/forgejo")
vim.api.nvim_win_set_cursor(state.win, { title_lines()[1], 0 })
press("s")
assert(#store.items() == 5)
assert(store.items()[1].source.provider == "codeberg")
assert(#read_state().saved_items == 5)

for _, event in ipairs(codeberg_saved) do
  store.add({
    key = "codeberg:" .. event.id,
    saved_at = "2026-08-04T12:00:00Z",
    source = { kind = "project", provider = "codeberg", repository = "forgejo/forgejo" },
    event = vim.deepcopy(event),
  })
end

-- The start screen opens the saved feed.
press("j")
assert(state.view == "contributors")
press("s")
assert(state.view == "activity" and state.activity_saved)
local text = buffer_text()
assert(text:find("  SAVED\n", 1, true), text)
assert(text:find("7 saved items (1/4)", 1, true), text)
assert(#state.events == 2)
assert(shortcuts_text():find("Unsave activity item", 1, true))

for _, line in ipairs(title_lines()) do
  assert(starred(line), "saved item is not starred")
end

-- A saved Codeberg push keeps Codeberg commit links without a Codeberg feed
-- open, and a saved Codeberg PR expands through the Codeberg client.
local push_detail_url

for line, target in pairs(state.line_targets) do
  if type(target) == "string" and target:find("c0ffee1", 1, true) then
    push_detail_url = target
  end
end

assert(push_detail_url and push_detail_url:find("^https://codeberg%.org/"), tostring(push_detail_url))
local pr_line

for _, line in ipairs(title_lines()) do
  local entry = state.saved_entries[state.activity_events[line]]

  if entry.event.id == "cb-pr" then
    pr_line = line
  end

  assert(state.line_targets[line]:find("^https://codeberg%.org/"), state.line_targets[line])
end

assert(pr_line, "the saved Codeberg PR is not on the first page")
vim.api.nvim_win_set_cursor(state.win, { pr_line, 0 })
press("l")
assert(commit_requests[#commit_requests].provider == "codeberg")
assert(commit_requests[#commit_requests].repo == "forgejo/forgejo")
assert(state.activity_commit_page)
press("j")
assert(state.activity_saved and not state.activity_commit_page)
press("p")
assert(state.activity_page == 2)
text = buffer_text()
assert(text:find("open issue #1 in forgejo/forgejo", 1, true), text)
assert(text:find("@asker · discussion #3 in Q&A", 1, true), text)
press("p")
press("p")
assert(state.activity_page == 4 and #state.events == 1)
text = buffer_text()
assert(text:find("open issue #5 in neovim/neovim", 1, true), text)
press("p")
assert(state.activity_page == 4)
press("j")
assert(state.activity_page == 3)
-- Unsaving on the saved feed removes the item and redraws the page.
vim.api.nvim_win_set_cursor(state.win, { title_lines()[1], 0 })
press("s")
assert(#store.items() == 6)
assert(buffer_text():find("6 saved items (3/3)", 1, true), buffer_text())
assert(#read_state().saved_items == 6)
-- Reloaded items keep the same keys.
local reloaded = read_state().saved_items

for index, entry in ipairs(reloaded) do
  assert(entry.key == store.items()[index].key)
end

-- Closing and reopening restores the saved feed; back returns to the lists.
window.close()
window.open(state.opts)
state = window.state
assert(state.view == "activity" and state.activity_saved and state.activity_page == 3)
press("j")
press("j")
press("j")
assert(state.view == "contributors", state.view)
store.load({})
press("s")
assert(buffer_text():find("No saved items. Press S on an activity item to save it.", 1, true))
window.close()

for provider, functions in pairs(originals) do
  for name, value in pairs(functions) do
    provider[name] = value
  end
end

assert(vim.fn.delete(workspace, "rf") == 0)
print("saved_spec: ok")
