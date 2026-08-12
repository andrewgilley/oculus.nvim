-- AGENT_CHANGE_BEGIN codeberg-andrew-kelley-20260727 2 Add Codeberg activity provider and Forgejo event normalization
local M = {}

local cache = {}
local repository_cache = {}
local repository_update_cache = {}
local repository_issue_cache = {}
local activity_pull_request_cache = {}
local pull_request_commits_cache = {}
local push_cache = {}
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
      merged_by = merged and activity.act_user or nil,
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
  local page = math.max(1, math.floor(opts.page or 1))
  local cache_key = page == 1 and username
    or (username .. ":" .. tostring(page))
  local cached = cache[cache_key]
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
      callback(cached.events, nil, true, nil, cached.complete)
    end)
    return
  end

  local url = (
    "%s/api/v1/users/%s/activities/feeds"
      .. "?only-performed-by=true&limit=%d&page=%d"
  ):format(base_url, vim.uri_encode(username), limit, page)
  request_json(url, opts, function(activities, err)
    if not activities then
      callback(nil, err)
      return
    end

    local events = {}
    for _, activity in ipairs(activities) do
      events[#events + 1] = M.normalize_activity(activity)
    end
    local complete = #activities < limit
    cache[cache_key] = {
      events = events,
      fetched_at = os.time(),
      per_page = limit,
      complete = complete,
    }
    callback(events, nil, false, nil, complete)
  end)
end

function M.repository_events(repository_name, opts, callback)
  opts = opts or {}
  local ttl = opts.cache_ttl or 300
  local page = math.max(1, math.floor(opts.page or 1))
  local cache_key = ("%s:%d"):format(repository_name, page)
  local cached = repository_cache[cache_key]
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
      callback(cached.events, nil, true, nil, cached.complete)
    end)
    return
  end

  local url = (
    "%s/api/v1/repos/%s/activities/feeds?limit=%d&page=%d"
  ):format(base_url, repository_name, limit, page)
  request_json(url, opts, function(activities, err)
    if not activities then
      callback(nil, err)
      return
    end

    local events = {}
    for _, activity in ipairs(activities) do
      events[#events + 1] = M.normalize_activity(activity)
    end
    repository_cache[cache_key] = {
      events = events,
      fetched_at = os.time(),
      per_page = limit,
      complete = #activities < limit,
    }
    callback(events, nil, false, nil, #activities < limit)
  end)
end

local function project_commit_event(repository_name, commit)
  local details = type(commit.commit) == "table" and commit.commit or {}
  local author = type(details.author) == "table" and details.author or {}
  local committer = type(details.committer) == "table"
      and details.committer
    or {}
  local account = type(commit.author) == "table" and commit.author or nil
  local sha = commit.sha
  if type(sha) ~= "string" or sha == "" then
    return nil
  end
  return {
    id = "project-commit:" .. sha,
    type = "PushEvent",
    actor = account or { name = author.name },
    repo = { name = repository_name },
    created_at = commit.created or committer.date or author.date,
    url = commit.html_url,
    payload = {
      size = 1,
      head = sha,
      commits = {
        {
          sha = sha,
          message = details.message,
          author = account or { name = author.name },
        },
      },
    },
  }
end

local function project_pull_request_event(repository_name, pull_request)
  local number = pull_request.number
  local merged_at = pull_request.merged_at
  if not number or type(merged_at) ~= "string" or merged_at == "" then
    return nil
  end
  local merger = pull_request.merged_by
  return {
    id = ("project-pr:%s:%s"):format(repository_name, number),
    type = "PullRequestEvent",
    actor = merger,
    repo = { name = repository_name },
    created_at = merged_at,
    url = pull_request.html_url,
    payload = {
      action = "merged",
      number = number,
      pull_request = {
        number = number,
        title = pull_request.title,
        user = pull_request.user,
        merged = true,
        merged_at = merged_at,
        merged_by = pull_request.merged_by,
        html_url = pull_request.html_url,
      },
    },
  }
end

function M.repository_updates(repository_name, opts, callback)
  opts = opts or {}
  local enabled = {}
  for _, category in ipairs(opts.activity_types or {}) do
    enabled[category] = true
  end
  local page = math.max(1, math.floor(opts.page or 1))
  local per_page = math.min(
    50,
    math.max(1, math.floor(opts.per_page or 16))
  )
  local categories = {}
  if enabled.push then
    categories[#categories + 1] = "push"
  end
  if enabled.merged_pull_request then
    categories[#categories + 1] = "merged_pull_request"
  end
  local cache_key = table.concat({
    repository_name:lower(),
    tostring(page),
    tostring(per_page),
    table.concat(categories, ","),
  }, ":")
  local cached = repository_update_cache[cache_key]
  local ttl = opts.cache_ttl or 300
  if cached
    and not opts.force
    and os.time() - cached.fetched_at < ttl
  then
    vim.schedule(function()
      callback(vim.deepcopy(cached.events), nil, true)
    end)
    return
  end
  if #categories == 0 then
    vim.schedule(function()
      callback({}, nil, false)
    end)
    return
  end

  local pending = #categories
  local events = {}
  local errors = {}
  local function complete()
    pending = pending - 1
    if pending > 0 then
      return
    end
    table.sort(events, function(left, right)
      return tostring(left.created_at or "")
        > tostring(right.created_at or "")
    end)
    if #events == 0 and #errors == #categories then
      callback(nil, table.concat(errors, "; "))
      return
    end
    repository_update_cache[cache_key] = {
      events = vim.deepcopy(events),
      fetched_at = os.time(),
    }
    callback(
      vim.deepcopy(events),
      nil,
      false,
      #errors > 0 and table.concat(errors, "; ") or nil
    )
  end

  if enabled.push then
    local url = (
      "%s/api/v1/repos/%s/commits?limit=%d&page=%d"
    ):format(base_url, repository_name, per_page, page)
    request_json(url, opts, function(commits, err)
      if commits then
        for _, commit in ipairs(commits) do
          local normalized = project_commit_event(repository_name, commit)
          if normalized then
            events[#events + 1] = normalized
          end
        end
      else
        errors[#errors + 1] = err or "could not load project commits"
      end
      complete()
    end)
  end
  if enabled.merged_pull_request then
    local url = (
      "%s/api/v1/repos/%s/pulls"
        .. "?state=closed&sort=recentupdate&limit=%d&page=%d"
    ):format(base_url, repository_name, per_page, page)
    request_json(url, opts, function(pull_requests, err)
      if pull_requests then
        for _, pull_request in ipairs(pull_requests) do
          local normalized = project_pull_request_event(
            repository_name,
            pull_request
          )
          if normalized then
            events[#events + 1] = normalized
          end
        end
      else
        errors[#errors + 1] = err
          or "could not load merged pull requests"
      end
      complete()
    end)
  end
end

local function project_issue_event(repository_name, issue)
  if type(issue) ~= "table" or issue.pull_request or not issue.number then
    return nil
  end
  local state = issue.state == "closed" and "closed" or "open"
  return {
    id = ("project-issue:%s:%s"):format(repository_name, issue.number),
    type = "IssuesEvent",
    actor = issue.user,
    repo = { name = repository_name },
    created_at = issue.updated_at or issue.created_at,
    url = issue.html_url,
    payload = {
      action = state == "closed" and "closed" or "opened",
      issue = {
        number = issue.number,
        title = issue.title,
        body = issue.body,
        user = issue.user,
        assignee = issue.assignee,
        assignees = issue.assignees or {},
        labels = issue.labels or {},
        state = state,
        html_url = issue.html_url,
        created_at = issue.created_at,
        updated_at = issue.updated_at,
      },
    },
  }
end

function M.repository_issues(repository_name, opts, callback)
  opts = opts or {}
  local ttl = opts.cache_ttl or 300
  local page = math.max(1, math.floor(opts.page or 1))
  local per_page = math.min(
    50,
    math.max(1, math.floor(opts.per_page or 50))
  )
  local state = opts.issue_state == "closed" and "closed"
    or opts.issue_state == "all" and "all"
    or "open"
  local cache_key = table.concat({
    repository_name:lower(),
    state,
    tostring(page),
    tostring(per_page),
  }, ":")
  local cached = repository_issue_cache[cache_key]
  if cached
    and not opts.force
    and os.time() - cached.fetched_at < ttl
  then
    vim.schedule(function()
      callback(
        vim.deepcopy(cached.events),
        nil,
        true,
        cached.complete
      )
    end)
    return
  end

  local url = (
    "%s/api/v1/repos/%s/issues"
      .. "?state=%s&type=issues&limit=%d&page=%d"
  ):format(base_url, repository_name, state, per_page, page)
  request_json(url, opts, function(issues, err)
    if not issues then
      callback(nil, err)
      return
    end
    local events = {}
    for _, issue in ipairs(issues) do
      local normalized = project_issue_event(repository_name, issue)
      if normalized then
        events[#events + 1] = normalized
      end
    end
    local complete = #issues < per_page
    repository_issue_cache[cache_key] = {
      events = vim.deepcopy(events),
      fetched_at = os.time(),
      complete = complete,
    }
    callback(events, nil, false, complete)
  end)
end

local function activity_pull_request_key(event)
  if event.type ~= "PullRequestEvent" then
    return nil
  end
  local repo = event.repo and event.repo.name
  local payload = event.payload or {}
  local pull_request = payload.pull_request or {}
  local number = pull_request.number or payload.number
  local merged = payload.action == "merged"
    or (payload.action == "closed" and pull_request.merged == true)
  if not merged or not repo or not number then
    return nil
  end
  if pull_request.title and pull_request.user and pull_request.merged_by then
    return nil
  end
  return ("%s#%s"):format(repo, number), repo, number
end

local function apply_activity_pull_request(event, details)
  event.payload = event.payload or {}
  event.payload.pull_request = event.payload.pull_request or {}
  local pull_request = event.payload.pull_request
  pull_request.title = pull_request.title or details.title
  pull_request.html_url = pull_request.html_url or details.html_url
  if not pull_request.user and details.author then
    pull_request.user = { login = details.author }
  end
  if not pull_request.merged_by and details.merged_by then
    pull_request.merged_by = { login = details.merged_by }
  end
end

function M.enrich_pull_requests(events, opts, callback)
  opts = opts or {}
  local pending = 0

  local function complete()
    pending = pending - 1
    if pending == 0 then
      callback(events)
    end
  end

  for _, event in ipairs(events) do
    local key, repo, number = activity_pull_request_key(event)
    if key then
      local cached = activity_pull_request_cache[key]
      if type(cached) == "table" then
        apply_activity_pull_request(event, cached)
      elseif cached == nil then
        pending = pending + 1
        local url = ("%s/api/v1/repos/%s/pulls/%s"):format(
          base_url,
          repo,
          number
        )
        request_json(url, opts, function(pull_request)
          if pull_request then
            local details = {
              title = pull_request.title,
              html_url = pull_request.html_url,
              author = pull_request.user and pull_request.user.login,
              merged_by = pull_request.merged_by
                and pull_request.merged_by.login,
            }
            activity_pull_request_cache[key] = details
            apply_activity_pull_request(event, details)
          else
            activity_pull_request_cache[key] = false
          end
          complete()
        end)
      end
    end
  end

  if pending == 0 then
    vim.schedule(function()
      callback(events)
    end)
  end
end

local function push_needs_enrichment(event)
  if event.type ~= "PushEvent" then
    return false
  end
  local payload = event.payload or {}
  local commits = payload.commits
  if type(commits) ~= "table" or #commits == 0 then
    return true
  end
  local expected = tonumber(payload.size)
  return expected ~= nil and expected > #commits
end

local function push_comparison_key(event)
  local repository_name = event.repo and event.repo.name
  local comparison_url = event.group_url
  local basehead = type(comparison_url) == "string"
      and comparison_url:match("/compare/([^/?#]+)")
    or nil
  if not repository_name or not basehead then
    return nil
  end
  return repository_name .. ":" .. basehead, repository_name, basehead
end

local function apply_push_comparison(event, comparison)
  local commits = {}
  for _, commit in ipairs(comparison.commits or {}) do
    local details = type(commit.commit) == "table" and commit.commit or {}
    if type(commit.sha) == "string" and commit.sha ~= "" then
      commits[#commits + 1] = {
        sha = commit.sha,
        message = details.message or commit.message,
      }
    end
  end
  if #commits == 0 then
    return false
  end
  event.payload = event.payload or {}
  event.payload.commits = commits
  event.payload.size = tonumber(event.payload.size)
    or tonumber(comparison.total_commits)
    or #commits
  return true
end

function M.enrich_pushes(events, opts, callback)
  opts = opts or {}
  local limit = opts.push_detail_limit or 10
  local pending = 0
  local selected = 0

  local function complete()
    pending = pending - 1
    if pending == 0 then
      callback(events)
    end
  end

  for _, event in ipairs(events) do
    if selected >= limit then
      break
    end
    if push_needs_enrichment(event) then
      local key, repository_name, basehead = push_comparison_key(event)
      if key then
        selected = selected + 1
        local cached = push_cache[key]
        if type(cached) == "table" then
          apply_push_comparison(event, cached)
        elseif cached == nil then
          pending = pending + 1
          local url = ("%s/api/v1/repos/%s/compare/%s"):format(
            base_url,
            repository_name,
            basehead
          )
          request_json(url, opts, function(comparison)
            if comparison and apply_push_comparison(event, comparison) then
              push_cache[key] = comparison
            else
              push_cache[key] = false
            end
            complete()
          end)
        end
      end
    end
  end

  if pending == 0 then
    vim.schedule(function()
      callback(events)
    end)
  end
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
      created_at = pull_request.created_at,
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

function M.pull_request_commits(repo, number, opts, callback)
  opts = opts or {}
  local key = ("%s#%s"):format(repo, number)
  local cached = pull_request_commits_cache[key]
  local ttl = opts.cache_ttl or 300
  if cached
    and not opts.force
    and os.time() - cached.fetched_at < ttl
  then
    vim.schedule(function()
      callback(vim.deepcopy(cached.commits))
    end)
    return
  end

  local commits = {}
  local page = 1
  local function load_page()
    local url = (
      "%s/api/v1/repos/%s/pulls/%s/commits?limit=50&page=%d"
    ):format(base_url, repo, number, page)
    request_json(url, opts, function(results, err)
      if not results then
        callback(nil, err)
        return
      end
      vim.list_extend(commits, results)
      if #results == 50 then
        page = page + 1
        load_page()
        return
      end
      pull_request_commits_cache[key] = {
        commits = vim.deepcopy(commits),
        fetched_at = os.time(),
      }
      callback(vim.deepcopy(commits))
    end)
  end
  load_page()
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
      author = issue.user and (issue.user.login or issue.user.username),
      state = issue.state,
      html_url = issue.html_url,
      created_at = issue.created_at,
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

M._apply_push_comparison = apply_push_comparison
M._project_commit_event = project_commit_event
M._project_pull_request_event = project_pull_request_event
M._push_needs_enrichment = push_needs_enrichment

return M
-- AGENT_CHANGE_END codeberg-andrew-kelley-20260727 2
