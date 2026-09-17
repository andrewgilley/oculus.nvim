-- Recent commits read from a local clone of a project. The forge activity
-- APIs can lag behind a push by minutes or hours, so these fill the gap until
-- the forge reports the same commits.
local git = require("oculus.inspect.git")
local M = {}
M.commit_limit = 100

local hosts = {
  github = "https://github.com/",
  codeberg = "https://codeberg.org/",
}

local function project_info(project)
  if type(project) ~= "table" or type(project.repository) ~= "string" then
    return nil
  end

  local owner, repo = project.repository:match("^([^/]+)/([^/]+)$")

  if not owner then
    return nil
  end

  return {
    forge = project.provider == "codeberg" and "codeberg" or "github",
    owner = owner,
    repo = repo,
  }
end

local function matching_remote(output, info)
  local slug = (info.owner .. "/" .. info.repo):lower()

  for line in (output or ""):gmatch("[^\r\n]+") do
    local remote, url = line:match("^(%S+)%s+(%S+)%s+%(fetch%)")
    local forge, repository = git.forge_repository(url)

    if forge == info.forge and repository == slug then
      return remote
    end
  end
end

-- Unlike inspection, a clone only counts when one of its remotes points at
-- the project; configured repositories are not assumed to match.
function M.find_repository(project, opts, callback)
  local info = project_info(project)

  if not info then
    callback(nil)
    return
  end

  local candidates = git.local_candidates(info, opts or {})
  local index = 1

  local function inspect_next()
    local candidate = candidates[index]
    index = index + 1

    if not candidate then
      callback(git.discover_local_repository(info, opts or {}))
      return
    end

    git.run({ "git", "-C", candidate.path, "remote", "-v" }, function(output)
      local remote = matching_remote(output, info)

      if remote then
        callback(candidate.path, remote)
        return
      end

      inspect_next()
    end)
  end

  inspect_next()
end

function M.parse_log(output)
  local commits = {}

  for record in (output or ""):gmatch("([^\30]+)") do
    local fields = vim.split(record, "\31", { plain = true })
    local sha = vim.trim(fields[1] or "")
    local timestamp = tonumber(fields[2])

    if sha:match("^%x+$") and #sha >= 40 and timestamp then
      commits[#commits + 1] = {
        sha = sha,
        timestamp = timestamp,
        author_name = fields[3],
        author_email = fields[4],
        message = vim.trim(fields[5] or ""),
      }
    end
  end

  return commits
end

function M.commit_event(project, commit, pushed)
  local info = project_info(project)

  if not info then
    return nil
  end

  local author = {
    name = commit.author_name ~= "" and commit.author_name or nil,
    email = commit.author_email ~= "" and commit.author_email or nil,
  }

  return {
    id = "local-commit:" .. commit.sha,
    type = "PushEvent",
    actor = { name = author.name },
    repo = { name = project.repository },
    created_at = os.date("!%Y-%m-%dT%H:%M:%SZ", commit.timestamp),
    url = hosts[info.forge] .. project.repository .. "/commit/" .. commit.sha,
    oculus_text = ("committed to %s · %s"):format(
      project.repository,
      pushed == false and "local, not pushed" or "local"
    ),
    oculus_local = {
      forge = info.forge,
      pushed = pushed,
    },
    payload = {
      size = 1,
      head = commit.sha,
      commits = {
        {
          sha = commit.sha,
          message = commit.message,
          author = author,
        },
      },
    },
  }
end

-- Local commits only cover the stretch of history the forge has not reported
-- yet: anything at or before its newest push is already in its feed, unless
-- the commit was never pushed.
function M.prune(feed)
  local newest

  for _, event in ipairs(feed.events) do
    if event.type == "PushEvent"
      and not event.oculus_local
      and type(event.created_at) == "string"
      and (not newest or event.created_at > newest)
    then
      newest = event.created_at
    end
  end

  if not newest then
    return
  end

  feed.events = vim.tbl_filter(function(event)
    return not event.oculus_local
      or event.oculus_local.pushed == false
      or tostring(event.created_at or "") > newest
  end, feed.events)
end

local function unpushed_commits(repository, remote, callback)
  git.run({
    "git",
    "-C",
    repository,
    "for-each-ref",
    "--count=1",
    "--format=%(refname)",
    "refs/remotes/" .. remote,
  }, function(refs)
    -- Without remote-tracking refs there is no way to tell what was pushed.
    if not refs or refs == "" then
      callback(nil)
      return
    end

    git.run({
      "git",
      "-C",
      repository,
      "rev-list",
      "--max-count=" .. M.commit_limit,
      "HEAD",
      "--not",
      "--remotes=" .. remote,
    }, function(output)
      local unpushed = {}

      for sha in (output or ""):gmatch("%x+") do
        unpushed[sha] = true
      end

      callback(unpushed)
    end)
  end)
end

-- Calls back with commit events reachable from HEAD or the project's
-- remote-tracking branches, newest first, or an empty list when no clone of
-- the project is available.
function M.commits(project, opts, callback)
  M.find_repository(project, opts, function(repository, remote)
    if not repository then
      callback({})
      return
    end

    git.run_raw({
      "git",
      "-C",
      repository,
      "log",
      "--max-count=" .. M.commit_limit,
      "--format=%H%x1f%ct%x1f%an%x1f%ae%x1f%B%x1e",
      "HEAD",
      "--remotes=" .. remote,
    }, function(output)
      local commits = M.parse_log(output)

      if #commits == 0 then
        callback({})
        return
      end

      unpushed_commits(repository, remote, function(unpushed)
        local events = {}

        for _, commit in ipairs(commits) do
          local pushed

          if unpushed then
            pushed = not unpushed[commit.sha]
          end

          local event = M.commit_event(project, commit, pushed)

          if event then
            events[#events + 1] = event
          end
        end

        callback(events)
      end)
    end)
  end)
end

return M
