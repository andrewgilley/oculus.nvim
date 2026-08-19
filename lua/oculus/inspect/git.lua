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
  local stat = vim.uv.fs_stat(path)
  return stat and stat.type == "directory"
end

function M.inspection_directory(repository, file)
  if not file then
    return repository
  end

  local parent = vim.fs.dirname(vim.fs.joinpath(repository, file))
  return M.directory(parent) and parent or repository
end

function M.forge_repository(url)
  if type(url) ~= "string" then
    return nil
  end

  local forge
  local owner
  local repo

  for _, candidate in ipairs({
    { name = "github", host = "github%.com" },
    { name = "codeberg", host = "codeberg%.org" },
  }) do
    owner, repo = url:match(
      "^https?://" .. candidate.host .. "/([^/]+)/([^/]+)"
    )

    if not owner then
      owner, repo = url:match(
        "^git@" .. candidate.host .. ":([^/]+)/([^/]+)"
      )
    end

    if not owner then
      owner, repo = url:match(
        "^ssh://git@" .. candidate.host .. "/([^/]+)/([^/]+)"
      )
    end

    if owner then
      forge = candidate.name
      break
    end
  end

  if not forge or not owner or not repo then
    return nil
  end

  repo = repo:gsub("[/?#].*$", ""):gsub("%.git$", "")
  return forge, (owner .. "/" .. repo):lower()
end

function M.github_repository(url)
  local forge, repository = M.forge_repository(url)

  if forge == "github" then
    return repository
  end
end

function M.repository_root(path)
  if type(path) ~= "string" or path == "" then
    return nil
  end

  local stat = vim.uv.fs_stat(path)

  if stat and stat.type ~= "directory" then
    path = vim.fs.dirname(path)
  end

  if not vim.uv.fs_stat(path) then
    return nil
  end

  return vim.fs.root(path, ".git")
end

