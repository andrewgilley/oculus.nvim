local M = {}

function M.git_error(result, fallback)
  local message = vim.trim(result.stderr or "")

  if message == "" then
    message = fallback
  end

  return message
end

function M.run(command, callback)
  vim.system(command, { text = true }, function(result)
    vim.schedule(function()
      if result.code ~= 0 then
        callback(nil, M.git_error(result, "git command failed"))
        return
      end

      callback(vim.trim(result.stdout or ""))
    end)
  end)
end

function M.run_raw(command, callback)
  vim.system(command, { text = true }, function(result)
    vim.schedule(function()
      if result.code ~= 0 then
        callback(nil, M.git_error(result, "git command failed"))
        return
      end

      callback(result.stdout or "")
    end)
  end)
end

function M.map_concurrently(items, limit, worker, callback)
  local count = #items

  if count == 0 then
    callback({})
    return
  end

  limit = math.max(1, math.floor(tonumber(limit) or 1))
  local results = {}
  local completed = {}
  local next_index = 1
  local active_count = 0
  local completed_count = 0
  local stopped = false
  local pumping = false
  local repump = false
  local pump

  local function finish(index, result, err)
    if stopped or completed[index] then
      return
    end

    completed[index] = true
    active_count = active_count - 1

    if err then
      stopped = true
      callback(nil, err)
      return
    end

    results[index] = result
    completed_count = completed_count + 1

    if completed_count == count then
      stopped = true
      callback(results)
      return
    end

    pump()
  end

  pump = function()
    if stopped then
      return
    end

    if pumping then
      repump = true
      return
    end

    pumping = true

    repeat
      repump = false

      while not stopped
        and active_count < limit
        and next_index <= count
      do
        local index = next_index
        next_index = next_index + 1
        active_count = active_count + 1

        worker(items[index], index, function(result, err)
          finish(index, result, err)
        end)
      end
    until not repump

    pumping = false
  end

  pump()
end

function M.directory(path)
  return path and vim.fn.isdirectory(path) == 1
end

function M.inspection_directory(repository, file)
  if not repository or not file or file == "" then
    return repository
  end

  local full_path = vim.fs.joinpath(repository, file)
  return M.directory(full_path) and full_path or vim.fs.dirname(full_path)
end

function M.forge_repository(url)
  if not url or url == "" then
    return nil
  end

  local patterns = {
    "^https?://github%.com/([^/]+/[^/#?]+)",
    "^https?://codeberg%.org/([^/]+/[^/#?]+)",
    "^git@github%.com:([^/]+/[^/#?]+)",
    "^git@codeberg%.org:([^/]+/[^/#?]+)",
    "^ssh://git@github%.com/([^/]+/[^/#?]+)",
    "^ssh://git@codeberg%.org/([^/]+/[^/#?]+)",
  }

  for _, pattern in ipairs(patterns) do
    local repository = url:match(pattern)

    if repository then
      return repository:gsub("%.git$", "")
    end
  end

  return nil
end

function M.github_repository(url)
  return M.forge_repository(url)
end

function M.repository_root(path)
  if not M.directory(path) then
    path = vim.fs.dirname(path)
  end

  if not path or path == "" or not M.directory(path) then
    return nil
  end

  local git_dir = vim.fs.find(".git", { path = path, upward = true })[1]
  return git_dir and vim.fs.dirname(git_dir) or nil
end

