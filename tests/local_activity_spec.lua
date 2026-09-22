local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)
local local_activity = require("oculus.local_activity")
local window = require("oculus.window")
local inspect = require("oculus.inspect")

local project = {
  name = "example",
  repository = "example-owner/example-repo",
  provider = "github",
}

local function wait_for(predicate)
  assert(vim.wait(10000, predicate, 10), "timed out waiting for condition")
end

local function git(directory, ...)
  local result = vim.system(
    { "git", "-C", directory, ... },
    {
      text = true,
      env = {
        GIT_AUTHOR_NAME = "Local Author",
        GIT_AUTHOR_EMAIL = "local@example.com",
        GIT_COMMITTER_NAME = "Local Author",
        GIT_COMMITTER_EMAIL = "local@example.com",
      },
    }
  ):wait()

  assert(result.code == 0, result.stderr)
  return vim.trim(result.stdout or "")
end

do
  local sha = ("a"):rep(40)

  local commits = local_activity.parse_log(
    sha .. "\31" .. "1790000000\31Local Author\31local@example.com\31"
      .. "Subject line\n\nBody text\n\30\n"
  )

  assert(#commits == 1)
  assert(commits[1].sha == sha)
  assert(commits[1].timestamp == 1790000000)
  assert(commits[1].message == "Subject line\n\nBody text")
  local event = local_activity.commit_event(project, commits[1], false)
  assert(event.type == "PushEvent")
  assert(event.id == "local-commit:" .. sha)
  assert(event.created_at == os.date("!%Y-%m-%dT%H:%M:%SZ", 1790000000))
  assert(event.url == "https://github.com/example-owner/example-repo/commit/" .. sha)
  assert(event.oculus_local.pushed == false)
  assert(event.oculus_text:find("not pushed", 1, true))
  assert(event.payload.commits[1].message == "Subject line\n\nBody text")
  local context = inspect.activity_context(event)
  assert(context.local_commit.pushed == false)
  assert(context.local_commit.forge == "github")
end

do
  local function push(id, sha, created_at)
    return {
      id = id,
      type = "PushEvent",
      repo = { name = project.repository },
      created_at = created_at,
      payload = { size = 1, head = sha, commits = { { sha = sha } } },
    }
  end

  local function local_commit(sha, created_at, pushed)
    local event = push("local-commit:" .. sha, sha, created_at)
    event.oculus_local = { forge = "github", pushed = pushed }
    return event
  end

  local feed = {
    events = {},
    seen = {},
    seen_commits = {},
    seen_pull_requests = {},
    local_commits = {},
  }

  assert(window._add_project_feed_event(
    feed,
    local_commit("newest", "2026-09-16T12:00:00Z", true)
  ))

  assert(window._add_project_feed_event(
    feed,
    local_commit("reported", "2026-09-16T11:00:00Z", true)
  ))

  assert(window._add_project_feed_event(
    feed,
    local_commit("older", "2026-09-16T09:00:00Z", true)
  ))

  assert(window._add_project_feed_event(
    feed,
    local_commit("unpushed", "2026-09-16T08:00:00Z", false)
  ))

  -- The forge reports a commit shown from the local clone: its event replaces
  -- the local one instead of being dropped as a duplicate.
  assert(window._add_project_feed_event(
    feed,
    push("remote-reported", "reported", "2026-09-16T11:30:00Z")
  ))

  assert(not window._add_project_feed_event(
    feed,
    push("remote-reported-again", "reported", "2026-09-16T11:30:00Z")
  ))

  assert(not window._add_project_feed_event(
    feed,
    local_commit("reported", "2026-09-16T11:00:00Z", true)
  ))

  local_activity.prune(feed)
  local ids = {}

  for _, event in ipairs(feed.events) do
    ids[event.id] = true
  end

  assert(ids["local-commit:newest"])
  assert(ids["remote-reported"])
  assert(not ids["local-commit:reported"])
  assert(not ids["local-commit:older"])
  assert(ids["local-commit:unpushed"])
  assert(#feed.events == 3)
end

do
  local lines = inspect._overview_ui.float_lines({
    kind = "commit",
    forge = "github",
    commit_details = { subject = "Local work" },
    local_commit = { forge = "github", pushed = true },
  }, 60)

  local text = table.concat(lines, "\n")
  assert(text:find("Local clone, not yet listed by GitHub", 1, true))

  lines = inspect._overview_ui.float_lines({
    kind = "commit",
    forge = "codeberg",
    commit_details = { subject = "Local work" },
    local_commit = { forge = "codeberg", pushed = false },
  }, 60)

  text = table.concat(lines, "\n")
  assert(text:find("Local clone, not pushed", 1, true))

  lines = inspect._overview_ui.float_lines({
    kind = "commit",
    forge = "github",
    commit_details = { subject = "Forge work" },
  }, 60)

  assert(not table.concat(lines, "\n"):find("Local clone", 1, true))
  local buf = vim.api.nvim_create_buf(false, true)

  local group = {
    overview_buf = buf,
    overview_content_width = 60,
    overview = {
      kind = "commit",
      forge = "github",
      commit_details = { subject = "Local work" },
      local_commit = { forge = "github", pushed = false },
    },
  }

  inspect._overview_ui.render(group)
  local rendered_lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local source_line

  for line_num, line_str in ipairs(rendered_lines) do
    if line_str == "  Source" then
      source_line = line_num
      break
    end
  end

  assert(source_line, "Source heading line not found in rendered overview")
  local source_underlined = false

  for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(
    buf,
    -1,
    0,
    -1,
    { details = true }
  )) do
    if mark[2] + 1 == source_line
      and mark[4].hl_group == "OculusInspectOverviewSection"
    then
      source_underlined = true
      break
    end
  end

  assert(
    source_underlined,
    "Source heading was not styled with OculusInspectOverviewSection"
  )

  vim.api.nvim_buf_delete(buf, { force = true })
end

do
  local directory = vim.fn.tempname()
  vim.fn.mkdir(directory, "p")
  git(directory, "init", "--quiet", "--initial-branch=main")

  git(
    directory,
    "remote",
    "add",
    "origin",
    "git@github.com:Example-Owner/example-repo.git"
  )

  git(directory, "commit", "--quiet", "--allow-empty", "-m", "Pushed work")
  local pushed_sha = git(directory, "rev-parse", "HEAD")
  git(directory, "update-ref", "refs/remotes/origin/main", pushed_sha)
  git(directory, "commit", "--quiet", "--allow-empty", "-m", "Unpushed work")
  local unpushed_sha = git(directory, "rev-parse", "HEAD")
  local events

  local_activity.commits(project, {
    inspect_repositories = {},
    inspect_search_paths = {},
    cwd = directory,
  }, function(result)
    events = result
  end)

  wait_for(function()
    return events ~= nil
  end)

  assert(#events == 2)
  assert(events[1].payload.head == unpushed_sha)
  assert(events[1].oculus_local.pushed == false)
  assert(events[1].actor.name == "Local Author")
  assert(events[2].payload.head == pushed_sha)
  assert(events[2].oculus_local.pushed == true)
  vim.fn.mkdir(directory .. "/packages/editor", "p")
  vim.fn.writefile({ "editor" }, directory .. "/packages/editor/main.lua")
  git(directory, "add", "packages/editor/main.lua")
  git(directory, "commit", "--quiet", "-m", "Edit editor")
  local editor_sha = git(directory, "rev-parse", "HEAD")
  vim.fn.writefile({ "unrelated" }, directory .. "/other.txt")
  git(directory, "add", "other.txt")
  git(directory, "commit", "--quiet", "-m", "Edit elsewhere")
  local directory_events

  local_activity.commits({
    repository = project.repository,
    provider = "github",
    path = "packages/editor",
  }, {
    inspect_repositories = {},
    inspect_search_paths = {},
    cwd = directory,
  }, function(result)
    directory_events = result
  end)

  wait_for(function() return directory_events ~= nil end)
  assert(#directory_events == 1 and directory_events[1].payload.head == editor_sha)
  local other
  local other_events

  local_activity.commits({
    repository = "someone-else/example-repo",
    provider = "github",
  }, {
    inspect_repositories = { directory },
    inspect_search_paths = {},
    cwd = directory,
  }, function(result)
    other_events = result
    other = true
  end)

  wait_for(function()
    return other
  end)

  assert(#other_events == 0)
  vim.fn.delete(directory, "rf")
end

print("local activity tests passed")
