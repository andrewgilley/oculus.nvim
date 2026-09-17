local M = {}
local remote_repositories = {}
local repository_queues = {}
local default_remote_pull_request_depth = 250

function M.git_error(result, fallback)
  local message = vim.trim(result.stderr or "")

  if message == "" then
    message = fallback
  end

  return message
end

local function path_key(path)
  local normalized = vim.fs.normalize(path)

  return vim.uv.os_uname().sysname == "Windows_NT"
      and normalized:lower()
    or normalized
end

local function command_options(command)
  local options = { text = true }

  -- Remote cache repositories hold only the objects Oculus fetched. A missing
  -- commit must fail instead of lazily downloading its entire history.
  if command[2] == "-C"
    and type(command[3]) == "string"
    and remote_repositories[path_key(command[3])]
  then
    options.env = { GIT_NO_LAZY_FETCH = "1" }
  end

  return options
end

function M.run(command, callback)
  vim.system(command, command_options(command), function(result)
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
  vim.system(command, command_options(command), function(result)
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
  if not repository or repository == "" then
    return vim.fn.getcwd()
  end

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

function M.detect_repository(path, callback)
  local root = M.repository_root(path or vim.fn.getcwd())

  if not root then
    local buf_name = vim.api.nvim_buf_get_name(0)

    if buf_name ~= "" then
      root = M.repository_root(buf_name)
    end
  end

  if not root then
    callback(nil)
    return
  end

  M.run({ "git", "-C", root, "remote", "-v" }, function(output)
    if not output or output == "" then
      callback(nil)
      return
    end

    local first_match = nil

    for line in output:gmatch("[^\r\n]+") do
      local remote_name, url = line:match("^(%S+)%s+(%S+)%s+%(fetch%)")

      if url then
        local forge, repository = M.forge_repository(url)

        if forge and repository then
          local owner, repo = repository:match("^([^/]+)/([^/]+)$")

          if owner and repo then
            local info = {
              forge = forge,
              owner = owner,
              repo = repo,
              repository = repository,
              root = root,
            }

            if remote_name == "origin" then
              callback(info)
              return
            end

            if not first_match then
              first_match = info
            end
          end
        end
      end
    end

    callback(first_match)
  end)
end

function M.remote_cache_root(opts)
  local root = type(opts) == "table" and opts.inspect_remote_cache or nil

  if type(root) ~= "string" or root == "" then
    root = vim.fs.joinpath(vim.fn.stdpath("cache"), "oculus", "remote")
  end

  return vim.fs.normalize(root)
end

function M.remote_repository_path(info, opts)
  return vim.fs.joinpath(
    M.remote_cache_root(opts),
    info.forge or "github",
    info.owner:lower(),
    info.repo:lower()
  )
end

function M.in_remote_cache(path, opts)
  local root = path_key(M.remote_cache_root(opts))
  local key = path_key(path)
  return key == root or key:sub(1, #root + 1) == root .. "/"
end

local discovery_depth = 4
local discovery_ttl = 60
local discovery_cache = {}

local skipped_discovery_directories = {
  node_modules = true,
  target = true,
  vendor = true,
}

-- Git repositories below root, without descending into repositories or
-- hidden directories. Scans are cached briefly because activity feeds and
-- inspections look up clones for many projects at once.
local function discovered_repositories(root)
  local key = path_key(root)
  local cached = discovery_cache[key]
  local now = vim.uv.now()

  if cached and now - cached.time < discovery_ttl * 1000 then
    return cached.repositories
  end

  local repositories = {}
  local pending = { { path = root, depth = 0 } }
  local next_directory = 1

  while pending[next_directory] do
    local current = pending[next_directory]
    next_directory = next_directory + 1

    if vim.uv.fs_stat(vim.fs.joinpath(current.path, ".git")) then
      repositories[#repositories + 1] = {
        path = current.path,
        depth = current.depth,
      }
    elseif current.depth < discovery_depth then
      local scanner = vim.uv.fs_scandir(current.path)

      while scanner do
        local name, kind = vim.uv.fs_scandir_next(scanner)

        if not name then
          break
        end

        local child = vim.fs.joinpath(current.path, name)

        if not name:match("^%.")
          and not skipped_discovery_directories[name]
          and (kind == "directory" or (kind == "link" and M.directory(child)))
        then
          pending[#pending + 1] = { path = child, depth = current.depth + 1 }
        end
      end
    end
  end

  discovery_cache[key] = { time = now, repositories = repositories }
  return repositories
end

-- The name of a remote in the repository's config whose URL points at the
-- project, read directly so discovery does not spawn git for every clone.
local function configured_remote(path, info)
  local config = vim.fs.joinpath(path, ".git", "config")

  if not M.directory(vim.fs.joinpath(path, ".git")) then
    return nil
  end

  local ok, lines = pcall(vim.fn.readfile, config)

  if not ok then
    return nil
  end

  local slug = (info.owner .. "/" .. info.repo):lower()
  local section

  for _, line in ipairs(lines) do
    local name = line:match('^%s*%[remote%s+"([^"]+)"%]')

    if name then
      section = name
    elseif line:match("^%s*%[") then
      section = nil
    elseif section then
      local url = line:match("^%s*url%s*=%s*(%S+)")
      local forge, repository = M.forge_repository(url)

      if forge == info.forge and repository == slug then
        return section
      end
    end
  end
end

function M.discovery_roots(opts)
  local roots = {}

  for _, root in ipairs(type(opts) == "table" and opts.inspect_discovery_roots or {}) do
    if type(root) == "string" and root ~= "" then
      root = vim.fs.normalize(vim.fn.expand(root))

      if M.directory(root) then
        roots[#roots + 1] = root
      end
    end
  end

  return roots
end

-- Looks for a clone of the project anywhere below inspect_discovery_roots.
-- This is the last local lookup before inspecting remotely, so a clone kept
-- outside inspect_search_paths still loads whole files.
function M.discover_local_repository(info, opts)
  if not info or not info.owner or not info.repo then
    return nil
  end

  local matches = {}

  for _, root in ipairs(M.discovery_roots(opts)) do
    for _, repository in ipairs(discovered_repositories(root)) do
      if not M.in_remote_cache(repository.path, opts) then
        local remote = configured_remote(repository.path, info)

        if remote then
          matches[#matches + 1] = {
            path = repository.path,
            depth = repository.depth,
            remote = remote,
          }
        end
      end
    end
  end

  table.sort(matches, function(left, right)
    local left_named = vim.fs.basename(left.path):lower() == info.repo:lower()
    local right_named = vim.fs.basename(right.path):lower() == info.repo:lower()

    if left_named ~= right_named then
      return left_named
    end

    if left.depth ~= right.depth then
      return left.depth < right.depth
    end

    return left.path < right.path
  end)

  local match = matches[1]
  return match and match.path, match and match.remote
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

    -- Remote cache repositories are shallow and blob-free; treating one as a
    -- local clone would run full-history fetches against it.
    if M.in_remote_cache(root, opts) then
      return
    end

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
        line:match("^(%S+)%s+(%S+)%s+%(fetch%)")

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
      callback(M.discover_local_repository(info, opts))
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

function M.with_repository_lock(path, task)
  local key = path_key(path)
  local queue = repository_queues[key]

  local function run(next_task)
    local released = false

    next_task(function()
      if released then
        return
      end

      released = true
      local pending = repository_queues[key]
      local following = pending and table.remove(pending, 1)

      if following then
        run(following)
      else
        repository_queues[key] = nil
      end
    end)
  end

  if queue then
    queue[#queue + 1] = task
    return
  end

  repository_queues[key] = {}
  run(task)
end

local function run_steps(steps, callback)
  local index = 1

  local function step()
    local command = steps[index]
    index = index + 1

    if not command then
      callback(true)
      return
    end

    M.run(command, function(_, err)
      if err then
        callback(nil, err)
        return
      end

      step()
    end)
  end

  step()
end

function M.ensure_remote_repository(info, opts, callback)
  local path = M.remote_repository_path(info, opts)

  M.with_repository_lock(path, function(release)
    local function finish(repository, err)
      release()
      callback(repository, err)
    end

    local steps = {}

    if not vim.uv.fs_stat(vim.fs.joinpath(path, ".git")) then
      if vim.fn.mkdir(path, "p") == 0 and not M.directory(path) then
        finish(nil, "could not create remote cache directory: " .. path)
        return
      end

      steps[#steps + 1] = { "git", "-C", path, "init", "--quiet" }

      steps[#steps + 1] = {
        "git", "-C", path, "config", "remote.origin.promisor", "true",
      }

      steps[#steps + 1] = {
        "git", "-C", path, "config", "remote.origin.partialclonefilter",
        "blob:none",
      }
    end

    steps[#steps + 1] = {
      "git", "-C", path, "config", "remote.origin.url", info.remote_url,
    }

    run_steps(steps, function(_, err)
      if err then
        finish(nil, "could not prepare remote cache repository: " .. err)
        return
      end

      remote_repositories[path_key(path)] = true
      finish(path)
    end)
  end)
end

-- Remote cache repositories have no working tree, so a file browser opened on
-- an inspected file finds nothing. Their commits do include trees (only blobs
-- are filtered out), so each inspected commit's layout is written out as empty
-- directories and files. The marker under .git skips commits already laid out.
local materialized_trees = {}
local materialize_batch_size = 2000

local function tree_marker(repository, commit)
  return vim.fs.joinpath(repository, ".git", "oculus", "trees", commit)
end

local function safe_tree_path(path)
  for part in (path .. "/"):gmatch("(.-)/") do
    if part == "" or part == "." or part == ".." or part:lower() == ".git" then
      return false
    end
  end

  return not path:find("\\", 1, true)
end

local function write_tree_entries(repository, entries, callback)
  local directories = { [repository] = true }
  local index = 1

  local function ensure_directory(path)
    if directories[path] then
      return true
    end

    if not ensure_directory(vim.fs.dirname(path)) then
      return false
    end

    if not vim.uv.fs_mkdir(path, 493) and not M.directory(path) then
      return false
    end

    directories[path] = true
    return true
  end

  local function step()
    local last = math.min(#entries, index + materialize_batch_size - 1)

    for position = index, last do
      local entry = entries[position]
      local path = vim.fs.joinpath(repository, entry.path)

      if entry.directory then
        ensure_directory(path)
      elseif ensure_directory(vim.fs.dirname(path)) then
        local fd = vim.uv.fs_open(path, "wx", 420)

        if fd then
          vim.uv.fs_close(fd)
        end
      end
    end

    index = last + 1

    if index > #entries then
      callback()
    else
      vim.schedule(step)
    end
  end

  step()
end

function M.materialize_remote_tree(repository, commits, callback)
  callback = callback or function() end
  local pending = {}
  local seen = {}

  for _, commit in pairs(commits or {}) do
    local key = path_key(repository) .. ":" .. tostring(commit)

    if type(commit) == "string"
      and commit:match("^%x+$")
      and not seen[key]
      and not materialized_trees[key]
      and not vim.uv.fs_stat(tree_marker(repository, commit))
    then
      seen[key] = true
      pending[#pending + 1] = commit
    end
  end

  if #pending == 0 then
    callback(true)
    return
  end

  M.map_concurrently(pending, 2, function(commit, _, done)
    M.run_raw({
      "git", "-C", repository, "ls-tree", "-r", "-z", commit,
    }, function(output, err)
      if not output then
        done(nil, err)
        return
      end

      local entries = {}

      for record in output:gmatch("([^%z]+)") do
        local kind, path = record:match("^%d+ (%a+) %x+\t(.+)$")

        if path and safe_tree_path(path) then
          entries[#entries + 1] = { path = path, directory = kind == "commit" }
        end
      end

      write_tree_entries(repository, entries, function()
        local marker = tree_marker(repository, commit)
        vim.fn.mkdir(vim.fs.dirname(marker), "p")
        local fd = vim.uv.fs_open(marker, "w", 420)

        if fd then
          vim.uv.fs_close(fd)
        end

        materialized_trees[path_key(repository) .. ":" .. commit] = true
        done(true)
      end)
    end)
  end, function(_, err)
    callback(err == nil, err)
  end)
end

function M.ensure_repository(info, opts, callback)
  M.find_local_repository(info, opts, function(repository, fetch_source)
    if repository then
      callback(repository, nil, fetch_source or info.remote_url, false)
      return
    end

    M.ensure_remote_repository(info, opts, function(remote, remote_err)
      if not remote then
        callback(nil, remote_err)
        return
      end

      callback(remote, nil, "origin", true)
    end)
  end)
end

local function fetch_remote(repository, arguments, stdin, callback)
  local command = {
    "git",
    "-C",
    repository,
    "fetch",
    "--quiet",
    "--no-tags",
    "--no-write-fetch-head",
    "--recurse-submodules=no",
    "--filter=blob:none",
  }

  vim.list_extend(command, arguments)

  vim.system(command, {
    text = true,
    stdin = stdin,
    env = { GIT_TERMINAL_PROMPT = "0" },
  }, function(result)
    vim.schedule(function()
      if result.code ~= 0 then
        callback(nil, M.git_error(result, "git fetch failed"))
        return
      end

      callback(true)
    end)
  end)
end

-- Shallow fetches can mark commits other inspections rely on as history
-- boundaries, so revision pairs are resolved while the repository is locked.
function M.fetch_remote_revisions(repository, info, callback)
  M.with_repository_lock(repository, function(release)
    local function finish(commits, pairs, err)
      release()
      callback(commits, pairs, err)
    end

    local target = info.kind == "pull_request"
        and ("pull request #" .. tostring(info.number))
      or ("commit " .. tostring(info.sha))

    local function resolve()
      M.resolve_pair(repository, info, function(commits, resolve_err)
        if not commits then
          finish(nil, nil, "could not resolve " .. target .. ": " .. resolve_err)
          return
        end

        if info.kind ~= "pull_request" then
          finish(commits, { commits })
          return
        end

        M.revision_pairs(repository, info, commits, function(pairs, pairs_err)
          if not pairs then
            finish(nil, nil, pairs_err)
            return
          end

          local included = {}

          for _, commit in ipairs(type(info.commits) == "table" and info.commits or {}) do
            if type(commit) == "table" and type(commit.sha) == "string" then
              included[commit.sha:lower()] = true
            end
          end

          -- Shallow history cannot tell base-branch commits merged into the
          -- pull request apart from its own, so keep the forge's commit list.
          local filtered = vim.tbl_filter(function(pair)
            return included[pair.commit:lower()] == true
          end, pairs)

          finish(commits, #filtered > 0 and filtered or pairs)
        end)
      end)
    end

    local function fetch(arguments, done)
      fetch_remote(repository, arguments, nil, function(_, err)
        if err then
          finish(nil, nil, "could not fetch " .. target .. ": " .. err)
          return
        end

        done()
      end)
    end

    if info.kind == "pull_request" then
      local depth = math.max(
        tonumber(info.commit_count) or 0,
        type(info.commits) == "table" and #info.commits or 0
      )

      if depth == 0 then
        depth = default_remote_pull_request_depth
      end

      fetch({ "--depth=1", "origin", info.base_sha }, function()
        fetch({
          "--depth=" .. tostring(depth + 1),
          "origin",
          info.head_sha,
        }, resolve)
      end)

      return
    end

    M.resolve_pair(repository, info, function(commits)
      if commits then
        finish(commits, { commits })
        return
      end

      fetch({ "--depth=2", "origin", info.sha }, resolve)
    end)
  end)
end

function M.prefetch_remote_blobs(repository, pairs, callback)
  local objects = {}
  local seen = {}

  M.map_concurrently(pairs, 4, function(pair, _, done)
    M.run({
      "git",
      "-C",
      repository,
      "diff",
      "--raw",
      "--no-abbrev",
      "--no-renames",
      pair.parent,
      pair.commit,
      "--",
    }, function(output, err)
      if err then
        done(nil, "could not list changed files: " .. err)
        return
      end

      for line in (output or ""):gmatch("[^\r\n]+") do
        local old_mode, new_mode, old_object, new_object =
          line:match("^:(%d+) (%d+) (%x+) (%x+) ")

        for _, entry in ipairs({
          { mode = old_mode, object = old_object },
          { mode = new_mode, object = new_object },
        }) do
          if entry.object
            and entry.mode ~= "160000"
            and not entry.object:match("^0+$")
            and not seen[entry.object]
          then
            seen[entry.object] = true
            objects[#objects + 1] = entry.object
          end
        end
      end

      done(true)
    end)
  end, function(_, list_err)
    if list_err then
      callback(nil, list_err)
      return
    end

    if #objects == 0 then
      callback(true)
      return
    end

    M.with_repository_lock(repository, function(release)
      fetch_remote(
        repository,
        { "--stdin", "origin" },
        table.concat(objects, "\n") .. "\n",
        function(_, fetch_err)
          release()

          if fetch_err then
            callback(nil, "could not fetch changed files: " .. fetch_err)
            return
          end

          callback(true)
        end
      )
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
