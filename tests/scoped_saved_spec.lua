vim.opt.runtimepath:prepend(vim.fn.getcwd())
local store = require("oculus.saved")

-- Source identity ignores display names and letter case, but preserves forge
-- and tracked subdirectory boundaries. Older saves need no migration.
do
  local project = { kind = "project", provider = "github", repository = "Owner/Repo" }
  local user = { kind = "user", provider = "github", username = "Alice" }
  local codeberg = vim.tbl_extend("force", project, { provider = "codeberg" })
  local subdir = vim.tbl_extend("force", project, { path = "src" })

  store.load({
    { key = "same", source = project, event = { id = 1 } },
    { key = "same", source = user, event = { id = 1 } },
    { key = "same", source = codeberg, event = { id = 1 } },
    { key = "same", source = subdir, event = { id = 1 } },
    { key = "legacy", event = { id = 2 } },
  })

  assert(#store.items() == 5)
  assert(#store.items({ kind = "project", repository = "owner/repo", name = "Renamed" }) == 1)
  assert(#store.items({ kind = "user", username = "alice" }) == 1)
  assert(#store.items(codeberg) == 1 and #store.items(subdir) == 1)
  store.add({ key = "same", source = project, event = { id = 3 } })
  assert(#store.items() == 5 and store.items(project)[1].event.id == 3)
  assert(store.remove("same", user, true))
  assert(#store.items(user) == 0 and #store.items(project) == 1)
  local snapshot = vim.deepcopy(store.items())
  store.load(snapshot)
  assert(vim.deep_equal(store.items(), snapshot))
  assert(store.items()[#store.items()].key == "legacy")
end

local github = require("oculus.github")
local originals = {}
local issue_events = {}

for number = 1, 3 do
  issue_events[number] = {
    id = "scoped-issue-" .. number,
    type = "IssuesEvent",
    actor = { login = "alice" },
    repo = { name = "owner/repo" },
    created_at = "2026-10-07T12:00:00Z",
    url = "https://github.com/owner/repo/issues/" .. number,
    payload = { action = "opened", issue = {
      number = number, title = "Issue " .. number, state = "open",
      html_url = "https://github.com/owner/repo/issues/" .. number,
    } },
  }
end

for _, name in ipairs({ "events", "repository_issues", "repository_info", "enrich_pushes", "enrich_pull_requests" }) do
  originals[name] = github[name]
end

github.events = function(_, _, callback) callback(vim.deepcopy(issue_events), nil, true) end
github.repository_issues = function(_, _, callback) callback(vim.deepcopy(issue_events), nil, true, false) end
github.repository_info = function(_, _, callback) callback({ description = "Fixture" }) end
github.enrich_pushes = function(events, _, callback) callback(events) end
github.enrich_pull_requests = function(events, _, callback) callback(events) end
store.load({})
local window = require("oculus.window")
local directory = vim.fn.tempname()
vim.fn.mkdir(directory, "p")
local state_file = directory .. "/state.json"
vim.o.columns = 160
vim.o.lines = 50

window.open({
  results_limit = 2,
  state_file = state_file,
  projects = { { repository = "owner/repo", provider = "github" } },
  contributors = { { username = "alice", provider = "github" }, { username = "bob", provider = "github" } },
  activity_types = { "IssuesEvent" },
  navigation = { up = "i", down = "k", left = "j", right = "l" },
})

local state = window.state

local function press(key)
  local mapping = vim.fn.maparg(key, "n", false, true)
  assert(type(mapping.callback) == "function", key)
  mapping.callback()
end

local function text()
  return table.concat(vim.api.nvim_buf_get_lines(state.buf, 0, -1, false), "\n")
end

local function select_source(name)
  for line, target in pairs(state.line_targets) do
    if target.username == name or (target.project and target.project.repository == name) then
      vim.api.nvim_win_set_cursor(state.win, { line, 0 })
      return
    end
  end

  error("Source not found: " .. name)
end

local function select_event(id)
  for line, event in pairs(state.activity_events) do
    if event.id == id and state.activity_title_lines[line] == line then
      vim.api.nvim_win_set_cursor(state.win, { line, 0 })
      return line
    end
  end

  error("Event not found: " .. id)
end

local function starred(line)
  for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(state.buf, -1, { line - 1, 0 }, { line - 1, -1 }, { details = true })) do
    if mark[4].virt_text and mark[4].virt_text[1][1] == "★" then return true end
  end

  return false
end

local project = { kind = "project", provider = "github", repository = "owner/repo" }
local alice = { kind = "user", provider = "github", username = "alice" }
local bob = { kind = "user", provider = "github", username = "bob" }
select_source("owner/repo")
press("l")
select_event("scoped-issue-1")
press("s")
assert(#store.items(project) == 1)
local event_key = store.items(project)[1].key
press("<S-Tab>")
assert(state.activity_saved and state.saved_scope.repository == "owner/repo")
assert(text():find("1 saved item", 1, true))
assert(text():find("saved", 1, true))
assert(#state.events == 1 and starred(select_event("scoped-issue-1")))
press("<Tab>")
assert(not state.activity_saved and state.activity_issue_kind == "issues")
assert(starred(select_event("scoped-issue-1")))
press("j")
press("u")
select_source("alice")
press("S")
assert(state.activity_saved and state.saved_scope.username == "alice")
assert(#state.events == 0 and text():find("SAVED · @alice", 1, true))
press("j")
select_source("alice")
press("l")
assert(not starred(select_event("scoped-issue-1")), "Project saves must not star the user feed")
press("s")
assert(#store.items(project) == 1 and #store.items(alice) == 1 and #store.items() == 2)
assert(store.items(alice)[1].key == event_key)
assert(starred(select_event("scoped-issue-1")))
press("s")
assert(#store.items(project) == 1 and #store.items(alice) == 0)
press("s")

for number = 2, 3 do
  store.add({ key = "alice-" .. number, source = alice, event = vim.deepcopy(issue_events[number]) })
end

store.add({ key = event_key, source = bob, event = vim.deepcopy(issue_events[1]) })
store.add({ key = event_key, source = { kind = "user", provider = "codeberg", username = "alice" }, event = vim.deepcopy(issue_events[1]) })
store.add({ key = "legacy", event = vim.deepcopy(issue_events[3]) })
press("S")
assert(text():find("3 saved items (1/2)", 1, true), text())
assert(#state.events == 2 and state.saved_scope.username == "alice")
press("p")
assert(state.activity_page == 2 and #state.events == 1)
assert(text():find("3 saved items (2/2)", 1, true), text())
press("?")
press("?")
press("r")
assert(state.saved_scope.username == "alice" and state.saved_scope.provider == "github")
assert(state.activity_page == 2 and #state.events == 1)
window.close()
window.open(state.opts)
state = window.state
assert(state.activity_saved and state.saved_scope.username == "alice" and state.activity_page == 2)
local removed = state.events[1].id
select_event(removed)
press("s")
assert(state.activity_page == 1 and #state.events == 2)
assert(#store.items(alice) == 2 and #store.items(project) == 1 and #store.items(bob) == 1)
press("j")
select_source("bob")
press("S")
assert(#state.events == 1 and state.saved_scope.username == "bob")
press("j")
press("s")
assert(state.saved_scope == nil and #store.items() == 6)
assert(text():find("6 saved items (1/3)", 1, true), text())
local persisted = require("oculus.storage").load(state_file).saved_items
store.load(persisted)
assert(#store.items() == 6 and #store.items(alice) == 2 and #store.items(project) == 1)
window.close()
for name, original in pairs(originals) do github[name] = original end
vim.fn.delete(directory, "rf")