function M.local_candidates(info, opts)
  local candidates = {}
  local seen = {}

  local function add(path, explicit, search_path)
    local root = M.repository_root(path)

    if not root then
      return
    end

    root = vim.fs.normalize(root)

    local key = vim.uv.os_uname().sysname == "Windows_NT"
        and root:lower()
      or root

    if seen[key] then
      if explicit then
        seen[key].explicit = true
      end

      if search_path then
        seen[key].search_path = true
      end

      return
    end

    local candidate = {
      path = root,
      explicit = explicit or false,
      search_path = search_path or false,
    }

    seen[key] = candidate
    candidates[#candidates + 1] = candidate
  end

  local function add_search_path(path)
    if type(path) ~= "string" or not M.directory(path) then
      return
    end

    add(path, false, true)
    local children = {}

    local pending = {
      { path = path, depth = 0 },
    }

    local next_directory = 1

    while pending[next_directory] do
      local current = pending[next_directory]
      next_directory = next_directory + 1
      local scanner = vim.uv.fs_scandir(current.path)

      while scanner do
        local name, kind = vim.uv.fs_scandir_next(scanner)

        if not name then
          break
        end

        local child = vim.fs.joinpath(current.path, name)

        local child_is_directory = kind == "directory"
          or kind == "link"
          or (kind == nil and M.directory(child))

        if child_is_directory and not name:match("^%.") then
          local marker = vim.fs.joinpath(child, ".git")

          if vim.uv.fs_stat(marker) then
            children[#children + 1] = {
              path = child,
              depth = current.depth + 1,
            }
          elseif current.depth < 1 then
            pending[#pending + 1] = {
              path = child,
              depth = current.depth + 1,
            }
          end
        end
      end
    end

    table.sort(children, function(left, right)
      local left_matches = info and info.repo and (vim.fs.basename(left.path):lower()
        == info.repo:lower()) or false

      local right_matches = info and info.repo and (vim.fs.basename(right.path):lower()
        == info.repo:lower()) or false

      if left_matches ~= right_matches then
        return left_matches
      end

      if left.depth ~= right.depth then
        return left.depth < right.depth
      end

      return left.path:lower() < right.path:lower()
    end)

    for _, child in ipairs(children) do
      add(child.path, false, true)
    end
  end

  for _, repo in ipairs(opts.inspect_repositories or {}) do
    if type(repo) == "table" and type(repo.path) == "string" then
      add(repo.path, true, false)
    elseif type(repo) == "string" then
      add(repo, true, false)
    end
  end

  if info and info.repo and info.owner and opts.inspect_repositories then
    local named = opts.inspect_repositories[info.owner .. "/" .. info.repo]

    if type(named) == "table" and type(named.path) == "string" then
      add(named.path, true, false)
    elseif type(named) == "string" then
      add(named, true, false)
    end
  end

  add(vim.fn.getcwd(), false, false)

  if opts.cwd then
    local ok, cwd = pcall(vim.fs.normalize, opts.cwd)

    if ok then
      add(cwd, false)
    end
  end

  for _, path in ipairs(opts.inspect_search_paths or {}) do
    add_search_path(path)
  end

  return candidates
end

function M.find_local_repository(info, opts, callback)
  local candidates = M.local_candidates(info, opts)
  local index = 1
  local slug = (info.owner .. "/" .. info.repo):lower()

  local function matching_remote(output)
    for line in (output or ""):gmatch("[^\r\n]+") do
      local remote, url =
        line:match("^(%S+)%s+(%S+)%s+%(fetch%)$")

      local forge, repository = M.forge_repository(url)

      if forge == info.forge and repository == slug then
        return remote
      end
    end
  end

  local function contains_target(candidate, target_callback)
    local revisions = {}

    if info.kind == "pull_request" then
      revisions = { info.base_sha, info.head_sha }
    else
      revisions = { info.sha }
    end

    local revision_index = 1

    local function inspect_revision()
      local revision = revisions[revision_index]
      revision_index = revision_index + 1

      if type(revision) ~= "string" or revision == "" then
        target_callback(false)
        return
      end

      M.run({
        "git",
        "-C",
        candidate.path,
        "cat-file",
        "-e",
        revision .. "^{commit}",
      }, function(_, revision_err)
        if revision_err then
          target_callback(false)
          return
        end

        if revision_index <= #revisions then
          inspect_revision()
          return
        end

        target_callback(true)
      end)
    end

    inspect_revision()
  end

  local function inspect_next()
    local candidate = candidates[index]
    index = index + 1

    if not candidate then
      callback()
      return
    end

    M.run({ "git", "-C", candidate.path, "remote", "-v" }, function(remotes)
      local remote = matching_remote(remotes)

      if remote or candidate.explicit then
        callback(candidate.path, remote or info.remote_url)
        return
      end

      if not candidate.search_path then
        inspect_next()
        return
      end

      contains_target(candidate, function(matches_target)
        if matches_target then
          callback(candidate.path, info.remote_url)
          return
        end

        inspect_next()
      end)
    end)
  end

  inspect_next()
end

function M.download_destination(info, opts)
  local source_root = (opts.inspect_search_paths or {})[1]

  if type(source_root) ~= "string" or source_root == "" then
    return nil, "no default source directory is configured"
  end

  return vim.fs.joinpath(vim.fs.normalize(source_root), info.repo)
end

function M.offer_repository_download(info, opts, callback)
  local destination, destination_err = M.download_destination(info, opts)

  if not destination then
    callback(nil, destination_err)
    return
  end

  if M.repository_root(destination) then
    callback(destination)
    return
  end

  if M.directory(destination) then
    callback(
      nil,
      "cannot use the existing destination because it is not a Git "
        .. "repository: "
        .. destination
    )

    return
  end

  local choices = {
    {
      download = true,
      label = "Download repository",
    },
    {
      download = false,
      label = "Do not download",
    },
  }

  vim.ui.select(choices, {
    prompt = ("No local clone of %s/%s was found. Download it to %s?")
      :format(info.owner, info.repo, destination),
    format_item = function(choice)
      return choice.label
    end,
  }, function(choice)
    if not choice or not choice.download then
      callback(nil, "repository download was declined")
      return
    end

    local source_root = vim.fs.dirname(destination)
    local made_root = vim.fn.mkdir(source_root, "p")

    if made_root == 0 and not M.directory(source_root) then
      callback(nil, "could not create source directory: " .. source_root)
      return
    end

    M.run({
      "git",
      "clone",
      info.remote_url,
      destination,
    }, function(_, clone_err)
      if clone_err then
        callback(nil, "could not download repository: " .. clone_err)
        return
      end

      callback(destination)
    end)
  end)
end

function M.ensure_repository(info, opts, callback)
  M.find_local_repository(info, opts, function(repository, fetch_source)
    if repository then
      callback(repository, nil, fetch_source or info.remote_url)
      return
    end

    M.offer_repository_download(info, opts, function(downloaded, download_err)
      if not downloaded then
        callback(nil, download_err)
        return
      end

      callback(downloaded, nil, info.remote_url)
    end)
  end)
end

function M.resolve_revision(repository, revision, callback)
  M.run({
    "git",
    "-C",
    repository,
    "rev-parse",
    revision .. "^{commit}",
  }, callback)
end

function M.resolve_pair(repository, info, callback)
  if info.kind == "pull_request" then
    M.resolve_revision(repository, info.base_sha, function(base, base_err)
      if base_err then
        callback(nil, base_err)
        return
      end

      M.resolve_revision(repository, info.head_sha, function(head, head_err)
        if head_err then
          callback(nil, head_err)
          return
        end

        callback({ commit = head, parent = base })
      end)
    end)

    return
  end

  M.resolve_revision(repository, info.sha, function(commit, resolve_err)
    if resolve_err then
      callback(nil, resolve_err)
      return
    end

    M.run({
      "git",
      "-C",
      repository,
      "rev-parse",
      commit .. "^",
    }, function(parent, parent_err)
      if parent_err then
        callback(nil, "this commit does not have an inspectable parent")
        return
      end

      callback({ commit = commit, parent = parent })
    end)
  end)
end

function M.fetch_pair(repository, fetch_source, info, callback)
  M.resolve_pair(repository, info, function(commits)
    if commits then
      callback(commits)
      return
    end

    local command = {
      "git",
      "-C",
      repository,
      "fetch",
      "--filter=blob:none",
      fetch_source or info.remote_url,
    }

    if info.kind == "pull_request" then
      command[#command + 1] = info.base_sha

      command[#command + 1] = info.fetch_ref
        or ("refs/pull/%d/head"):format(info.number)
    else
      command[#command + 1] = info.sha
    end

    M.run(command, function(_, err)
      if err then
        local target = info.kind == "pull_request"
            and ("pull request #" .. info.number)
          or ("commit " .. info.sha)

        callback(nil, "could not fetch " .. target .. ": " .. err)
        return
      end

      M.resolve_pair(repository, info, function(resolved, resolve_err)
        if resolve_err then
          callback(nil, "could not resolve commit: " .. resolve_err)
          return
        end

        callback(resolved)
      end)
    end)
  end)
end

function M.revision_pairs(repository, info, commits, callback)
  if info.kind ~= "pull_request" then
    callback({ commits })
    return
  end

  M.run({
    "git",
    "-C",
    repository,
    "rev-list",
    "--reverse",
    "--topo-order",
    "--parents",
    commits.parent .. ".." .. commits.commit,
  }, function(output, err)
    if err then
      callback(nil, "could not list pull request commits: " .. err)
      return
    end

    local patch = require("oculus.inspect.patch")
    local pairs = patch.parse_revision_pairs(output)

    if #pairs == 0 then
      callback(nil, "the pull request does not contain inspectable commits")
      return
    end

    callback(pairs)
  end)
end

return M
