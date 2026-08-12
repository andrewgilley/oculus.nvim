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

local function request_json(url, opts, callback)
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

  local token = opts.token or vim.env.GITHUB_TOKEN
  local stdin
  if token and token ~= "" then
    vim.list_extend(command, { "-H", "@-" })
    stdin = "Authorization: Bearer " .. token .. "\n"
  end
  command[#command + 1] = url

  vim.system(command, { text = true, stdin = stdin }, function(result)
    vim.schedule(function()
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
      callback(cached.events, nil, true, cached.complete)
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
    callback(events, nil, false, complete)
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
      #events < per_page
    )
  end)
end

local function project_issue_event(repository, issue)
  if type(issue) ~= "table" or issue.pull_request or not issue.number then
    return nil
  end
  local state = issue.state == "closed" and "closed" or "open"
  return {
    id = ("project-issue:%s:%s"):format(repository, issue.number),
    type = "IssuesEvent",
    actor = issue.user,
    repo = { name = repository },
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
      or pull_request.merged_at ~= nil
      or pull_request.merged_by ~= nil
    ))
  local author = pull_request.user or pull_request.author
  local merger = pull_request.merged_by or event.actor
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
end

function M.apply_pull_request(event, pull_request)
  apply_pull_request_details(event, {
    number = pull_request.number,
    title = pull_request.title,
    html_url = pull_request.html_url,
    author = pull_request.user and pull_request.user.login,
    merged_by = pull_request.merged_by and pull_request.merged_by.login,
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
              author = pull_request.user and pull_request.user.login,
              merged_by = pull_request.merged_by
                and pull_request.merged_by.login,
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
      author = pull_request.user and pull_request.user.login,
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
      author = issue.user and issue.user.login,
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

M._project_commit_event = project_commit_event
M._project_pull_request_event = project_pull_request_event
M._push_needs_enrichment = push_needs_enrichment

return M
