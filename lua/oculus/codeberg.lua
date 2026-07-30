-- AGENT_CHANGE_BEGIN codeberg-andrew-kelley-20260727 2 Add Codeberg activity provider and Forgejo event normalization
local M = {}

local cache = {}
local inspect_pull_request_cache = {}
local inspect_issue_cache = {}
local base_url = "https://codeberg.org"

local function decode_response(stdout)
  local body, status = stdout:match("^(.*)\n(%d%d%d)%s*$")
  if not status then
    return nil, "Codeberg returned an invalid response"
  end

  if tonumber(status) ~= 200 then
    local ok, payload = pcall(vim.json.decode, body)
    local message = ok
        and payload
        and (payload.message or payload.error)
      or ("HTTP " .. status)
    return nil, "Codeberg: " .. message
  end

  local ok, payload = pcall(vim.json.decode, body)
  if not ok or type(payload) ~= "table" then
    return nil, "Codeberg returned malformed JSON"
  end
  return payload
end

local function request_json(url, opts, callback)
  if vim.fn.executable("curl") ~= 1 then
    vim.schedule(function()
      callback(nil, "Oculus requires curl to load Codeberg activity")
    end)
    return
  end

  local command = {
    "curl",
    "-sS",
    "-L",
    "--max-time",
    tostring(opts.request_timeout or 15),
    "-H",
    "Accept: application/json",
    "-H",
    "User-Agent: oculus.nvim",
    "-w",
    "\n%{http_code}",
  }

  local token = opts.codeberg_token or vim.env.CODEBERG_TOKEN
  local stdin
  if token and token ~= "" then
    vim.list_extend(command, { "-H", "@-" })
    stdin = "Authorization: token " .. token .. "\n"
  end
  command[#command + 1] = url

  vim.system(command, { text = true, stdin = stdin }, function(result)
    vim.schedule(function()
      if result.code ~= 0 then
        local message = vim.trim(result.stderr or "")
        callback(nil, message ~= "" and message or "Unable to reach Codeberg")
        return
      end
      callback(decode_response(result.stdout or ""))
    end)
  end)
end

local function content(activity)
  if type(activity.content) == "table" then
    return activity.content
  end
  if type(activity.content) ~= "string" or activity.content == "" then
    return {}
  end
  local ok, decoded = pcall(vim.json.decode, activity.content)
  return ok and type(decoded) == "table" and decoded or {}
end

local function repository(activity)
  local repo = type(activity.repo) == "table" and activity.repo or {}
  local name = repo.full_name
    or (
      type(repo.owner) == "table"
      and repo.owner.login
      and repo.name
      and (repo.owner.login .. "/" .. repo.name)
    )
    or repo.name
    or "an unknown repository"
  return name, repo.html_url or (base_url .. "/" .. name)
end

local function target(content_value)
  local number = content_value[1]
  if number ~= nil then
    number = tonumber(number) or number
  end
  return number, content_value[2]
end

local function event(activity, event_type, payload, url, group_url)
  local repo_name, repo_url = repository(activity)
  return {
    id = activity.id,
    type = event_type,
    actor = activity.act_user,
    repo = { name = repo_name },
    payload = payload or {},
    created_at = activity.created,
    url = url or repo_url,
    group_url = group_url,
  }
end

local function pull_request_event(activity, action, merged)
  local details = content(activity)
  local number, title = target(details)
  local _, repo_url = repository(activity)
  local url = number and (repo_url .. "/pulls/" .. number) or repo_url
  return event(activity, "PullRequestEvent", {
    action = action,
    number = number,
    pull_request = {
      number = number,
      title = title,
      merged = merged or false,
      html_url = url,
    },
  }, url)
end

local function issue_event(activity, action)
  local details = content(activity)
  local number, title = target(details)
  local _, repo_url = repository(activity)
  local url = number and (repo_url .. "/issues/" .. number) or repo_url
  return event(activity, "IssuesEvent", {
    action = action,
    issue = {
      number = number,
      title = title,
      html_url = url,
    },
  }, url)
end

local function comment_event(activity, pull_request)
  local details = content(activity)
  local number = target(details)
  local _, repo_url = repository(activity)
  local url = repo_url
  local comment = vim.deepcopy(activity.comment or {})
  comment.user = comment.user or activity.act_user
  if pull_request then
    url = number and (repo_url .. "/pulls/" .. number) or repo_url
  else
    url = number and (repo_url .. "/issues/" .. number) or repo_url
  end
  url = comment.html_url or url
  return event(activity, "IssueCommentEvent", {
    action = "created",
    issue = {
      number = number,
      html_url = url,
      pull_request = pull_request and {} or nil,
    },
    comment = comment,
  }, url)
end

local function review_event(activity, action)
  local details = content(activity)
  local number, body = target(details)
  local _, repo_url = repository(activity)
  local url = number and (repo_url .. "/pulls/" .. number) or repo_url
  local comment = activity.comment or {}
  url = comment.html_url or url
  return event(activity, "PullRequestReviewEvent", {
    action = action,
    pull_request = {
      number = number,
      html_url = url,
    },
    review = {
      body = body or comment.body,
      html_url = url,
    },
  }, url)
end

local function push_event(activity)
  local details = content(activity)
  local commits = {}
  for _, commit in ipairs(details.Commits or {}) do
    commits[#commits + 1] = {
      sha = commit.Sha1,
      message = commit.Message,
    }
  end

  local head = details.HeadCommit and details.HeadCommit.Sha1
    or (commits[1] and commits[1].sha)
  local _, repo_url = repository(activity)
  local url = head and (repo_url .. "/commit/" .. head) or repo_url
  local group_url
  if type(details.CompareURL) == "string" and details.CompareURL ~= "" then
    group_url = details.CompareURL:match("^https?://")
        and details.CompareURL
      or (base_url .. "/" .. details.CompareURL:gsub("^/", ""))
  end
  return event(activity, "PushEvent", {
    ref = activity.ref_name,
    head = head,
    size = tonumber(details.Len) or #commits,
    commits = commits,
  }, url, group_url or repo_url)
end

local normalizers = {
  commit_repo = push_event,
  mirror_sync_push = push_event,
  create_pull_request = function(activity)
    return pull_request_event(activity, "opened", false)
  end,
  merge_pull_request = function(activity)
    return pull_request_event(activity, "closed", true)
  end,
  auto_merge_pull_request = function(activity)
    return pull_request_event(activity, "enabled auto-merge for", false)
  end,
  close_pull_request = function(activity)
    return pull_request_event(activity, "closed", false)
  end,
  reopen_pull_request = function(activity)
    return pull_request_event(activity, "reopened", false)
  end,
  pull_request_ready_for_review = function(activity)
    return pull_request_event(activity, "marked ready for review", false)
  end,
  comment_pull = function(activity)
    return comment_event(activity, true)
  end,
  approve_pull_request = function(activity)
    return review_event(activity, "approved")
  end,
  reject_pull_request = function(activity)
    return review_event(activity, "changes requested")
  end,
  pull_review_dismissed = function(activity)
    return review_event(activity, "dismissed")
  end,
  create_issue = function(activity)
    return issue_event(activity, "opened")
  end,
  close_issue = function(activity)
    return issue_event(activity, "closed")
  end,
  reopen_issue = function(activity)
    return issue_event(activity, "reopened")
  end,
  comment_issue = function(activity)
    return comment_event(activity, false)
  end,
  create_repo = function(activity)
    return event(activity, "CreateEvent", { ref_type = "repository" })
  end,
  push_tag = function(activity)
    return event(activity, "CreateEvent", {
      ref_type = "tag",
      ref = (activity.ref_name or ""):gsub("^refs/tags/", ""),
    })
  end,
  mirror_sync_create = function(activity)
    return event(activity, "CreateEvent", {
      ref_type = "branch",
      ref = (activity.ref_name or ""):gsub("^refs/heads/", ""),
    })
  end,
  delete_tag = function(activity)
    return event(activity, "DeleteEvent", {
      ref_type = "tag",
      ref = (activity.ref_name or ""):gsub("^refs/tags/", ""),
    })
  end,
  delete_branch = function(activity)
    return event(activity, "DeleteEvent", {
      ref_type = "branch",
      ref = (activity.ref_name or ""):gsub("^refs/heads/", ""),
    })
  end,
  mirror_sync_delete = function(activity)
    return event(activity, "DeleteEvent", {
      ref_type = "branch",
      ref = (activity.ref_name or ""):gsub("^refs/heads/", ""),
    })
  end,
  star_repo = function(activity)
    return event(activity, "WatchEvent")
  end,
  watch_repo = function(activity)
    return event(activity, "WatchEvent")
  end,
  publish_release = function(activity)
    local details = content(activity)
    return event(activity, "ReleaseEvent", {
      action = "published",
      release = { tag_name = details[1] or activity.ref_name },
    })
  end,
}

function M.normalize_activity(activity)
  local normalize = normalizers[activity.op_type]
  if normalize then
    return normalize(activity)
  end

  local normalized = event(activity, "ActivityEvent")
  local operation = tostring(activity.op_type or "activity")
    :gsub("_", " ")
    :gsub("^%l", string.upper)
  normalized.oculus_text = operation .. " in " .. normalized.repo.name
  return normalized
end

function M.events(username, opts, callback)
  opts = opts or {}
  local ttl = opts.cache_ttl or 300
  local cached = cache[username]
  local limit = math.min(
    50,
    math.max(1, math.floor(opts.per_page or 30))
  )
  if not opts.force
    and cached
    and os.time() - cached.fetched_at < ttl
    and (
      (cached.per_page or #cached.events) >= limit
      or cached.complete
    )
  then
    vim.schedule(function()
      callback(cached.events, nil, true)
    end)
    return
  end

  local url = (
    "%s/api/v1/users/%s/activities/feeds?only-performed-by=true&limit=%d"
  ):format(base_url, vim.uri_encode(username), limit)
  request_json(url, opts, function(activities, err)
    if not activities then
      callback(nil, err)
      return
    end

    local events = {}
    for _, activity in ipairs(activities) do
      events[#events + 1] = M.normalize_activity(activity)
    end
    cache[username] = {
      events = events,
      fetched_at = os.time(),
      per_page = limit,
      complete = #activities < limit,
    }
    callback(events, nil, false)
  end)
end

function M.enrich_pull_requests(events, _, callback)
  vim.schedule(function()
    callback(events)
  end)
end

function M.enrich_pushes(events, _, callback)
  vim.schedule(function()
    callback(events)
  end)
end

function M.pull_request(repo, number, opts, callback)
  opts = opts or {}
  local key = ("%s#%s"):format(repo, number)
  local cached = inspect_pull_request_cache[key]
  local ttl = opts.inspect_cache_ttl or 60
  if
    cached
    and not opts.force
    and os.time() - cached.fetched_at < ttl
  then
    vim.schedule(function()
      callback(vim.deepcopy(cached.details))
    end)
    return
  end

  local url = ("%s/api/v1/repos/%s/pulls/%s"):format(
    base_url,
    repo,
    number
  )
  request_json(url, opts, function(pull_request, err)
    if not pull_request then
      callback(nil, err)
      return
    end

    local base = pull_request.base or {}
    local head = pull_request.head or {}
    local base_sha = pull_request.merge_base or base.sha
    if not base_sha or not head.sha then
      callback(
        nil,
        "Codeberg returned a pull request without base/head commits"
      )
      return
    end
    local details = {
      number = pull_request.number or number,
      title = pull_request.title,
      body = pull_request.body,
      author = pull_request.user and pull_request.user.login,
      state = pull_request.state,
      draft = pull_request.draft,
      merged = pull_request.merged,
      html_url = pull_request.html_url,
      base_sha = base_sha,
      base_ref = base.ref,
      head_sha = head.sha,
      head_ref = head.ref,
      commit_count = pull_request.commits,
      fetch_ref = type(head.ref) == "string"
          and head.ref:match("^refs/")
          and head.ref
        or ("refs/pull/%d/head"):format(number),
    }
    inspect_pull_request_cache[key] = {
      details = details,
      fetched_at = os.time(),
    }
    callback(vim.deepcopy(details))
  end)
end

function M.issue(repo, number, opts, callback)
  opts = opts or {}
  local key = ("%s#%s"):format(repo, number)
  local cached = inspect_issue_cache[key]
  local ttl = opts.inspect_cache_ttl or 60
  if
    cached
    and not opts.force
    and os.time() - cached.fetched_at < ttl
  then
    vim.schedule(function()
      callback(vim.deepcopy(cached.details))
    end)
    return
  end
  local url = ("%s/api/v1/repos/%s/issues/%s"):format(
    base_url,
    repo,
    number
  )
  request_json(url, opts, function(issue, err)
    if not issue then
      callback(nil, err)
      return
    end
    local details = {
      number = issue.number or number,
      title = issue.title,
      body = issue.body,
      html_url = issue.html_url,
    }
    inspect_issue_cache[key] = {
      details = details,
      fetched_at = os.time(),
    }
    callback(vim.deepcopy(details))
  end)
end

function M.clear(username)
  cache[username] = nil
end

return M
-- AGENT_CHANGE_END codeberg-andrew-kelley-20260727 2
