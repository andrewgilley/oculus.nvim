local M = {}
local cache = {}
local repository_cache = {}
local repository_update_cache = {}
local repository_issue_cache = {}
local push_cache = {}
local pull_request_cache = {}
local pull_request_commits_cache = {}
local inspect_pull_request_cache = {}
local inspect_issue_cache = {}
local repository_milestone_cache = {}

local function decode_response(stdout)
  local body, status = stdout:match("^(.*)\n(%d%d%d)%s*$")

  if not status then
    return nil, "GitHub returned an invalid response"
  end

  if tonumber(status) ~= 200 then
    local ok, payload = pcall(vim.json.decode, body)
    local message = ok and payload and payload.message or ("HTTP " .. status)
    return nil, "GitHub: " .. message
  end

  local ok, payload = pcall(vim.json.decode, body)

  if not ok or type(payload) ~= "table" then
    return nil, "GitHub returned malformed JSON"
  end

  return payload
end

-- request, when given, is { body = <table> } and sends the body as a JSON POST.
local function request_json(url, opts, callback, request)
  if vim.fn.executable("curl") ~= 1 then
    vim.schedule(function()
      callback(nil, "Oculus requires curl to load GitHub activity")
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
    "Accept: application/vnd.github+json",
    "-H",
    "User-Agent: oculus.nvim",
    "-w",
    "\n%{http_code}",
  }

  local token = require("oculus.auth").github_token(opts)
  local stdin

  if token and token ~= "" then
    vim.list_extend(command, { "-H", "@-" })
    stdin = "Authorization: Bearer " .. token .. "\n"
  end

  -- stdin already carries the token, so the body goes through a file.
  local body_file

  if request and request.body ~= nil then
    body_file = vim.fn.tempname()
    vim.fn.writefile({ vim.json.encode(request.body) }, body_file)

    vim.list_extend(command, {
      "-X",
      "POST",
      "-H",
      "Content-Type: application/json",
      "--data-binary",
      "@" .. body_file,
    })
  end

  command[#command + 1] = url

  vim.system(command, { text = true, stdin = stdin }, function(result)
    vim.schedule(function()
      if body_file then
        vim.fn.delete(body_file)
      end

      if result.code ~= 0 then
        local message = vim.trim(result.stderr or "")
        callback(nil, message ~= "" and message or "Unable to reach GitHub")
        return
      end

      callback(decode_response(result.stdout or ""))
    end)
  end)
end

function M.events(username, opts, callback)
  opts = opts or {}
  local ttl = opts.cache_ttl or 300
  local page = math.max(1, math.floor(opts.page or 1))

  local cache_key = page == 1 and username
    or (username .. ":" .. tostring(page))

  local cached = cache[cache_key]

  local per_page = math.min(
    100,
    math.max(1, math.floor(opts.per_page or 30))
  )

  if not opts.force
    and cached
    and os.time() - cached.fetched_at < ttl
    and (
      (cached.per_page or #cached.events) >= per_page
      or cached.complete
    )
  then
    vim.schedule(function()
      callback(cached.events, nil, true, nil, cached.complete)
    end)

    return
  end

  local url = (
    "https://api.github.com/users/%s/events/public?per_page=%d&page=%d"
  ):format(username, per_page, page)

  request_json(url, opts, function(events, err)
    if not events then
      callback(nil, err)
      return
    end

    local complete = #events < per_page

    cache[cache_key] = {
      events = events,
      fetched_at = os.time(),
      per_page = per_page,
      complete = complete,
    }

    callback(events, nil, false, nil, complete)
  end)
end

function M.repository_events(repository, opts, callback)
  opts = opts or {}
  local ttl = opts.cache_ttl or 300
  local page = math.max(1, math.floor(opts.page or 1))
  local cache_key = ("%s:%d"):format(repository, page)
  local cached = repository_cache[cache_key]

  local per_page = math.min(
    100,
    math.max(1, math.floor(opts.per_page or 30))
  )

  if not opts.force
    and cached
    and os.time() - cached.fetched_at < ttl
    and (
      (cached.per_page or #cached.events) >= per_page
      or cached.complete
    )
  then
    vim.schedule(function()
      callback(
        vim.deepcopy(cached.events),
        nil,
        true,
        nil,
        cached.complete
      )
    end)

    return
  end

  local url = (
    "https://api.github.com/repos/%s/events?per_page=%d&page=%d"
  ):format(repository, per_page, page)

  request_json(url, opts, function(events, err)
    if not events then
      callback(nil, err)
      return
    end

    repository_cache[cache_key] = {
      events = events,
      fetched_at = os.time(),
      per_page = per_page,
      complete = #events < per_page,
    }

    callback(
      vim.deepcopy(events),
      nil,
      false,
      nil,
      #events < per_page
    )
  end)
end

-- JSON null decodes to vim.NIL, which is truthy; treat it as absent.
local function json_value(value)
  if value == vim.NIL then
    return nil
  end

  return value
end

local function project_issue_event(repository, issue, include_pull_requests)
  local pull_request = type(issue) == "table"
      and json_value(issue.pull_request)
    or nil

  if type(issue) ~= "table"
    or not issue.number
    or (pull_request and not include_pull_requests)
  then
    return nil
  end

  local state = issue.state == "closed" and "closed" or "open"
  local assignee = json_value(issue.assignee)

  return {
    id = ("project-issue:%s:%s"):format(repository, issue.number),
    type = "IssuesEvent",
    actor = json_value(issue.user),
    repo = { name = repository },
    created_at = json_value(issue.updated_at) or json_value(issue.created_at),
    url = json_value(issue.html_url),
    payload = {
      action = state == "closed" and "closed" or "opened",
      issue = {
        number = issue.number,
        title = json_value(issue.title),
        body = json_value(issue.body),
        user = json_value(issue.user),
        assignee = assignee,
        assignees = json_value(issue.assignees) or {},
        labels = json_value(issue.labels) or {},
        state = state,
        html_url = json_value(issue.html_url),
        created_at = json_value(issue.created_at),
        updated_at = json_value(issue.updated_at),
        pull_request = pull_request and {
          merged = json_value(pull_request.merged) == true
            or json_value(pull_request.merged_at) ~= nil,
        } or nil,
      },
    },
  }
end

function M.repository_issues(repository, opts, callback)
  opts = opts or {}
  local ttl = opts.cache_ttl or 300
  local page = math.max(1, math.floor(opts.page or 1))

  local per_page = math.min(
    100,
    math.max(1, math.floor(opts.per_page or 100))
  )

  local state = opts.issue_state == "closed" and "closed"
    or opts.issue_state == "all" and "all"
    or "open"

  local cache_key = table.concat({
    repository:lower(),
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
    "https://api.github.com/repos/%s/issues"
      .. "?state=%s&sort=updated&direction=desc&per_page=%d&page=%d"
  ):format(repository, state, per_page, page)

  request_json(url, opts, function(issues, err)
    if not issues then
      callback(nil, err)
      return
    end

    local events = {}

    for _, issue in ipairs(issues) do
      local normalized = project_issue_event(repository, issue)

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

local function project_milestone(milestone, html_url)
  if type(milestone) ~= "table" or not json_value(milestone.number) then
    return nil
  end

  local id = milestone.number

  return {
    id = id,
    title = json_value(milestone.title) or ("Milestone " .. tostring(id)),
    description = json_value(milestone.description),
    state = milestone.state == "closed" and "closed" or "open",
    open_issues = tonumber(json_value(milestone.open_issues)) or 0,
    closed_issues = tonumber(json_value(milestone.closed_issues)) or 0,
    due_on = json_value(milestone.due_on),
    closed_at = json_value(milestone.closed_at),
    html_url = html_url,
  }
end

function M.repository_milestones(repository, opts, callback)
  opts = opts or {}
  local ttl = opts.cache_ttl or 300
  local cache_key = repository:lower()
  local cached = repository_milestone_cache[cache_key]

  if cached
    and not opts.force
    and os.time() - cached.fetched_at < ttl
  then
    vim.schedule(function()
      callback(vim.deepcopy(cached.milestones), nil, true)
    end)

    return
  end

  local milestones = {}
  local page = 1
  local max_pages = 10

  local function load_page()
    local url = (
      "https://api.github.com/repos/%s/milestones"
        .. "?state=all&sort=due_on&direction=asc&per_page=100&page=%d"
    ):format(repository, page)

    request_json(url, opts, function(results, err)
      if not results then
        callback(nil, err)
        return
      end

      for _, milestone in ipairs(results) do
        local normalized = project_milestone(milestone, json_value(milestone.html_url))

        if normalized then
          milestones[#milestones + 1] = normalized
        end
      end

      if #results == 100 and page < max_pages then
        page = page + 1
        load_page()
        return
      end

      repository_milestone_cache[cache_key] = {
        milestones = vim.deepcopy(milestones),
        fetched_at = os.time(),
      }

      callback(vim.deepcopy(milestones), nil, false)
    end)
  end

  load_page()
end

-- Returns the issues and pull requests in a milestone as issue events, in the
-- same shape as M.repository_issues.
function M.milestone_issues(repository, milestone_id, opts, callback)
  opts = opts or {}
  local ttl = opts.cache_ttl or 300
  local page = math.max(1, math.floor(opts.page or 1))

  local per_page = math.min(
    100,
    math.max(1, math.floor(opts.per_page or 100))
  )

  local cache_key = table.concat({
    repository:lower(),
    "milestone",
    tostring(milestone_id),
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
    "https://api.github.com/repos/%s/issues"
      .. "?milestone=%s&state=all&sort=updated&direction=desc"
      .. "&per_page=%d&page=%d"
  ):format(repository, tostring(milestone_id), per_page, page)

  request_json(url, opts, function(issues, err)
    if not issues then
      callback(nil, err)
      return
    end

    local events = {}

    for _, issue in ipairs(issues) do
      local normalized = project_issue_event(repository, issue, true)

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

local function project_commit_event(repository, commit)
  local details = type(commit.commit) == "table" and commit.commit or {}
  local author = type(details.author) == "table" and details.author or {}
  local account = type(commit.author) == "table" and commit.author or nil
  local sha = commit.sha

  if type(sha) ~= "string" or sha == "" then
    return
  end

  return {
    id = "project-commit:" .. sha,
    type = "PushEvent",
    actor = account or { name = author.name },
    repo = { name = repository },
    created_at = author.date,
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

local function project_pull_request_event(repository, pull_request)
  local number = pull_request.number
  local merged_at = pull_request.merged_at

  if not number or type(merged_at) ~= "string" or merged_at == "" then
    return
  end

  return {
    id = ("project-pr:%s:%s"):format(repository, number),
    type = "PullRequestEvent",
    actor = pull_request.merged_by,
    repo = { name = repository },
    created_at = merged_at,
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

function M.repository_updates(repository, opts, callback)
  opts = opts or {}
  local enabled = {}

  for _, category in ipairs(opts.activity_types or {}) do
    enabled[category] = true
  end

  local page = math.max(1, math.floor(opts.page or 1))

  local per_page = math.min(
    100,
    math.max(1, math.floor(opts.per_page or 100))
  )

  local categories = {}

  if enabled.push then
    categories[#categories + 1] = "push"
  end

  if enabled.merged_pull_request then
    categories[#categories + 1] = "merged_pull_request"
  end

  local key = table.concat({
    repository:lower(),
    tostring(page),
    table.concat(categories, ","),
  }, ":")

  local cached = repository_update_cache[key]
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
      return tostring(left.created_at or "") > tostring(right.created_at or "")
    end)

    if #events == 0 and #errors == #categories then
      callback(nil, table.concat(errors, "; "))
      return
    end

    repository_update_cache[key] = {
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
      "https://api.github.com/repos/%s/commits?per_page=%d&page=%d"
    ):format(repository, per_page, page)

    request_json(url, opts, function(commits, err)
      if commits then
        for _, commit in ipairs(commits) do
          local normalized = project_commit_event(repository, commit)

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
      "https://api.github.com/repos/%s/pulls"
        .. "?state=closed&sort=updated&direction=desc"
        .. "&per_page=%d&page=%d"
    ):format(repository, per_page, page)

    request_json(url, opts, function(pull_requests, err)
      if pull_requests then
        for _, pull_request in ipairs(pull_requests) do
          local normalized = project_pull_request_event(
            repository,
            pull_request
          )

          if normalized then
            events[#events + 1] = normalized
          end
        end
      else
        errors[#errors + 1] = err or "could not load merged pull requests"
      end

      complete()
    end)
  end
end

local function push_key(event)
  local payload = event.payload or {}
  local repo = event.repo and event.repo.name

  if
    not repo
    or not payload.before
    or not payload.head
    or payload.before:match("^0+$")
  then
    return nil
  end

  return ("%s:%s:%s"):format(repo, payload.before, payload.head)
end

local function apply_push_details(event, details)
  event.payload = event.payload or {}
  event.payload.size = details.count
  event.payload.commits = details.commits
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

  local expected = tonumber(payload.size or payload.distinct_size)
  return expected ~= nil and expected > #commits
end

function M.apply_push_comparison(event, comparison)
  local commits = {}

  for _, commit in ipairs(comparison.commits or {}) do
    commits[#commits + 1] = {
      sha = commit.sha,
      message = commit.commit and commit.commit.message or nil,
    }
  end

  apply_push_details(event, {
    count = comparison.total_commits or #commits,
    commits = commits,
  })

  return event
end

local function pull_request_key(event)
  if
    event.type ~= "PullRequestEvent"
    and event.type ~= "PullRequestReviewEvent"
  then
    return nil
  end

  local repo = event.repo and event.repo.name
  local payload = event.payload or {}
  local pull_request = payload.pull_request or {}
  local number = pull_request.number or payload.number

  if not repo or not number then
    return nil
  end

  local merged = payload.action == "merged"
    or (payload.action == "closed" and (
      pull_request.merged == true
      or (type(pull_request.merged_at) == "string" and pull_request.merged_at ~= "")
      or type(pull_request.merged_by) == "table"
    ))

  local author = type(pull_request.user) == "table" and pull_request.user
    or (type(pull_request.author) == "table" and pull_request.author)
    or nil

  local merger = type(pull_request.merged_by) == "table" and pull_request.merged_by or nil

  if pull_request.title
    and (not merged or (author and merger))
  then
    return nil
  end

  return ("%s#%s"):format(repo, number), repo, number
end

local function apply_pull_request_details(event, details)
  event.payload = event.payload or {}
  event.payload.pull_request = event.payload.pull_request or {}

  event.payload.pull_request.title = event.payload.pull_request.title
    or details.title

  event.payload.pull_request.number = event.payload.pull_request.number
    or details.number

  event.payload.pull_request.html_url = event.payload.pull_request.html_url
    or details.html_url

  if not event.payload.pull_request.user and details.author then
    event.payload.pull_request.user = { login = details.author }
  end

  if not event.payload.pull_request.merged_by and details.merged_by then
    event.payload.pull_request.merged_by = { login = details.merged_by }
  end

  if details.merged_by then
    event.actor = { login = details.merged_by }
  end
end

function M.apply_pull_request(event, pull_request)
  apply_pull_request_details(event, {
    number = pull_request.number,
    title = pull_request.title,
    html_url = pull_request.html_url,
    author = type(pull_request.user) == "table" and pull_request.user.login or nil,
    merged_by = type(pull_request.merged_by) == "table" and pull_request.merged_by.login or nil,
  })

  return event
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
    local key, repo, number = pull_request_key(event)

    if key then
      local cached = pull_request_cache[key]

      if type(cached) == "table" then
        apply_pull_request_details(event, cached)
      elseif cached == nil then
        pending = pending + 1

        local url = ("https://api.github.com/repos/%s/pulls/%s"):format(
          repo,
          number
        )

        request_json(url, opts, function(pull_request)
          if pull_request and pull_request.title then
            local details = {
              number = pull_request.number or number,
              title = pull_request.title,
              html_url = pull_request.html_url,
              author = type(pull_request.user) == "table"
                  and pull_request.user.login
                or nil,
              merged_by = type(pull_request.merged_by) == "table"
                  and pull_request.merged_by.login
                or nil,
            }

            pull_request_cache[key] = details
            apply_pull_request_details(event, details)
          else
            pull_request_cache[key] = false
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
      local key = push_key(event)

      if key then
        selected = selected + 1
        local cached = push_cache[key]

        if type(cached) == "table" then
          apply_push_details(event, cached)
        elseif cached == nil then
          pending = pending + 1
          local repo = event.repo.name
          local payload = event.payload

          local url = (
            "https://api.github.com/repos/%s/compare/%s...%s"
          ):format(repo, payload.before, payload.head)

          request_json(url, opts, function(comparison)
            if comparison then
              M.apply_push_comparison(event, comparison)

              local details = {
                count = event.payload.size,
                commits = event.payload.commits,
              }

              push_cache[key] = details
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

local function requested_reviewers(pull_request)
  local reviewers = {}

  for _, user in ipairs(json_value(pull_request.requested_reviewers) or {}) do
    if type(user) == "table" and type(user.login) == "string" then
      reviewers[#reviewers + 1] = user.login
    end
  end

  for _, team in ipairs(json_value(pull_request.requested_teams) or {}) do
    if type(team) == "table" and type(team.slug) == "string" then
      reviewers[#reviewers + 1] = team.slug
    end
  end

  return reviewers
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

  local url = ("https://api.github.com/repos/%s/pulls/%s"):format(
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

    if not base.sha or not head.sha then
      callback(nil, "GitHub returned a pull request without base/head commits")
      return
    end

    local details = {
      number = pull_request.number or number,
      title = pull_request.title,
      body = pull_request.body,
      author = type(pull_request.user) == "table"
          and pull_request.user.login
        or nil,
      state = pull_request.state,
      draft = pull_request.draft,
      merged = pull_request.merged,
      html_url = pull_request.html_url,
      created_at = pull_request.created_at,
      base_sha = base.sha,
      base_ref = base.ref,
      head_sha = head.sha,
      head_ref = head.ref,
      commit_count = pull_request.commits,
      mergeable = json_value(pull_request.mergeable),
      mergeable_state = json_value(pull_request.mergeable_state),
      requested_reviewers = requested_reviewers(pull_request),
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
      "https://api.github.com/repos/%s/pulls/%s/commits"
        .. "?per_page=100&page=%d"
    ):format(repo, number, page)

    request_json(url, opts, function(results, err)
      if not results then
        callback(nil, err)
        return
      end

      vim.list_extend(commits, results)

      if #results == 100 and #commits < 250 then
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

local review_states = {
  APPROVED = "approved",
  CHANGES_REQUESTED = "changes_requested",
  COMMENTED = "commented",
  DISMISSED = "dismissed",
}

-- Groups pull request review comments into threads. resolutions maps a
-- thread's first comment id to { resolved, outdated } from the GraphQL API.
function M.review_threads(comments, resolutions)
  local threads = {}
  local thread_for_comment = {}

  for _, comment in ipairs(comments or {}) do
    local user = json_value(comment.user)

    local entry = {
      author = type(user) == "table" and user.login or nil,
      body = json_value(comment.body),
      created_at = json_value(comment.created_at),
      url = json_value(comment.html_url),
    }

    local parent = thread_for_comment[json_value(comment.in_reply_to_id)]

    if parent then
      parent.comments[#parent.comments + 1] = entry
    elseif type(comment.path) == "string" then
      -- GitHub drops the current line once a comment no longer applies to
      -- the head, leaving only the line in the commit it was written on.
      local line = json_value(comment.line)

      parent = {
        id = tostring(comment.id),
        path = comment.path,
        side = comment.side == "LEFT" and "parent" or "change",
        line = comment.subject_type ~= "file"
            and (line or json_value(comment.original_line))
          or nil,
        commit = line and json_value(comment.commit_id)
          or json_value(comment.original_commit_id),
        outdated = line == nil and comment.subject_type ~= "file",
        resolved = false,
        url = entry.url,
        comments = { entry },
      }

      local resolution = resolutions and resolutions[parent.id]

      if resolution then
        parent.resolved = resolution.resolved == true
        parent.outdated = resolution.outdated == true
      end

      threads[#threads + 1] = parent
    end

    if parent and comment.id then
      thread_for_comment[comment.id] = parent
    end
  end

  return threads
end

local function check_run_state(run)
  if run.status ~= "completed" then
    return "pending"
  end

  local conclusion = json_value(run.conclusion)

  if conclusion == "success" then
    return "success"
  end

  if conclusion == "neutral" or conclusion == "skipped" or conclusion == "stale" then
    return "skipped"
  end

  return "failure"
end

local function status_state(status)
  if status.state == "success" or status.state == "pending" then
    return status.state
  end

  return "failure"
end

local function request_pages(url, per_page, max_pages, opts, callback)
  local results = {}
  local page = 1

  local function load_page()
    local separator = url:find("?", 1, true) and "&" or "?"

    request_json(
      ("%s%sper_page=%d&page=%d"):format(url, separator, per_page, page),
      opts,
      function(items, err)
        if not items then
          callback(nil, err)
          return
        end

        vim.list_extend(results, items)

        if #items == per_page and page < max_pages then
          page = page + 1
          load_page()
          return
        end

        callback(results)
      end
    )
  end

  load_page()
end

local review_threads_query = [[
query($owner: String!, $name: String!, $number: Int!, $cursor: String) {
  repository(owner: $owner, name: $name) {
    pullRequest(number: $number) {
      reviewThreads(first: 100, after: $cursor) {
        pageInfo { hasNextPage endCursor }
        nodes {
          isResolved
          isOutdated
          comments(first: 1) { nodes { databaseId } }
        }
      }
    }
  }
}
]]

-- Thread resolution needs the GraphQL API, which always needs a token.
local function thread_resolutions(repo, number, opts, callback)
  if not require("oculus.auth").github_token(opts) then
    callback(nil)
    return
  end

  local owner, name = repo:match("^([^/]+)/(.+)$")
  local resolutions = {}
  local pages = 0

  local function load_page(cursor)
    pages = pages + 1

    request_json("https://api.github.com/graphql", opts, function(payload)
      local connection = type(payload) == "table"
        and type(payload.data) == "table"
        and vim.tbl_get(payload.data, "repository", "pullRequest", "reviewThreads")

      if type(connection) ~= "table" then
        callback(nil)
        return
      end

      for _, node in ipairs(connection.nodes or {}) do
        local first = vim.tbl_get(node, "comments", "nodes", 1, "databaseId")

        if first then
          resolutions[tostring(first)] = {
            resolved = node.isResolved,
            outdated = node.isOutdated,
          }
        end
      end

      local page_info = connection.pageInfo or {}

      if page_info.hasNextPage == true and pages < 5 then
        load_page(page_info.endCursor)
        return
      end

      callback(resolutions)
    end, {
      body = {
        query = review_threads_query,
        variables = {
          owner = owner,
          name = name,
          number = tonumber(number),
          cursor = cursor,
        },
      },
    })
  end

  load_page(vim.NIL)
end

-- Reviews, inline review threads and head commit checks for a pull request.
-- Checks and thread resolution are best effort; a token without access to
-- them still loads the reviews and threads.
function M.pull_request_review(repo, number, head_sha, opts, callback)
  opts = opts or {}
  local remaining = 5
  local failed = false
  local reviews, comments, runs, statuses, resolutions

  local function finish(err)
    if failed then
      return
    end

    if err then
      failed = true
      callback(nil, err)
      return
    end

    remaining = remaining - 1

    if remaining > 0 then
      return
    end

    local result = { reviews = {}, checks = {} }

    for _, review in ipairs(reviews) do
      local state = review_states[review.state]
      local user = json_value(review.user)

      if state and type(user) == "table" then
        result.reviews[#result.reviews + 1] = {
          author = user.login,
          state = state,
          submitted_at = json_value(review.submitted_at),
        }
      end
    end

    for _, run in ipairs(runs or {}) do
      result.checks[#result.checks + 1] = {
        name = run.name,
        state = check_run_state(run),
        url = json_value(run.html_url),
      }
    end

    for _, status in ipairs(statuses or {}) do
      result.checks[#result.checks + 1] = {
        name = status.context,
        state = status_state(status),
        url = json_value(status.target_url),
      }
    end

    result.threads = M.review_threads(comments, resolutions)
    callback(result)
  end

  local base = ("https://api.github.com/repos/%s"):format(repo)

  request_pages(base .. "/pulls/" .. number .. "/reviews", 100, 3, opts, function(items, err)
    reviews = items
    finish(err and ("could not load reviews: " .. err))
  end)

  request_pages(base .. "/pulls/" .. number .. "/comments", 100, 5, opts, function(items, err)
    comments = items
    finish(err and ("could not load review comments: " .. err))
  end)

  if type(head_sha) == "string" and head_sha ~= "" then
    request_json(base .. "/commits/" .. head_sha .. "/check-runs?per_page=100", opts, function(payload)
      runs = type(payload) == "table" and payload.check_runs or nil
      finish()
    end)

    request_json(base .. "/commits/" .. head_sha .. "/status?per_page=100", opts, function(payload)
      statuses = type(payload) == "table" and payload.statuses or nil
      finish()
    end)
  else
    remaining = remaining - 2
  end

  thread_resolutions(repo, number, opts, function(result)
    resolutions = result
    finish()
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

  local url = ("https://api.github.com/repos/%s/issues/%s"):format(
    repo,
    number
  )

  request_json(url, opts, function(issue, err)
    if not issue then
      callback(nil, err)
      return
    end

    if issue.pull_request then
      callback(nil, "this issue URL refers to a pull request")
      return
    end

    local details = {
      number = issue.number or number,
      title = issue.title,
      body = issue.body,
      author = type(issue.user) == "table" and issue.user.login or nil,
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

function M.commit_sha(repo, sha, opts, callback)
  opts = opts or {}

  local url = ("https://api.github.com/repos/%s/commits?sha=%s&per_page=1")
    :format(repo, sha)

  request_json(url, opts, function(commits, err)
    local commit = type(commits) == "table" and commits[1] or nil
    local full = type(commit) == "table" and commit.sha or nil

    if type(full) ~= "string"
      or full:sub(1, #sha):lower() ~= sha:lower()
    then
      callback(nil, err or ("GitHub: no commit matches " .. sha))
      return
    end

    callback(full:lower())
  end)
end

local repository_info_cache = {}

function M.repository_info(repository, opts, callback)
  opts = opts or {}
  local ttl = opts.cache_ttl or 300
  local key = repository:lower()
  local cached = repository_info_cache[key]

  if not opts.force
    and cached
    and os.time() - cached.fetched_at < ttl
  then
    vim.schedule(function()
      callback(vim.deepcopy(cached.info))
    end)

    return
  end

  local url = ("https://api.github.com/repos/%s"):format(repository)

  request_json(url, opts, function(payload, err)
    if err or type(payload) ~= "table" then
      callback(nil, err)
      return
    end

    local info = {
      description = type(payload.description) == "string"
          and payload.description
        or nil,
      name = payload.name,
      full_name = payload.full_name,
    }

    repository_info_cache[key] = {
      fetched_at = os.time(),
      info = info,
    }

    callback(vim.deepcopy(info))
  end)
end

function M.viewer(opts, callback)
  request_json("https://api.github.com/user", opts or {}, function(user, err)
    local login = type(user) == "table" and json_value(user.login) or nil

    if type(login) ~= "string" or login == "" then
      callback(nil, err or "GitHub returned no signed-in user")
      return
    end

    callback({
      provider = "github",
      login = login,
      name = json_value(user.name),
      html_url = json_value(user.html_url),
      avatar_url = json_value(user.avatar_url),
    })
  end)
end

local work_queries = {
  review_requested = "is:open is:pr archived:false review-requested:@me",
  authored = "is:open is:pr archived:false author:@me",
  assigned = "is:open archived:false assignee:@me",
  mentioned = "is:open archived:false mentions:@me",
}

-- Open issues and pull requests that involve the signed-in user, as issue
-- events in the shape of M.repository_issues, most recently updated first. The
-- callback's fifth argument is the total number of matches.
function M.work_items(category, opts, callback)
  opts = opts or {}
  local query = work_queries[category]
  local token = require("oculus.auth").github_token(opts)

  if not query or not token then
    vim.schedule(function()
      callback(nil, query and ("Not signed in to GitHub: " .. require("oculus.auth").sign_in_hint("github"))
        or ("unknown work category " .. tostring(category)))
    end)

    return
  end

  local ttl = opts.cache_ttl or 300
  local page = math.max(1, math.floor(opts.page or 1))
  local per_page = math.min(100, math.max(1, math.floor(opts.per_page or 50)))

  -- Results belong to the account behind the token, so key them by it.
  local cache_key = table.concat({
    "work",
    vim.fn.sha256(token):sub(1, 16),
    category,
    tostring(page),
    tostring(per_page),
  }, ":")

  local cached = repository_issue_cache[cache_key]

  if cached and not opts.force and os.time() - cached.fetched_at < ttl then
    vim.schedule(function()
      callback(vim.deepcopy(cached.events), nil, true, cached.complete, cached.total)
    end)

    return
  end

  local url = (
    "https://api.github.com/search/issues"
      .. "?q=%s&sort=updated&order=desc&per_page=%d&page=%d&advanced_search=true"
  ):format(vim.uri_encode(query), per_page, page)

  request_json(url, opts, function(result, err)
    if type(result) ~= "table" or type(json_value(result.items)) ~= "table" then
      callback(nil, err or "GitHub returned no search results")
      return
    end

    local events = {}

    for _, issue in ipairs(result.items) do
      local repository = type(issue) == "table"
          and type(json_value(issue.repository_url)) == "string"
          and issue.repository_url:match("/repos/([^/]+/[^/]+)$")
        or nil

      local normalized = repository and project_issue_event(repository, issue, true)

      if normalized then
        events[#events + 1] = normalized
      end
    end

    local total = tonumber(json_value(result.total_count))
    local complete = #result.items < per_page or (total ~= nil and page * per_page >= total)

    repository_issue_cache[cache_key] = {
      events = vim.deepcopy(events),
      fetched_at = os.time(),
      complete = complete,
      total = total,
    }

    callback(events, nil, false, complete, total)
  end)
end

function M.clear(username)
  cache[username] = nil
end

M._project_commit_event = project_commit_event
M._project_pull_request_event = project_pull_request_event
M._pull_request_key = pull_request_key
M._push_needs_enrichment = push_needs_enrichment
return M
