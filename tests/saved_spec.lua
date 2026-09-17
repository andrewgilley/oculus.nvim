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
    "repository_events",
    "repository_updates",
    "repository_issues",
    "enrich_pull_requests",
    "enrich_pushes",
    "pull_request_commits",
  }) do
    originals[provider][name] = provider[name]
  end

  provider.repository_updates = function(_, _, callback)
    callback({}, nil, false)
  end

  provider.enrich_pull_requests = function(events, _, callback)
    callback(events)
  end

  provider.enrich_pushes = function(events, _, callback)
    callback(events)
  end
end

github.repository_events = function(repository, _, callback)
  callback({
    {
      id = "gh-push",
      type = "PushEvent",
      repo = { name = repository },
      actor = { login = "pusher" },
      created_at = "2026-07-02T12:00:00Z",
      payload = { size = 1, head = "abc123", before = "000111" },
    },
    {
      id = "gh-pr",
      type = "PullRequestEvent",
      repo = { name = repository },
      actor = { login = "maintainer" },
      created_at = "2026-07-01T12:00:00Z",
      payload = {
        action = "merged",
        number = 12,
        pull_request = { number = 12, title = "Refine defaults", html_url = "https://github.com/neovim/neovim/pull/12" },
      },
    },
  }, nil, false)
end

github.repository_issues = function(repository, _, callback)
  callback({
    {
      id = "project-issue:neovim/neovim:5",
      type = "IssuesEvent",
      actor = { login = "reporter" },
      repo = { name = repository },
      created_at = "2026-08-01T12:00:00Z",
      url = "https://github.com/neovim/neovim/issues/5",
      payload = {
        action = "opened",
        issue = {
          number = 5,
          title = "Saved issue",
          state = "open",
          assignees = {},
          html_url = "https://github.com/neovim/neovim/issues/5",
        },
      },
    },
  }, nil, false, true)
end

-- Codeberg project feeds come from repository_updates.
codeberg.repository_updates = function(repository, _, callback)
  callback({
    {
      id = "cb-pr",
      type = "PullRequestEvent",
      repo = { name = repository },
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
      repo = { name = repository },
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
  }, nil, false)
end

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

local function footer_text()
  return table.concat(vim.api.nvim_buf_get_lines(state.footer_buf, 0, -1, false), "\n")
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

  press("l")
  assert(state.activity_project.repository == repository)
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
open_project("neovim/neovim")
assert(footer_text():find("s save", 1, true), footer_text())
local lines = title_lines()
vim.api.nvim_win_set_cursor(state.win, { lines[1], 0 })
press("s")
assert(#store.items() == 1)
assert(store.items()[1].source.kind == "project")
assert(store.items()[1].source.repository == "neovim/neovim")
assert(store.items()[1].event.id == "gh-push")
assert(starred(lines[1]) and not starred(lines[2]))
assert(read_state().saved_items[1].event.id == "gh-push")
-- Saving toggles.
press("s")
assert(#store.items() == 0 and not starred(lines[1]))
press("s")
vim.api.nvim_win_set_cursor(state.win, { lines[2], 0 })
press("s")
assert(#store.items() == 2 and store.items()[1].event.id == "gh-pr")
press("u")
assert(state.activity_issue_page)
vim.api.nvim_win_set_cursor(state.win, { title_lines()[1], 0 })
press("s")
assert(store.items()[1].event.id == "project-issue:neovim/neovim:5")
open_project("forgejo/forgejo")
local forgejo_lines = title_lines()
vim.api.nvim_win_set_cursor(state.win, { forgejo_lines[1], 0 })
press("s")
vim.api.nvim_win_set_cursor(state.win, { forgejo_lines[2], 0 })
press("s")
assert(#store.items() == 5)
assert(store.items()[1].source.provider == "codeberg")
assert(#read_state().saved_items == 5)
-- The start screen opens the saved feed.
press("j")
assert(state.view == "contributors")
press("s")
assert(state.view == "activity" and state.activity_saved)
local text = buffer_text()
assert(text:find("  SAVED\n", 1, true), text)
assert(text:find("5 saved items (1/3)", 1, true), text)
assert(#state.events == 2)
assert(footer_text():find("s unsave", 1, true))

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
assert(text:find("open issue #5 in neovim/neovim", 1, true), text)
press("p")
assert(state.activity_page == 3 and #state.events == 1)
press("p")
assert(state.activity_page == 3)
press("j")
assert(state.activity_page == 2)
-- Unsaving on the saved feed removes the item and redraws the page.
vim.api.nvim_win_set_cursor(state.win, { title_lines()[1], 0 })
press("s")
assert(#store.items() == 4)
assert(buffer_text():find("4 saved items (2/2)", 1, true), buffer_text())
assert(#read_state().saved_items == 4)
-- Reloaded items keep the same keys.
local reloaded = read_state().saved_items

for index, entry in ipairs(reloaded) do
  assert(entry.key == store.items()[index].key)
end

-- Closing and reopening restores the saved feed; back returns to the lists.
window.close()
window.open(state.opts)
state = window.state
assert(state.view == "activity" and state.activity_saved)
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
