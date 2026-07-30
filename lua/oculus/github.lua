local M = {}

local cache = {}
local push_cache = {}
local pull_request_cache = {}
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
  local cached = cache[username]
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
      callback(cached.events, nil, true)
    end)
    return
  end

  local url = (
    "https://api.github.com/users/%s/events/public?per_page=%d"
  ):format(username, per_page)
  request_json(url, opts, function(events, err)
    if not events then
      callback(nil, err)
      return
    end
    cache[username] = {
      events = events,
      fetched_at = os.time(),
      per_page = per_page,
      complete = #events < per_page,
    }
    callback(events, nil, false)
  end)
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
  if not repo or not number or pull_request.title then
    return nil
  end
  return ("%s#%s"):format(repo, number), repo, number
end

local function apply_pull_request_details(event, details)
  event.payload = event.payload or {}
  event.payload.pull_request = event.payload.pull_request or {}
  event.payload.pull_request.title = details.title
  event.payload.pull_request.number = event.payload.pull_request.number
    or details.number
  event.payload.pull_request.html_url = event.payload.pull_request.html_url
    or details.html_url
end

function M.apply_pull_request(event, pull_request)
  apply_pull_request_details(event, {
    number = pull_request.number,
    title = pull_request.title,
    html_url = pull_request.html_url,
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
    if
      event.type == "PushEvent"
      and not (event.payload and event.payload.commits)
    then
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