function M.local_candidates(info, opts)
  local explicit_roots = {}
  local candidates = {}
  local seen = {}

  local function add(path, explicit, search_path)
    if not path or path == "" then
      return
    end

    local candidate = vim.fs.normalize(path)
    local key = candidate:lower()

    if seen[key] then
      if explicit then
        seen[key].explicit = true
      end
      if search_path then
        seen[key].search_path = true
      end
      return
    end

    local entry = {
      path = candidate,
      explicit = explicit or false,
      search_path = search_path or false,
    }
    seen[key] = entry
    candidates[#candidates + 1] = entry
  end

  local function add_search_path(path)
    if not path or path == "" or not M.directory(path) then
      return
    end

    local base = vim.fs.normalize(path)
    add(base, false, true)

    if info and info.repository then
      local parts = vim.split(info.repository, "/")
      local org = parts[1]
      local name = parts[2]

      if name then
        add(vim.fs.joinpath(base, name), false, true)
      end

      if org and name then
        add(vim.fs.joinpath(base, org, name), false, true)
      end
    end

    local handle = vim.uv.fs_scandir(base)
    if handle then
      while true do
        local name, type = vim.uv.fs_scandir_next(handle)
        if not name then
          break
        end

        if type == "directory" then
          local child = vim.fs.joinpath(base, name)
          add(child, false, true)

          if info and info.repository then
            local repo_parts = vim.split(info.repository, "/")
            local repo_name = repo_parts[2]
            if repo_name then
              add(vim.fs.joinpath(child, repo_name), false, true)
            end
          end
        end
      end
    end
  end

  for _, repo in ipairs((opts and opts.inspect_repositories) or {}) do
    if type(repo) == "table" and repo.path then
      add(repo.path, true, false)
      explicit_roots[#explicit_roots + 1] = vim.fs.normalize(repo.path)
    elseif type(repo) == "string" then
      add(repo, true, false)
      explicit_roots[#explicit_roots + 1] = vim.fs.normalize(repo)
    end
  end

  if info and info.repository and opts and opts.inspect_repositories then
    local repo_config = opts.inspect_repositories[info.repository]
    if type(repo_config) == "string" then
      add(repo_config, true, false)
    elseif type(repo_config) == "table" and repo_config.path then
      add(repo_config.path, true, false)
    end
  end

  local cwd = vim.fn.getcwd()
  add(cwd, false, false)
  local current_root = M.repository_root(cwd)
  if current_root then
    add(current_root, false, false)
  end

  for _, path in ipairs((opts and opts.inspect_search_paths) or {}) do
    add_search_path(path)
  end

  return candidates
end

function M.find_local_repository(info, opts, callback)
  local candidates = M.local_candidates(info, opts)
  local verified_candidates = {}

  local function matching_remote(remotes)
    if not info or not info.repository then
      return false
    end

    local target_repo = info.repository:lower()

    for _, remote in ipairs(vim.split(remotes, "\n")) do
      local forge_repo = M.forge_repository(remote)
      if forge_repo and forge_repo:lower() == target_repo then
        return true
      end
    end

    return false
  end

  local function contains_target(candidate, target_callback)
    if not info then
      target_callback(false)
      return
    end

    local revision = info.sha or info.head or info.base
    if not revision then
      target_callback(true)
      return
    end

    M.run({ "git", "-C", candidate.path, "cat-file", "-e", revision .. "^{commit}" }, function(stdout, err)
      target_callback(err == nil)
    end)
  end

  M.map_concurrently(candidates, 4, function(candidate, _, worker_callback)
    if not M.directory(candidate.path) then
      worker_callback(nil)
      return
    end

    M.run({ "git", "-C", candidate.path, "remote", "-v" }, function(remotes, err)
      if err or not remotes then
        worker_callback(nil)
        return
      end

      if matching_remote(remotes) then
        contains_target(candidate, function(has_target)
          worker_callback({
            path = candidate.path,
            has_target = has_target,
            explicit = candidate.explicit,
            search_path = candidate.search_path,
          })
        end)
      else
        worker_callback(nil)
      end
    end)
  end, function(results)
    for _, result in ipairs(results or {}) do
      if result then
        verified_candidates[#verified_candidates + 1] = result
      end
    end

    for _, candidate in ipairs(verified_candidates) do
      if candidate.has_target then
        callback(candidate.path)
        return
      end
    end

    for _, candidate in ipairs(verified_candidates) do
      if candidate.explicit then
        callback(candidate.path)
        return
      end
    end

    for _, candidate in ipairs(verified_candidates) do
      if not candidate.search_path then
        callback(candidate.path)
        return
      end
    end

    if #verified_candidates > 0 then
      callback(verified_candidates[1].path)
      return
    end

    callback(nil)
  end)
end

function M.download_destination(info, opts)
  local source_root = ((opts and opts.inspect_search_paths) or {})[1]
    or vim.fn.stdpath("data")

  if not info or not info.repository then
    return vim.fs.joinpath(source_root, "oculus-inspections")
  end

  return vim.fs.joinpath(source_root, info.repository)
end

function M.offer_repository_download(info, opts, callback)
  local destination = M.download_destination(info, opts)

  local prompt = string.format(
    "Local clone of %s not found. Clone to %s? [y/N] ",
    info.repository or "repository",
    destination
  )

  vim.ui.input({ prompt = prompt }, function(input)
    if not input or not input:match("^[yY]") then
      callback(nil, "repository clone aborted")
      return
    end

    local clone_url = info.provider == "codeberg"
        and string.format("https://codeberg.org/%s.git", info.repository)
      or string.format("https://github.com/%s.git", info.repository)

    vim.fn.mkdir(vim.fs.dirname(destination), "p")

    M.run({ "git", "clone", clone_url, destination }, function(output, err)
      if err then
        callback(nil, "git clone failed: " .. err)
        return
      end

      callback(destination)
    end)
  end)
end

function M.ensure_repository(info, opts, callback)
  M.find_local_repository(info, opts, function(repository)
    if repository then
      callback(repository)
      return
    end

    M.offer_repository_download(info, opts, callback)
  end)
end

function M.resolve_revision(repository, revision, callback)
  if not revision or revision == "" then
    callback(nil, "missing revision")
    return
  end

  M.run({ "git", "-C", repository, "rev-parse", "--verify", revision .. "^{commit}" }, function(sha, err)
    if err then
      callback(nil, err)
      return
    end

    callback(sha)
  end)
end

function M.resolve_pair(repository, info, callback)
  local base_ref = info.base or (info.sha and info.sha .. "~1") or "HEAD~1"
  local head_ref = info.head or info.sha or "HEAD"

  M.resolve_revision(repository, base_ref, function(base_sha, base_err)
    if base_err then
      callback(nil, base_err)
      return
    end

    M.resolve_revision(repository, head_ref, function(head_sha, head_err)
      if head_err then
        callback(nil, head_err)
        return
      end

      callback({
        base = base_sha,
        head = head_sha,
      })
    end)
  end)
end

function M.fetch_pair(repository, fetch_source, info, callback)
  local remote_url = fetch_source
  if not remote_url then
    callback(true)
    return
  end

  M.run({ "git", "-C", repository, "fetch", remote_url }, function(_, err)
    if err then
      callback(nil, err)
      return
    end

    callback(true)
  end)
end

function M.revision_pairs(repository, info, commits, callback)
  if not commits or #commits == 0 then
    M.resolve_pair(repository, info, function(pair, err)
      if err then
        callback(nil, err)
        return
      end

      callback({ pair })
    end)
    return
  end

  local pairs = {}
  for _, commit in ipairs(commits) do
    pairs[#pairs + 1] = {
      base = commit.sha .. "~1",
      head = commit.sha,
      message = commit.commit and commit.commit.message,
      author = commit.commit and commit.commit.author,
    }
  end

  callback(pairs)
end

return M
