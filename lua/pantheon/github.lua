local M = {}

local cache = {}
local push_cache = {}

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
      callback(nil, "Pantheon requires curl to load GitHub activity")
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
    "User-Agent: pantheon.nvim",
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

  if not opts.force and cached and os.time() - cached.fetched_at < ttl then
    vim.schedule(function()
      callback(cached.events, nil, true)
    end)
    return
  end

  local url = (
    "https://api.github.com/users/%s/events/public?per_page=%d"
  ):format(username, opts.per_page or 30)
  request_json(url, opts, function(events, err)
    if not events then
      callback(nil, err)
      return
    end
    cache[username] = { events = events, fetched_at = os.time() }
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

function M.clear(username)
  cache[username] = nil
end

return M
