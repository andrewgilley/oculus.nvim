local M = {}

local github = require("oculus.github")
local codeberg = require("oculus.codeberg")

local active = false
local change_ns = vim.api.nvim_create_namespace("oculus_inspect_changes")
local oil_ns = vim.api.nvim_create_namespace("oculus_inspect_oil")
local sidebar_ns =
  vim.api.nvim_create_namespace("oculus_inspect_sidebar")
local sessions = {}
local sidebar_groups = {}
local next_session = 0
local syncing = false
local sidebar_navigating = false
local inspection_tabs_loading = false
local oil_contexts = {}
local default_sidebar_toggle = "<leader>oi"
local default_overview_toggle = "o"
local default_version_switch = "<C-s>"
local default_next_chunk = "<Tab>"
local default_next_file = "<S-Tab>"
local normalize_inspection_view
local refresh_sidebar
local focus_sidebar_selection
local select_next_sidebar_chunk
local switch_sidebar_version
local close_inspection_sidebar
local open_inspection_sidebar
local restore_inspection_sidebar_for_buffer
local show_inspection_overview
local show_sidebar_files

local function git_error(result, fallback)
  local message = vim.trim(result.stderr or "")
  if message == "" then
    message = fallback
  end
  return message
end

local function run(command, callback)
  vim.system(command, { text = true }, function(result)
    vim.schedule(function()
      if result.code ~= 0 then
        callback(nil, git_error(result, "git command failed"))
        return
      end
      callback(vim.trim(result.stdout or ""))
    end)
  end)
end

local function run_raw(command, callback)
  vim.system(command, { text = true }, function(result)
    vim.schedule(function()
      if result.code ~= 0 then
        callback(nil, git_error(result, "git command failed"))
        return
      end
      callback(result.stdout or "")
    end)
  end)
end

local function parse_commit_url(url)
  if type(url) ~= "string" then
    return nil
  end

  local owner, repo, sha, suffix = url:match(
    "^https?://github%.com/([^/]+)/([^/]+)/commit/([0-9a-fA-F]+)(.*)$"
  )
  local forge = "github"
  local host = "github.com"
  if not owner then
    owner, repo, sha, suffix = url:match(
      "^https?://codeberg%.org/([^/]+)/([^/]+)/commit/([0-9a-fA-F]+)(.*)$"
    )
    forge = "codeberg"
    host = "codeberg.org"
  end
  if not owner or not repo or not sha then
    return nil
  end

  repo = repo:gsub("%.git$", "")
  if
    not owner:match("^[%w][%w._-]*$")
    or not repo:match("^[%w._-]+$")
    or repo == "."
    or repo == ".."
    or #sha < 7
    or #sha > 40
    or (suffix ~= "" and not suffix:match("^[/?#]"))
  then
    return nil
  end

  return {
    kind = "commit",
    forge = forge,
    host = host,
    owner = owner,
    repo = repo,
    sha = sha:lower(),
    remote_url = ("https://%s/%s/%s.git"):format(host, owner, repo),
  }
end

local function parse_pull_request_url(url)
  if type(url) ~= "string" then
    return nil
  end

  local owner, repo, number, suffix = url:match(
    "^https?://github%.com/([^/]+)/([^/]+)/pull/(%d+)(.*)$"
  )
  local forge = "github"
  local host = "github.com"
  if not owner then
    owner, repo, number, suffix = url:match(
      "^https?://codeberg%.org/([^/]+)/([^/]+)/pulls/(%d+)(.*)$"
    )
    forge = "codeberg"
    host = "codeberg.org"
  end
  if
    not owner
    or not repo
    or not number
    or not owner:match("^[%w][%w._-]*$")
    or not repo:match("^[%w._-]+$")
    or repo == "."
    or repo == ".."
    or (suffix ~= "" and not suffix:match("^[/?#]"))
  then
    return nil
  end

  repo = repo:gsub("%.git$", "")
  return {
    kind = "pull_request",
    forge = forge,
    host = host,
    owner = owner,
    repo = repo,
    number = tonumber(number),
    remote_url = ("https://%s/%s/%s.git"):format(host, owner, repo),
  }
end

local function parse_issue_url(url)
  if type(url) ~= "string" then
    return nil
  end
  local owner, repo, number, suffix = url:match(
    "^https?://github%.com/([^/]+)/([^/]+)/issues/(%d+)(.*)$"
  )
  local forge = "github"
  local host = "github.com"
  if not owner then
    owner, repo, number, suffix = url:match(
      "^https?://codeberg%.org/([^/]+)/([^/]+)/issues/(%d+)(.*)$"
    )
    forge = "codeberg"
    host = "codeberg.org"
  end
  if
    not owner
    or not repo
    or not number
    or not owner:match("^[%w][%w._-]*$")
    or not repo:match("^[%w._-]+$")
    or repo == "."
    or repo == ".."
    or (suffix ~= "" and not suffix:match("^[/?#]"))
  then
    return nil
  end
  repo = repo:gsub("%.git$", "")
  return {
    kind = "issue",
    forge = forge,
    host = host,
    owner = owner,
    repo = repo,
    number = tonumber(number),
    remote_url = ("https://%s/%s/%s.git"):format(host, owner, repo),
  }
end

local function parse_target_url(url)
  return parse_commit_url(url)
    or parse_pull_request_url(url)
    or parse_issue_url(url)
end

local function parse_commit_overview(output)
  if type(output) ~= "string" or output == "" then
    return nil
  end
  local fields = vim.split(output, "\0", { plain = true })
  if #fields < 7 then
    return nil
  end
  return {
    sha = vim.trim(fields[1] or ""),
    parents = vim.split(
      vim.trim(fields[2] or ""),
      "%s+",
      { trimempty = true }
    ),
    author_name = vim.trim(fields[3] or ""),
    author_email = vim.trim(fields[4] or ""),
    authored_at = vim.trim(fields[5] or ""),
    subject = vim.trim(fields[6] or ""),
    body = vim.trim(fields[7] or ""),
  }
end

local function activity_comment(event)
  if type(event) ~= "table" then
    return nil
  end
  if
    event.type ~= "PullRequestReviewCommentEvent"
    and event.type ~= "CommitCommentEvent"
  then
    return nil
  end
  local comment = event.payload and event.payload.comment or nil
  if type(comment) ~= "table" then
    return nil
  end
  local body = type(comment.body) == "string"
      and vim.trim(comment.body)
    or ""
  local path = type(comment.path) == "string"
      and comment.path
    or nil
  local side = comment.side == "LEFT" and "parent" or "change"
  local line = side == "parent"
      and (
        tonumber(comment.original_start_line)
        or tonumber(comment.original_line)
      )
    or (
      tonumber(comment.start_line)
      or tonumber(comment.line)
      or tonumber(comment.original_line)
    )
  if body == "" or not path or path == "" or not line then
    return nil
  end
  return {
    body = body,
    path = path:gsub("\\", "/"),
    line = math.max(1, line),
    side = side,
    commit = side == "parent"
        and (comment.original_commit_id or comment.commit_id)
      or comment.commit_id,
  }
end

local function activity_context(event)
  local comment = activity_comment(event)
  if comment then
    return comment
  end
  if type(event) ~= "table"
    or (
      event.type ~= "IssuesEvent"
      and event.type ~= "IssueCommentEvent"
    )
  then
    return nil
  end
  local payload = event.payload or {}
  local issue = payload.issue
  if type(issue) ~= "table" or issue.pull_request then
    return nil
  end
  local issue_body = type(issue.body) == "string" and issue.body or nil
  local comment_body = type(payload.comment) == "table"
      and type(payload.comment.body) == "string"
      and payload.comment.body
    or nil
  return {
    issue = {
      number = issue.number,
      title = issue.title,
      body = issue_body,
      comment = comment_body,
      html_url = issue.html_url,
    },
  }
end

local function first_changed_paths(output)
  local line = output and output:match("[^\r\n]+")
  if not line then
    return nil, nil
  end

  local fields = vim.split(line, "\t", { plain = true })
  local status = fields[1] or ""
  if (status:sub(1, 1) == "R" or status:sub(1, 1) == "C")
    and fields[2]
    and fields[3]
  then
    return fields[2], fields[3]
  end
  return fields[2], fields[2]
end

local function parse_changed_files(output)
  local changes = {}
  for line in (output or ""):gmatch("[^\r\n]+") do
    local fields = vim.split(line, "\t", { plain = true })
    local status = (fields[1] or ""):sub(1, 1)
    if
      (status == "R" or status == "C")
      and fields[2]
      and fields[3]
    then
      changes[#changes + 1] = {
        status = status,
        old_path = fields[2],
        new_path = fields[3],
      }
    elseif status ~= "" and fields[2] then
      changes[#changes + 1] = {
        status = status,
        old_path = fields[2],
        new_path = fields[2],
      }
    end
  end
  return changes
end

local function parse_hunks(patch)
  local hunks = {}
  for old_start, old_count, new_start, new_count in
    (patch or ""):gmatch(
      "@@ %-(%d+),?(%d*) %+(%d+),?(%d*) @@"
    )
  do
    hunks[#hunks + 1] = {
      old_start = tonumber(old_start),
      old_count = old_count == "" and 1 or tonumber(old_count),
      new_start = tonumber(new_start),
      new_count = new_count == "" and 1 or tonumber(new_count),
    }
  end
  return hunks
end

local function hunk_start(hunk, role)
  return math.max(
    1,
    role == "parent" and hunk.old_start or hunk.new_start
  )
end

local function focused_hunk_start(hunk)
  local before = hunk.old_count == 0
      and hunk.old_start
    or hunk.old_start - 1
  return math.max(1, before + 1)
end

local function revision_hunk_index_at_line(session, role, line)
  for index, hunk in ipairs(session.hunks or {}) do
    local start = hunk_start(hunk, role)
    local count = role == "parent"
        and hunk.old_count
      or hunk.new_count
    if line >= start
      and line <= start + math.max(1, count) - 1
    then
      return index
    end
  end
end

local function hunk_index_at_line(session, role, line)
  if not session.focused_chunks then
    return revision_hunk_index_at_line(session, role, line)
  end
  for index, hunk in ipairs(session.hunks or {}) do
    local focused_change = session.focused_chunks
      and role == "change"
      and index == session.active_chunk
    local start
    if focused_change then
      start = focused_hunk_start(hunk)
    elseif session.focused_chunks then
      start = hunk_start(hunk, "parent")
      local active = session.hunks[session.active_chunk]
      if role == "change"
        and active
        and hunk.old_start > active.old_start
      then
        start = start + active.new_count - active.old_count
      end
    else
      start = hunk_start(hunk, role)
    end
    local count
    if focused_change then
      count = hunk.new_count
    elseif role == "parent" or index ~= session.active_chunk then
      count = hunk.old_count
    else
      count = hunk.new_count
    end
    if line >= start
      and line <= start + math.max(1, count) - 1
    then
      return index
    end
  end
end

local function change_lines(hunks, role)
  local lines = {}
  local seen = {}
  for _, hunk in ipairs(hunks or {}) do
    local line = hunk_start(hunk, role or "change")
    if not seen[line] then
      seen[line] = true
      lines[#lines + 1] = line
    end
  end
  table.sort(lines)
  return lines
end

local function focused_change_lines(parent_lines, change_lines_value, hunk)
  if not hunk then
    return vim.deepcopy(parent_lines or { "" }), 1
  end

  parent_lines = parent_lines or { "" }
  change_lines_value = change_lines_value or { "" }
  local parent_count = #parent_lines
  if parent_count == 1
    and parent_lines[1] == ""
    and hunk.old_start == 0
    and hunk.old_count == 0
  then
    parent_count = 0
  end

  local before_count = hunk.old_count == 0
      and hunk.old_start
    or hunk.old_start - 1
  before_count = math.min(math.max(0, before_count), parent_count)
  local result = {}
  local function append(source, first, last)
    for index = math.max(1, first), math.min(#source, last) do
      result[#result + 1] = source[index]
    end
  end

  append(parent_lines, 1, before_count)
  append(
    change_lines_value,
    hunk.new_start,
    hunk.new_start + hunk.new_count - 1
  )
  append(
    parent_lines,
    before_count + hunk.old_count + 1,
    parent_count
  )
  return #result > 0 and result or { "" }, math.max(1, before_count + 1)
end

local function parse_revision_pairs(output)
  local pairs = {}
  for line in (output or ""):gmatch("[^\r\n]+") do
    local fields = vim.split(line, "%s+", { trimempty = true })
    if fields[1] and fields[2] then
      pairs[#pairs + 1] = {
        commit = fields[1],
        parent = fields[2],
      }
    end
  end
  return pairs
end

local function directory(path)
  local stat = vim.uv.fs_stat(path)
  return stat and stat.type == "directory"
end

local function inspection_directory(repository, file)
  if not file then
    return repository
  end
  local parent = vim.fs.dirname(vim.fs.joinpath(repository, file))
  return directory(parent) and parent or repository
end

local function forge_repository(url)
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

local function github_repository(url)
  local forge, repository = forge_repository(url)
  if forge == "github" then
    return repository
  end
end

local function repository_root(path)
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

local function local_candidates(info, opts)
  local candidates = {}
  local seen = {}

  local function add(path, explicit, search_path)
    local root = repository_root(path)
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
    if type(path) ~= "string" or not directory(path) then
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
          or (kind == nil and directory(child))
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
      local left_matches = vim.fs.basename(left.path):lower()
        == info.repo:lower()
      local right_matches = vim.fs.basename(right.path):lower()
        == info.repo:lower()
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

  local slug = (info.owner .. "/" .. info.repo):lower()
  for name, path in pairs(opts.inspect_repositories or {}) do
    if type(name) == "string" and name:lower() == slug then
      add(path, true)
    end
  end

  add(vim.fn.getcwd(), false)
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(buf) then
      add(vim.api.nvim_buf_get_name(buf), false)
    end
  end
  for tab = 1, vim.fn.tabpagenr("$") do
    local ok, cwd = pcall(vim.fn.getcwd, -1, tab)
    if ok then
      add(cwd, false)
    end
  end
  for _, path in ipairs(opts.inspect_search_paths or {}) do
    add_search_path(path)
  end
  return candidates
end

local function find_local_repository(info, opts, callback)
  local candidates = local_candidates(info, opts)
  local slug = (info.owner .. "/" .. info.repo):lower()
  local index = 1

  local function matching_remote(remotes)
    for line in (remotes or ""):gmatch("[^\r\n]+") do
      local remote, url =
        line:match("^(%S+)%s+(%S+)%s+%(fetch%)$")
      local forge, repository = forge_repository(url)
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
      run({
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

    run({ "git", "-C", candidate.path, "remote", "-v" }, function(remotes)
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

local function download_destination(info, opts)
  local source_root = (opts.inspect_search_paths or {})[1]
  if type(source_root) ~= "string" or source_root == "" then
    return nil, "no default source directory is configured"
  end
  return vim.fs.joinpath(vim.fs.normalize(source_root), info.repo)
end

local function offer_repository_download(info, opts, callback)
  local destination, destination_err = download_destination(info, opts)
  if not destination then
    callback(nil, destination_err)
    return
  end
  if vim.uv.fs_stat(destination) then
    local root = repository_root(destination)
    local normalized_destination = vim.fs.normalize(destination)
    local normalized_root = root and vim.fs.normalize(root) or nil
    if vim.uv.os_uname().sysname == "Windows_NT" then
      normalized_destination = normalized_destination:lower()
      normalized_root = normalized_root and normalized_root:lower() or nil
    end
    if normalized_root == normalized_destination then
      callback(destination)
      return
    end
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
    if made_root == 0 and not directory(source_root) then
      callback(nil, "could not create source directory: " .. source_root)
      return
    end
    run({
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

local function ensure_repository(info, opts, callback)
  find_local_repository(info, opts, function(repository, fetch_source)
    if repository then
      callback(repository, nil, fetch_source or info.remote_url)
      return
    end
    offer_repository_download(info, opts, function(downloaded, download_err)
      if not downloaded then
        callback(nil, download_err)
        return
      end
      callback(downloaded, nil, info.remote_url)
    end)
  end)
end

local function resolve_revision(repository, revision, callback)
  run({
    "git",
    "-C",
    repository,
    "rev-parse",
    revision .. "^{commit}",
  }, callback)
end

local function resolve_pair(repository, info, callback)
  if info.kind == "pull_request" then
    resolve_revision(repository, info.base_sha, function(base, base_err)
      if base_err then
        callback(nil, base_err)
        return
      end
      resolve_revision(repository, info.head_sha, function(head, head_err)
        if head_err then
          callback(nil, head_err)
          return
        end
        callback({ commit = head, parent = base })
      end)
    end)
    return
  end

  resolve_revision(repository, info.sha, function(commit, resolve_err)
    if resolve_err then
      callback(nil, resolve_err)
      return
    end
    run({
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

local function fetch_pair(repository, fetch_source, info, callback)
  resolve_pair(repository, info, function(commits)
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

    run(command, function(_, err)
      if err then
        local target = info.kind == "pull_request"
            and ("pull request #" .. info.number)
          or ("commit " .. info.sha)
        callback(nil, "could not fetch " .. target .. ": " .. err)
        return
      end
      resolve_pair(repository, info, function(resolved, resolve_err)
        if resolve_err then
          callback(nil, "could not resolve commit: " .. resolve_err)
          return
        end
        callback(resolved)
      end)
    end)
  end)
end

local function revision_pairs(repository, info, commits, callback)
  if info.kind ~= "pull_request" then
    callback({ commits })
    return
  end

  run({
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
    local pairs = parse_revision_pairs(output)
    if #pairs == 0 then
      callback(nil, "the pull request does not contain inspectable commits")
      return
    end
    callback(pairs)
  end)
end

local function valid_endpoint(endpoint)
  return endpoint
    and vim.api.nvim_tabpage_is_valid(endpoint.tab)
    and vim.api.nvim_win_is_valid(endpoint.win)
    and vim.api.nvim_buf_is_valid(endpoint.buf)
end

local function prevent_window_dimming(win)
  if not vim.api.nvim_win_is_valid(win) then
    return false
  end
  local mappings = {}
  for _, mapping in ipairs(vim.split(
    vim.wo[win].winhighlight,
    ",",
    { trimempty = true }
  )) do
    if not mapping:match("^NormalNC:") then
      mappings[#mappings + 1] = mapping
    end
  end
  mappings[#mappings + 1] = "NormalNC:Normal"
  vim.wo[win].winhighlight = table.concat(mappings, ",")
  return true
end

local function update_session_buffer(win, buf)
  local name = vim.api.nvim_buf_get_name(buf)
  if vim.bo[buf].filetype == "oil"
    or vim.bo[buf].filetype == "oculus-inspect-files"
    or name:match("^oil://")
  then
    return
  end
  for _, session in pairs(sessions) do
    if session.parent.win == win then
      session.parent.buf = buf
    elseif session.change.win == win then
      session.change.buf = buf
    end
  end
end

local function show_inspection_path(buf)
  if not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  local state = vim.b[buf].oculus_inspect
  if type(state) ~= "table"
    or type(state.source_path) ~= "string"
    or state.source_path == ""
  then
    return
  end
  for _, other in ipairs(vim.api.nvim_list_bufs()) do
    if other ~= buf
      and vim.api.nvim_buf_is_valid(other)
      and type(vim.b[other].oculus_inspect) == "table"
      and vim.api.nvim_buf_get_name(other) ~= ""
    then
      pcall(vim.api.nvim_buf_set_name, other, "")
    end
  end
  if vim.api.nvim_buf_get_name(buf) == "" then
    local named = pcall(
      vim.api.nvim_buf_set_name,
      buf,
      state.source_path
    )
    if not named then
      local revision = type(state.commit) == "string"
          and state.commit:sub(1, 8)
        or tostring(state.pair_index or "")
      pcall(
        vim.api.nvim_buf_set_name,
        buf,
        state.source_path .. "@" .. revision
      )
    end
  end
end

local function paired_endpoint(win)
  for id, session in pairs(sessions) do
    if not valid_endpoint(session.parent)
      or not valid_endpoint(session.change)
    then
      sessions[id] = nil
    elseif session.parent.win == win then
      return session.change
    elseif session.change.win == win then
      return session.parent
    end
  end
end

local function window_view(win)
  return vim.api.nvim_win_call(win, function()
    return vim.fn.winsaveview()
  end)
end

local function sync_window(source_win)
  if syncing or not vim.api.nvim_win_is_valid(source_win) then
    return
  end
  local origin_tab = vim.api.nvim_get_current_tabpage()
  local origin_win = vim.api.nvim_get_current_win()
  local target = paired_endpoint(source_win)
  if not target then
    return
  end
  local source_buf = vim.api.nvim_win_get_buf(source_win)
  if vim.bo[source_buf].filetype == "oil"
    or vim.bo[target.buf].filetype == "oil"
  then
    return
  end

  syncing = true
  local ok = pcall(function()
    local cursor = vim.api.nvim_win_get_cursor(source_win)
    local line_count = vim.api.nvim_buf_line_count(target.buf)
    local line = math.min(math.max(1, cursor[1]), line_count)
    local text = vim.api.nvim_buf_get_lines(
      target.buf,
      line - 1,
      line,
      false
    )[1] or ""
    local column = math.min(cursor[2], #text)
    vim.api.nvim_win_set_cursor(target.win, { line, column })

    local view = window_view(source_win)
    view.lnum = line
    view.col = column
    vim.api.nvim_win_call(target.win, function()
      vim.fn.winrestview(view)
    end)
  end)
  syncing = false
  if vim.api.nvim_tabpage_is_valid(origin_tab)
    and vim.api.nvim_win_is_valid(origin_win)
  then
    sidebar_navigating = true
    vim.api.nvim_set_current_tabpage(origin_tab)
    vim.api.nvim_set_current_win(origin_win)
    sidebar_navigating = false
  end
  if not ok then
    return
  end
end

local sync_group = vim.api.nvim_create_augroup(
  "OculusInspectSync",
  { clear = true }
)

vim.api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI" }, {
  group = sync_group,
  callback = function()
    sync_window(vim.api.nvim_get_current_win())
  end,
})

vim.api.nvim_create_autocmd("BufEnter", {
  group = sync_group,
  callback = function(args)
    update_session_buffer(vim.api.nvim_get_current_win(), args.buf)
    show_inspection_path(args.buf)
    vim.schedule(function()
      if restore_inspection_sidebar_for_buffer then
        restore_inspection_sidebar_for_buffer(args.buf)
      end
    end)
  end,
})

vim.api.nvim_create_autocmd("WinScrolled", {
  group = sync_group,
  callback = function(args)
    local win = tonumber(args.match)
    if win then
      sync_window(win)
    end
  end,
})

local function comparable_path(path)
  path = vim.fs.normalize(path):gsub("\\", "/"):gsub("/+$", "")
  if vim.uv.os_uname().sysname == "Windows_NT" then
    return path:lower()
  end
  return path
end

local function relative_path(root, path)
  local normalized_root = comparable_path(root)
  local normalized_path = comparable_path(path)
  if normalized_path == normalized_root then
    return ""
  end
  local prefix = normalized_root .. "/"
  if normalized_path:sub(1, #prefix) ~= prefix then
    return nil
  end
  return normalized_path:sub(#prefix + 1)
end

local function session_directory(session, role, directory)
  local root
  if role == "issue" then
    root = session.repository
  else
    root = role == "parent"
        and session.parent_repository
      or session.change_repository
  end
  if not root then
    return
  end
  local relative = relative_path(root, directory)
  if relative ~= nil then
    return session, role, relative
  end
end

local function issue_session_for_directory(directory, preferred_tab)
  for _, group in ipairs(sidebar_groups) do
    if group.kind == "issue" then
      for _, session in ipairs(group) do
        if valid_endpoint(session.issue)
          and (
            not preferred_tab
            or session.issue.tab == preferred_tab
          )
        then
          local found, role, relative =
            session_directory(session, "issue", directory)
          if found then
            return found, role, relative
          end
        end
      end
    end
  end
end

local function session_for_directory(directory, preferred_tab)
  if preferred_tab then
    for _, session in pairs(sessions) do
      if session.parent.tab == preferred_tab then
        local found, role, relative =
          session_directory(session, "parent", directory)
        if found then
          return found, role, relative
        end
      elseif session.change.tab == preferred_tab then
        local found, role, relative =
          session_directory(session, "change", directory)
        if found then
          return found, role, relative
        end
      end
    end
    local issue_session, issue_role, issue_relative =
      issue_session_for_directory(directory, preferred_tab)
    if issue_session then
      return issue_session, issue_role, issue_relative
    end
  end

  for _, session in pairs(sessions) do
    local found, role, relative =
      session_directory(session, "parent", directory)
    if found then
      return found, role, relative
    end
    found, role, relative =
      session_directory(session, "change", directory)
    if found then
      return found, role, relative
    end
  end
  return issue_session_for_directory(directory)
end

local function change_path_for_role(change, role)
  if role == "parent" then
    if change.status == "A" or change.status == "C" then
      return nil
    end
    return change.old_path
  end
  if change.status == "D" then
    return nil
  end
  return change.new_path
end

local function oil_entry_status(session, role, path, directory)
  local comparable = path:gsub("\\", "/")
  if vim.uv.os_uname().sysname == "Windows_NT" then
    comparable = comparable:lower()
  end
  local prefix = comparable == "" and "" or (comparable .. "/")

  for _, change in ipairs(session.changes or {}) do
    local candidate = change_path_for_role(change, role)
    if candidate then
      candidate = candidate:gsub("\\", "/")
      if vim.uv.os_uname().sysname == "Windows_NT" then
        candidate = candidate:lower()
      end
      if candidate == comparable then
        return change.status
      end
      if directory and candidate:sub(1, #prefix) == prefix then
        return "directory"
      end
    end
  end
end

local oil_status = {
  A = { sign = "+", highlight = "OculusOilAdded" },
  C = { sign = "+", highlight = "OculusOilAdded" },
  D = { sign = "-", highlight = "OculusOilDeleted" },
  M = { sign = "~", highlight = "OculusOilModified" },
  R = { sign = "→", highlight = "OculusOilRenamed" },
  T = { sign = "~", highlight = "OculusOilModified" },
  directory = {
    sign = "•",
    highlight = "OculusOilDirectory",
  },
}

local function decorate_oil_buffer(buf)
  if not vim.api.nvim_buf_is_valid(buf) or vim.bo[buf].filetype ~= "oil" then
    return
  end
  local ok, oil = pcall(require, "oil")
  if not ok then
    return
  end
  local directory = oil.get_current_dir(buf)
  if not directory then
    return
  end
  local preferred_tab
  if vim.api.nvim_get_current_buf() == buf then
    preferred_tab = vim.api.nvim_get_current_tabpage()
  end
  local session, role, relative =
    session_for_directory(directory, preferred_tab)
  vim.api.nvim_buf_clear_namespace(buf, oil_ns, 0, -1)
  if not session then
    return
  end

  for line = 1, vim.api.nvim_buf_line_count(buf) do
    local entry = oil.get_entry_on_line(buf, line)
    if entry and entry.name and entry.name ~= ".." then
      local path = relative == ""
          and entry.name
        or (relative .. "/" .. entry.name)
      local status = oil_entry_status(
        session,
        role,
        path,
        entry.type == "directory"
      )
      local style = oil_status[status]
      if style then
        vim.api.nvim_buf_set_extmark(buf, oil_ns, line - 1, 0, {
          sign_text = style.sign,
          sign_hl_group = style.highlight,
          priority = 50,
        })
      end
    end
  end

  for _, win in ipairs(vim.fn.win_findbuf(buf)) do
    vim.wo[win].signcolumn = "yes"
  end
end

local function sidebar_group_for_session(session)
  for _, group in ipairs(sidebar_groups) do
    for _, candidate in ipairs(group) do
      if candidate == session then
        return group
      end
    end
  end
end

local function matching_oil_entry_name(left, right)
  if vim.uv.os_uname().sysname == "Windows_NT" then
    return left:lower() == right:lower()
  end
  return left == right
end

local function invoke_oil_mapping(mapping)
  if type(mapping.callback) == "function" then
    mapping.callback()
  elseif type(mapping.rhs) == "string" and mapping.rhs ~= "" then
    vim.api.nvim_feedkeys(
      vim.api.nvim_replace_termcodes(
        mapping.rhs,
        true,
        false,
        true
      ),
      "m",
      false
    )
  end
end

local function map_oil_origin_selection(buf, context, oil)
  for _, lhs in ipairs({ "l", "<CR>" }) do
    local original = vim.api.nvim_buf_call(buf, function()
      return vim.fn.maparg(lhs, "n", false, true)
    end)
    if original.buffer == 1
      and original.desc ~= "Select Oculus Inspect Oil entry"
    then
      vim.keymap.set("n", lhs, function()
        local entry = oil.get_cursor_entry()
        local directory = oil.get_current_dir()
        if entry
          and entry.type ~= "directory"
          and directory
          and comparable_path(directory)
            == comparable_path(context.directory)
          and matching_oil_entry_name(entry.name, context.filename)
        then
          oil.close()
          return
        end
        invoke_oil_mapping(original)
      end, {
        buffer = buf,
        nowait = true,
        silent = true,
        desc = "Select Oculus Inspect Oil entry",
      })
    end
  end
end

local function focus_oil_origin(buf, context, oil)
  local wins = vim.fn.win_findbuf(buf)
  local win = vim.api.nvim_get_current_buf() == buf
      and vim.api.nvim_get_current_win()
    or wins[1]
  if not win or not vim.api.nvim_win_is_valid(win) then
    return
  end
  for line = 1, vim.api.nvim_buf_line_count(buf) do
    local entry = oil.get_entry_on_line(buf, line)
    if entry
      and matching_oil_entry_name(entry.name, context.filename)
    then
      vim.api.nvim_win_set_cursor(win, { line, 0 })
      return true
    end
  end
end

local function activate_oil_context(context)
  if context.active then
    return
  end
  context.active = true
  local group = context.group
  context.restore_sidebar =
    group and group.sidebar_visible == true or false
  if context.restore_sidebar and close_inspection_sidebar then
    close_inspection_sidebar(group)
  end
end

restore_inspection_sidebar_for_buffer = function(buf)
  for _, context in pairs(oil_contexts) do
    if context.source_buf == buf and context.active then
      context.active = false
      local group = context.group
      if context.restore_sidebar
        and group
        and not group.sidebar_visible
        and open_inspection_sidebar
      then
        context.restore_sidebar = false
        open_inspection_sidebar(group)
      end
      return
    end
  end
end

local function configure_inspection_oil_buffer(buf)
  if not vim.api.nvim_buf_is_valid(buf)
    or vim.bo[buf].filetype ~= "oil"
  then
    return
  end
  local ok, oil = pcall(require, "oil")
  if not ok then
    return
  end
  if oil_contexts[buf] then
    local context = oil_contexts[buf]
    activate_oil_context(context)
    focus_oil_origin(buf, context, oil)
    map_oil_origin_selection(buf, context, oil)
    return
  end
  local directory = oil.get_current_dir(buf)
  if not directory then
    return
  end
  local wins = vim.fn.win_findbuf(buf)
  local win = vim.api.nvim_get_current_buf() == buf
      and vim.api.nvim_get_current_win()
    or wins[1]
  if not win or not vim.api.nvim_win_is_valid(win) then
    return
  end
  local tab = vim.api.nvim_win_get_tabpage(win)
  local session, role = session_for_directory(directory, tab)
  local endpoint = session and session[role] or nil
  if not endpoint or not vim.api.nvim_buf_is_valid(endpoint.buf) then
    return
  end
  local state = vim.b[endpoint.buf].oculus_inspect
  local source_path = type(state) == "table" and state.source_path or nil
  if type(source_path) ~= "string" or source_path == "" then
    return
  end
  local source_directory = vim.fs.dirname(source_path)
  if comparable_path(directory) ~= comparable_path(source_directory) then
    return
  end
  local context = {
    directory = source_directory,
    filename = vim.fs.basename(source_path),
    source_buf = endpoint.buf,
  }
  vim.b[buf].oculus_inspect_oil_origin = vim.deepcopy(context)

  local group = sidebar_group_for_session(session)
  context.group = group
  oil_contexts[buf] = context
  activate_oil_context(context)

  focus_oil_origin(buf, context, oil)
  map_oil_origin_selection(buf, context, oil)
end

local function highlight_foreground(name, fallback)
  local ok, highlight = pcall(
    vim.api.nvim_get_hl,
    0,
    { name = name, link = false }
  )
  if ok and highlight.fg then
    return highlight.fg
  end
  return fallback
end

local function highlight_background(name)
  local ok, highlight = pcall(
    vim.api.nvim_get_hl,
    0,
    { name = name, link = false }
  )
  return ok and highlight.bg or nil
end

local function set_oil_highlights()
  local background = highlight_background("Normal")
  vim.api.nvim_set_hl(0, "OculusOilAdded", {
    fg = highlight_foreground("DiagnosticOk", 0x9ae6b4),
    bg = background,
  })
  vim.api.nvim_set_hl(0, "OculusOilDeleted", {
    fg = highlight_foreground("DiagnosticError", 0xf87171),
    bg = background,
  })
  vim.api.nvim_set_hl(0, "OculusOilModified", {
    fg = highlight_foreground("DiagnosticWarn", 0xfbd38d),
    bg = background,
  })
  vim.api.nvim_set_hl(0, "OculusOilRenamed", {
    fg = highlight_foreground("DiagnosticInfo", 0x7dd3fc),
    bg = background,
  })
  vim.api.nvim_set_hl(0, "OculusOilDirectory", {
    fg = highlight_foreground("DiagnosticInfo", 0x7dd3fc),
    bg = background,
  })
end

set_oil_highlights()

local oil_group = vim.api.nvim_create_augroup(
  "OculusInspectOil",
  { clear = true }
)

vim.api.nvim_create_autocmd("ColorScheme", {
  group = oil_group,
  callback = set_oil_highlights,
})

local function queue_oil_decorations(buf)
  vim.schedule(function()
    configure_inspection_oil_buffer(buf)
    decorate_oil_buffer(buf)
  end)
end

vim.api.nvim_create_autocmd("User", {
  group = oil_group,
  pattern = "OilEnter",
  callback = function(args)
    local buf = args.data and args.data.buf or vim.api.nvim_get_current_buf()
    queue_oil_decorations(buf)
  end,
})

vim.api.nvim_create_autocmd({ "BufEnter", "WinEnter", "TextChanged" }, {
  group = oil_group,
  pattern = "oil://*",
  callback = function(args)
    queue_oil_decorations(args.buf)
  end,
})

vim.api.nvim_create_autocmd("BufWipeout", {
  group = oil_group,
  callback = function(args)
    oil_contexts[args.buf] = nil
  end,
})

local function place_sign(buf, line, text, highlight)
  if not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  local line_count = vim.api.nvim_buf_line_count(buf)
  line = math.min(math.max(1, line), line_count)
  vim.api.nvim_buf_set_extmark(buf, change_ns, line - 1, 0, {
    sign_text = text,
    sign_hl_group = highlight,
    priority = 50,
  })
end

local function place_range(buf, start, count, text, highlight)
  if count == 0 then
    place_sign(buf, start, text, highlight)
    return
  end
  for line = start, start + count - 1 do
    place_sign(buf, line, text, highlight)
  end
end

local function set_change_highlights()
  local normal =
    vim.api.nvim_get_hl(0, { name = "Normal", link = false })
  local diagnostic_info =
    vim.api.nvim_get_hl(0, { name = "DiagnosticInfo", link = false })
  vim.api.nvim_set_hl(0, "OculusInspectRemoved", {
    link = "DiffDelete",
  })
  vim.api.nvim_set_hl(0, "OculusInspectAdded", {
    link = "DiffAdd",
  })
  vim.api.nvim_set_hl(0, "OculusIssueSection", {
    fg = diagnostic_info.fg or 0x61afef,
    bg = normal.bg,
  })
end

set_change_highlights()

vim.api.nvim_create_autocmd("ColorScheme", {
  group = oil_group,
  callback = set_change_highlights,
})

local function apply_change_signs(parent_buf, change_buf, hunks)
  set_change_highlights()
  vim.api.nvim_buf_clear_namespace(parent_buf, change_ns, 0, -1)
  vim.api.nvim_buf_clear_namespace(change_buf, change_ns, 0, -1)

  for _, hunk in ipairs(hunks or {}) do
    place_range(
      parent_buf,
      hunk.old_start,
      hunk.old_count,
      hunk.old_count == 0 and "+" or "-",
      hunk.old_count == 0
          and "OculusInspectAdded"
        or "OculusInspectRemoved"
    )
    place_range(
      change_buf,
      hunk.new_start,
      hunk.new_count,
      hunk.new_count == 0 and "-" or "+",
      hunk.new_count == 0
          and "OculusInspectRemoved"
        or "OculusInspectAdded"
    )
  end
end

local function refresh_buffer_highlighting(buf)
  if not vim.api.nvim_buf_is_valid(buf)
    or type(vim.b[buf].oculus_inspect) ~= "table"
  then
    return false
  end
  if vim.b[buf].oculus_inspect_highlighting_refreshed then
    return true
  end

  local syntax = vim.bo[buf].syntax
  if syntax ~= "" then
    for _, win in ipairs(vim.fn.win_findbuf(buf)) do
      vim.api.nvim_win_call(win, function()
        vim.cmd("syntax sync fromstart")
      end)
    end
  end

  local highlighters = vim.treesitter
      and vim.treesitter.highlighter
      and vim.treesitter.highlighter.active
    or nil
  if highlighters and highlighters[buf] then
    local parser_ok, parser = pcall(vim.treesitter.get_parser, buf)
    if parser_ok and parser then
      pcall(parser.invalidate, parser, true)
      pcall(parser.parse, parser, true, function()
        if vim.api.nvim_buf_is_valid(buf) then
          vim.schedule(function()
            if vim.api.nvim_buf_is_valid(buf) then
              vim.cmd("redraw")
            end
          end)
        end
      end)
    end
  end

  if not inspection_tabs_loading then
    vim.cmd("redraw")
  end
  vim.b[buf].oculus_inspect_highlighting_refreshed = true
  return true
end

local function apply_inspection_filetype(buf)
  if not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  local state = vim.b[buf].oculus_inspect
  if type(state) ~= "table" then
    return
  end
  local filename = type(state.source_path) == "string"
      and state.source_path ~= ""
      and state.source_path
    or state.file
  if type(filename) ~= "string" or filename == "" then
    return
  end
  local ok, filetype = pcall(vim.filetype.match, {
    buf = buf,
    filename = filename,
  })
  if not ok or type(filetype) ~= "string" or filetype == "" then
    return
  end
  if vim.bo[buf].filetype ~= filetype then
    vim.b[buf].oculus_inspect_highlighting_refreshed = false
    vim.bo[buf].filetype = filetype
  end
  local reliquary_ok, reliquary = pcall(require, "reliquary")
  if reliquary_ok
    and type(reliquary) == "table"
    and type(reliquary.apply) == "function"
  then
    pcall(reliquary.apply, buf)
  end
  refresh_buffer_highlighting(buf)
  return filetype
end

local function replace_inspection_lines(endpoint, lines)
  if not valid_endpoint(endpoint)
    or type(vim.b[endpoint.buf].oculus_inspect) ~= "table"
  then
    return false
  end
  vim.bo[endpoint.buf].readonly = false
  vim.bo[endpoint.buf].modifiable = true
  vim.api.nvim_buf_set_lines(endpoint.buf, 0, -1, false, lines)
  vim.bo[endpoint.buf].modifiable = false
  vim.bo[endpoint.buf].readonly = true
  return true
end

local function render_focused_chunk(session, chunk_index)
  local hunk = session.hunks and session.hunks[chunk_index] or nil
  if not hunk then
    return
  end
  local lines, start = focused_change_lines(
    session.parent_content,
    session.change_content,
    hunk
  )
  if not replace_inspection_lines(session.change, lines) then
    return
  end
  session.active_chunk = chunk_index
  session.focused_start = start
  session.focused_chunks = true
  apply_change_signs(session.parent.buf, session.change.buf, {
    {
      old_start = hunk.old_start,
      old_count = hunk.old_count,
      new_start = start,
      new_count = hunk.new_count,
    },
  })
  refresh_buffer_highlighting(session.change.buf)
  return start
end

local function set_change_cursor(win, line)
  if not vim.api.nvim_win_is_valid(win) then
    return
  end
  local buf = vim.api.nvim_win_get_buf(win)
  local line_count = vim.api.nvim_buf_line_count(buf)
  line = math.min(math.max(1, line), line_count)
  vim.api.nvim_win_set_cursor(win, { line, 0 })
  normalize_inspection_view(win)
  sync_window(win)
end

normalize_inspection_view = function(win)
  if not vim.api.nvim_win_is_valid(win) then
    return
  end
  vim.api.nvim_win_call(win, function()
    local cursor_line = vim.api.nvim_win_get_cursor(win)[1]
    if cursor_line < 10 then
      return
    end
    local keys = vim.api.nvim_replace_termcodes(
      "zt10<C-y>^",
      true,
      false,
      true
    )
    vim.cmd("normal! " .. keys)
    local buf = vim.api.nvim_win_get_buf(win)
    local text = vim.api.nvim_buf_get_lines(
      buf,
      cursor_line - 1,
      cursor_line,
      false
    )[1] or ""
    vim.api.nvim_win_set_cursor(
      win,
      { cursor_line, math.max(0, #text - 1) }
    )
    local view = vim.fn.winsaveview()
    view.topline = math.max(1, cursor_line - 10)
    vim.fn.winrestview(view)
  end)
end

local function select_endpoint(endpoint)
  if not valid_endpoint(endpoint) then
    return
  end
  sidebar_navigating = true
  vim.api.nvim_set_current_tabpage(endpoint.tab)
  vim.api.nvim_set_current_win(endpoint.win)
  show_inspection_path(endpoint.buf)
  sidebar_navigating = false
end

local function map_file_navigation(endpoint, session, role, group)
  local function toggle_version()
    local line = vim.api.nvim_win_get_cursor(endpoint.win)[1]
    local chunk_index = hunk_index_at_line(session, role, line)
    if chunk_index and chunk_index ~= session.active_chunk then
      render_focused_chunk(session, chunk_index)
    end
    select_endpoint(
      role == "parent" and session.change or session.parent
    )
  end
  local version_lhs = group.version_switch
  if version_lhs == nil then
    version_lhs = default_version_switch
  end
  if type(version_lhs) == "string" and version_lhs ~= "" then
    vim.keymap.set("n", version_lhs, toggle_version, {
      buffer = endpoint.buf,
      nowait = true,
      silent = true,
      desc = "Switch Oculus file version",
    })
  end
end

local function sidebar_active_item(group, tab)
  for index, session in ipairs(group) do
    if group.kind == "issue"
      and valid_endpoint(session.issue)
      and session.issue.tab == tab
    then
      return index, "issue"
    end
    if valid_endpoint(session.parent) and session.parent.tab == tab then
      return index, "parent"
    end
    if valid_endpoint(session.change) and session.change.tab == tab then
      return index, "change"
    end
  end
end

local function select_next_sidebar_file(group)
  if
    group.kind == "issue"
    or group.sidebar_mode == "overview"
    or vim.api.nvim_get_current_buf() ~= group.sidebar_buf
  then
    return
  end
  local current_index, role =
    sidebar_active_item(group, vim.api.nvim_get_current_tabpage())
  if not current_index or not role then
    return
  end
  for offset = 1, #group do
    local next_index = ((current_index + offset - 1) % #group) + 1
    local endpoint = group[next_index][role]
    if valid_endpoint(endpoint) then
      local sidebar_win = group.sidebar_windows[endpoint.tab]
      if not sidebar_win or not vim.api.nvim_win_is_valid(sidebar_win) then
        return
      end
      sidebar_navigating = true
      vim.api.nvim_set_current_tabpage(endpoint.tab)
      vim.api.nvim_set_current_win(sidebar_win)
      local row = group.sidebar_rows[next_index]
      if row then
        vim.api.nvim_win_set_cursor(sidebar_win, { row.line_number, 0 })
      end
      group.focused_win = sidebar_win
      refresh_sidebar(group, endpoint.tab)
      sidebar_navigating = false
      return
    end
  end
end

local function sidebar_target_role(active_index, active_role, entry, group)
  if group and group.kind == "issue" then
    return "issue"
  end
  if entry and entry.pair_index ~= active_index then
    return "parent"
  end
  return active_role
end

local function sidebar_endpoint(group, session, role)
  if not session then
    return nil
  end
  if group.kind == "issue" then
    return session.issue
  end
  return role and session[role] or nil
end

local function truncate_path(path, width)
  if vim.fn.strdisplaywidth(path) <= width then
    return path
  end
  if width <= 1 then
    return "…"
  end
  local characters = vim.fn.strchars(path)
  for start = 1, characters - 1 do
    local tail = vim.fn.strcharpart(path, start)
    if vim.fn.strdisplaywidth(tail) <= width - 1 then
      return "…" .. tail
    end
  end
  return "…"
end

local function sidebar_file(file)
  local normalized = file:gsub("\\", "/"):gsub("/+$", "")
  local parent, name = normalized:match("([^/]+)/([^/]+)$")
  if parent and name then
    return parent .. "/" .. name
  end
  return normalized
end

local function sidebar_row(file, width)
  local prefix = "• "
  local suffix = "P C"
  local path_width = math.max(
    1,
    width
      - vim.fn.strdisplaywidth(prefix)
      - vim.fn.strdisplaywidth(suffix)
      - 2
  )
  local path = truncate_path(file, path_width)
  local body = prefix .. path
  local padding = math.max(
    1,
    width
      - vim.fn.strdisplaywidth(body)
      - vim.fn.strdisplaywidth(suffix)
      - 1
  )
  local line = body .. string.rep(" ", padding) .. suffix .. " "
  return {
    line = line,
    parent_column = #line - 4,
    change_column = #line - 2,
  }
end

local function inspect_sidebar_width(proportion, columns)
  columns = math.max(1, tonumber(columns) or vim.o.columns)
  if type(proportion) ~= "number"
    or proportion <= 0
    or proportion >= 1
  then
    proportion = 28 / columns
  end
  local width = math.floor(columns * proportion)
  return math.min(
    math.max(20, width),
    math.max(1, columns - 20)
  )
end

local function issue_sidebar_row(file, width)
  local prefix = "• "
  local path_width = math.max(
    1,
    width - vim.fn.strdisplaywidth(prefix)
  )
  return {
    line = prefix .. truncate_path(file, path_width),
  }
end

local function sidebar_chunk_row(hunk, last)
  local branch = last and "└─" or "├─"
  local first = hunk.new_start
  local last_line = first + math.max(0, (hunk.new_count or 0) - 1)
  local delta = (hunk.new_count or 0) - (hunk.old_count or 0)
  local delta_text = delta > 0 and ("+" .. delta) or tostring(delta)
  return ("  %s %d-%d (%s)"):format(
    branch,
    first,
    last_line,
    delta_text
  )
end

local function inspection_overview(info)
  local overview = vim.deepcopy(info or {})
  local route = overview.kind == "pull_request"
      and (
        overview.forge == "codeberg"
            and ("pulls/" .. tostring(overview.number))
          or ("pull/" .. tostring(overview.number))
      )
    or ("commit/" .. tostring(
      overview.commit_details
        and overview.commit_details.sha
        or overview.sha
        or ""
    ))
  overview.url = overview.html_url
    or ("https://%s/%s/%s/%s"):format(
      overview.host or (
        overview.forge == "codeberg"
            and "codeberg.org"
          or "github.com"
      ),
      overview.owner or "",
      overview.repo or "",
      route
    )
  return overview
end

local function append_sidebar_text(lines, text, width, indent)
  indent = indent or ""
  local available = math.max(1, width - vim.fn.strdisplaywidth(indent))
  for _, paragraph in ipairs(vim.split(
    tostring(text or ""),
    "\n",
    { plain = true }
  )) do
    paragraph = vim.trim(paragraph)
    if paragraph == "" then
      lines[#lines + 1] = ""
    else
      local current = ""
      for word in paragraph:gmatch("%S+") do
        while vim.fn.strdisplaywidth(word) > available do
          if current ~= "" then
            lines[#lines + 1] = indent .. current
            current = ""
          end
          local take = math.max(1, available)
          local piece = vim.fn.strcharpart(word, 0, take)
          while vim.fn.strdisplaywidth(piece) > available and take > 1 do
            take = take - 1
            piece = vim.fn.strcharpart(word, 0, take)
          end
          lines[#lines + 1] = indent .. piece
          word = vim.fn.strcharpart(word, take)
        end
        local proposed = current == "" and word or (current .. " " .. word)
        if vim.fn.strdisplaywidth(proposed) <= available then
          current = proposed
        else
          lines[#lines + 1] = indent .. current
          current = word
        end
      end
      if current ~= "" then
        lines[#lines + 1] = indent .. current
      end
    end
  end
end

local function sidebar_overview_lines(overview, width, toggle)
  width = math.max(12, tonumber(width) or 28)
  local details = overview.commit_details or {}
  local is_pull_request = overview.kind == "pull_request"
  local lines = {
    "OVERVIEW",
    "",
  }
  local function field(label, value)
    if value == nil or value == "" then
      return
    end
    lines[#lines + 1] = label
    append_sidebar_text(lines, value, width, "  ")
    lines[#lines + 1] = ""
  end
  local function value_or(value, fallback)
    return type(value) == "string" and vim.trim(value) ~= ""
        and value
      or fallback
  end
  field("Title", value_or(
    is_pull_request and overview.title or details.subject,
    "Untitled"
  ))
  field("Description", value_or(
    is_pull_request and overview.body or details.body,
    "No description provided."
  ))
  local author
  if is_pull_request then
    author = overview.author and ("@" .. overview.author)
  else
    author = details.author_name or ""
    if details.author_email and details.author_email ~= "" then
      author = author .. " <" .. details.author_email .. ">"
    end
  end
  field("Author", value_or(author, "Unknown"))
  field("URL", overview.url)
  if is_pull_request then
    field("PR number", "#" .. tostring(overview.number or ""))
    local status = overview.merged and "Merged"
      or overview.draft and "Draft"
      or (
        type(overview.state) == "string"
          and overview.state:gsub("^%l", string.upper)
        or nil
      )
    field("Status", value_or(status, "Unknown"))
  end
  toggle = toggle == nil and default_overview_toggle or toggle
  if type(toggle) == "string" and toggle ~= "" then
    lines[#lines + 1] = toggle .. " changed files"
  end
  return lines
end

local function set_sidebar_buffer_lines(group, lines, mode)
  local buf = group.sidebar_buf
  if not buf or not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  if group.sidebar_rendered_mode ~= mode then
    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.bo[buf].modifiable = false
    group.sidebar_rendered_mode = mode
    for _, win in pairs(group.sidebar_windows or {}) do
      if vim.api.nvim_win_is_valid(win) then
        vim.api.nvim_win_set_cursor(win, { 1, 0 })
      end
    end
  end
  vim.b[buf].oculus_inspect_sidebar_mode = mode
end

local function issue_sidebar_section_row(section, last)
  local branch = last and "└─" or "├─"
  return ("  %s %d-%d"):format(
    branch,
    section.line,
    section.last_line or section.line
  )
end

local function issue_section_at_line(session, line)
  local closest
  local closest_distance
  for index, section in ipairs(session.sections or {}) do
    local first = section.line
    local last = section.last_line or first
    if line >= first and line <= last then
      return index
    end
    local distance = line < first and first - line or line - last
    if not closest_distance or distance < closest_distance then
      closest = index
      closest_distance = distance
    end
  end
  return closest
end

local function sidebar_chunk(group, session, role)
  local endpoint = sidebar_endpoint(group, session, role)
  if not valid_endpoint(endpoint) then
    return
  end
  local line = vim.api.nvim_win_get_cursor(endpoint.win)[1]
  if group.kind == "issue" then
    return issue_section_at_line(session, line)
  end
  local index = hunk_index_at_line(session, role, line)
  if index and index ~= session.active_chunk then
    render_focused_chunk(session, index)
  end
  return index or session.active_chunk
end

refresh_sidebar = function(group, tab)
  local buf = group.sidebar_buf
  if not buf or not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  if group.sidebar_mode == "overview" then
    set_sidebar_buffer_lines(
      group,
      group.sidebar_overview_lines,
      "overview"
    )
    vim.api.nvim_buf_clear_namespace(buf, sidebar_ns, 0, -1)
    vim.b[buf].oculus_inspect_sidebar_active = {
      mode = "overview",
    }
    vim.api.nvim_buf_set_extmark(buf, sidebar_ns, 0, 0, {
      line_hl_group = "Title",
      priority = 100,
    })
    return
  end
  set_sidebar_buffer_lines(group, group.sidebar_lines, "files")
  local active_index, active_role = sidebar_active_item(group, tab)
  if not active_index then
    return
  end
  local normal_hl =
    vim.api.nvim_get_hl(0, { name = "Normal", link = false })
  local parent_hl =
    vim.api.nvim_get_hl(0, { name = "DiagnosticError", link = false })
  vim.api.nvim_set_hl(0, "OculusInspectSidebarParent", {
    fg = parent_hl.fg or 0xe06c75,
    bg = normal_hl.bg,
    default = true,
  })
  vim.api.nvim_set_hl(0, "OculusInspectSidebarParentActive", {
    fg = parent_hl.fg or 0xe06c75,
    bg = normal_hl.bg,
    underline = true,
    default = true,
  })
  vim.api.nvim_set_hl(0, "OculusInspectSidebarChange", {
    fg = 0x00c853,
    bg = normal_hl.bg,
    default = true,
  })
  vim.api.nvim_set_hl(0, "OculusInspectSidebarChangeActive", {
    fg = 0x00c853,
    bg = normal_hl.bg,
    underline = true,
    default = true,
  })
  local active_chunk =
    sidebar_chunk(group, group[active_index], active_role)
  vim.api.nvim_buf_clear_namespace(buf, sidebar_ns, 0, -1)
  local sidebar_win = group.sidebar_windows
      and group.sidebar_windows[tab]
    or nil
  local sidebar_is_focused = sidebar_win
    and vim.api.nvim_win_is_valid(sidebar_win)
    and vim.api.nvim_get_current_win() == sidebar_win
    and vim.api.nvim_get_current_buf() == buf
  local active_row = group.sidebar_rows[active_index]
  local active_chunk_line = active_chunk
      and group.sidebar_chunk_lines[active_index]
      and group.sidebar_chunk_lines[active_index][active_chunk]
    or nil
  local sidebar_cursor_line = active_chunk_line
    or (active_row and active_row.line_number)
  if sidebar_cursor_line
    and sidebar_win
    and vim.api.nvim_win_is_valid(sidebar_win)
    and vim.api.nvim_win_get_buf(sidebar_win) == buf
    and not sidebar_navigating
    and not sidebar_is_focused
    and vim.api.nvim_win_get_cursor(sidebar_win)[1]
      ~= sidebar_cursor_line
  then
    local was_navigating = sidebar_navigating
    sidebar_navigating = true
    vim.api.nvim_win_set_cursor(
      sidebar_win,
      { sidebar_cursor_line, 0 }
    )
    sidebar_navigating = was_navigating
  end
  local anchor_line = group.sidebar_anchor_line
  if anchor_line
    and anchor_line >= 1
    and anchor_line <= vim.api.nvim_buf_line_count(buf)
  then
    vim.api.nvim_buf_set_extmark(
      buf,
      sidebar_ns,
      anchor_line - 1,
      0,
      {
        line_hl_group = "CursorLine",
        hl_eol = true,
        priority = 90,
      }
    )
  end
  if group.kind ~= "issue" then
    for index, _ in ipairs(group) do
      local row = group.sidebar_rows[index]
      vim.api.nvim_buf_set_extmark(
        buf,
        sidebar_ns,
        row.line_number - 1,
        row.parent_column,
        {
          end_col = row.parent_column + 1,
          hl_group = index == active_index
              and active_role == "parent"
              and "OculusInspectSidebarParentActive"
            or "OculusInspectSidebarParent",
          priority = 100,
        }
      )
      vim.api.nvim_buf_set_extmark(
        buf,
        sidebar_ns,
        row.line_number - 1,
        row.change_column,
        {
          end_col = row.change_column + 1,
          hl_group = index == active_index
              and active_role == "change"
              and "OculusInspectSidebarChangeActive"
            or "OculusInspectSidebarChange",
          priority = 100,
        }
      )
    end
  end
  vim.b[buf].oculus_inspect_sidebar_active = {
    pair_index = active_index,
    role = active_role,
    chunk_index = active_chunk,
    chunk_count = group.kind == "issue"
        and #(group[active_index].sections or {})
      or #(group[active_index].hunks or {}),
  }
end

local function create_sidebar_window(group, endpoint)
  if not valid_endpoint(endpoint) then
    return
  end
  vim.api.nvim_set_current_tabpage(endpoint.tab)
  vim.api.nvim_set_current_win(endpoint.win)
  vim.cmd("botright vsplit")
  local win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(win, group.sidebar_buf)
  vim.api.nvim_win_set_width(win, group.sidebar_width)
  vim.wo[win].winfixwidth = true
  vim.wo[win].number = false
  vim.wo[win].relativenumber = false
  vim.wo[win].signcolumn = "no"
  vim.wo[win].foldcolumn = "0"
  vim.wo[win].wrap = false
  vim.wo[win].cursorline = true
  vim.wo[win].cursorlineopt = "line"
  prevent_window_dimming(win)
  group.sidebar_windows[endpoint.tab] = win
  vim.api.nvim_set_current_win(endpoint.win)
end

local function endpoint_for_tab(group, tab)
  local index, role = sidebar_active_item(group, tab)
  local session = index and group[index] or nil
  return sidebar_endpoint(group, session, role)
end

close_inspection_sidebar = function(group)
  local origin_tab = vim.api.nvim_get_current_tabpage()
  local origin_win = vim.api.nvim_get_current_win()
  local sidebar_focused =
    vim.api.nvim_get_current_buf() == group.sidebar_buf
  local fallback = endpoint_for_tab(group, origin_tab)
  group.sidebar_visible = false
  group.sidebar_focus_generation =
    (group.sidebar_focus_generation or 0) + 1
  group.focused_win = nil
  sidebar_navigating = true
  for tab, win in pairs(group.sidebar_windows or {}) do
    if vim.api.nvim_tabpage_is_valid(tab)
      and vim.api.nvim_win_is_valid(win)
    then
      vim.api.nvim_win_close(win, true)
    end
  end
  group.sidebar_windows = {}
  local focus_win = sidebar_focused
      and fallback
      and fallback.win
    or origin_win
  if focus_win and vim.api.nvim_win_is_valid(focus_win) then
    vim.api.nvim_set_current_win(focus_win)
  end
  sidebar_navigating = false
end

open_inspection_sidebar = function(group)
  local origin_tab = vim.api.nvim_get_current_tabpage()
  local origin_win = vim.api.nvim_get_current_win()
  group.sidebar_windows = {}
  group.sidebar_visible = true
  sidebar_navigating = true
  for _, session in ipairs(group) do
    if group.kind == "issue" then
      create_sidebar_window(group, session.issue)
    else
      create_sidebar_window(group, session.parent)
      create_sidebar_window(group, session.change)
    end
  end
  if vim.api.nvim_tabpage_is_valid(origin_tab)
    and vim.api.nvim_win_is_valid(origin_win)
  then
    vim.api.nvim_set_current_tabpage(origin_tab)
    vim.api.nvim_set_current_win(origin_win)
  end
  sidebar_navigating = false
  refresh_sidebar(group, vim.api.nvim_get_current_tabpage())
end

local function toggle_inspection_sidebar(group)
  if group.sidebar_visible then
    close_inspection_sidebar(group)
  else
    open_inspection_sidebar(group)
  end
end

local function capture_window_state(win)
  if not win or not vim.api.nvim_win_is_valid(win) then
    return nil
  end
  return {
    win = win,
    cursor = vim.api.nvim_win_get_cursor(win),
    view = vim.api.nvim_win_call(win, function()
      return vim.fn.winsaveview()
    end),
  }
end

local function restore_window_state(state)
  if not state or not vim.api.nvim_win_is_valid(state.win) then
    return
  end
  vim.api.nvim_win_set_cursor(state.win, state.cursor)
  vim.api.nvim_win_call(state.win, function()
    vim.fn.winrestview(state.view)
  end)
end

show_inspection_overview = function(group)
  local tab = vim.api.nvim_get_current_tabpage()
  local sidebar_win = vim.api.nvim_get_current_win()
  local endpoint = endpoint_for_tab(group, tab)
  group.overview_return = {
    tab = tab,
    sidebar = capture_window_state(sidebar_win),
    endpoint = endpoint and capture_window_state(endpoint.win),
    anchor_line = group.sidebar_anchor_line,
  }
  group.sidebar_mode = "overview"
  group.sidebar_rendered_mode = nil
  if not group.sidebar_visible then
    open_inspection_sidebar(group)
  else
    refresh_sidebar(group, vim.api.nvim_get_current_tabpage())
  end
end

show_sidebar_files = function(group)
  local return_state = group.overview_return
  sidebar_navigating = true
  group.sidebar_mode = "files"
  group.sidebar_rendered_mode = nil
  group.sidebar_anchor_line = return_state and return_state.anchor_line or nil
  local tab = return_state
      and vim.api.nvim_tabpage_is_valid(return_state.tab)
      and return_state.tab
    or vim.api.nvim_get_current_tabpage()
  refresh_sidebar(group, tab)
  if return_state then
    restore_window_state(return_state.endpoint)
    if vim.api.nvim_tabpage_is_valid(return_state.tab) then
      vim.api.nvim_set_current_tabpage(return_state.tab)
    end
    restore_window_state(return_state.sidebar)
    if return_state.sidebar
      and vim.api.nvim_win_is_valid(return_state.sidebar.win)
    then
      vim.api.nvim_set_current_win(return_state.sidebar.win)
      group.focused_win = return_state.sidebar.win
    end
  end
  group.overview_return = nil
  group.sidebar_focus_generation =
    (group.sidebar_focus_generation or 0) + 1
  sidebar_navigating = false
end

local function map_inspection_sidebar_toggle(group)
  local opts = {
    nowait = true,
    silent = true,
    desc = "Toggle Oculus Inspect sidebar",
  }
  local lhs = group.sidebar_toggle
  if lhs == nil then
    lhs = default_sidebar_toggle
  end
  local function map_buffer(buf)
    if type(lhs) == "string" and lhs ~= "" then
      vim.keymap.set("n", lhs, function()
        toggle_inspection_sidebar(group)
      end, vim.tbl_extend("force", opts, {
        buffer = buf,
      }))
    end
  end
  for _, session in ipairs(group) do
    local endpoints = group.kind == "issue"
        and { session.issue }
      or { session.parent, session.change }
    for _, endpoint in ipairs(endpoints) do
      if valid_endpoint(endpoint) then
        map_buffer(endpoint.buf)
      end
    end
  end
  map_buffer(group.sidebar_buf)
  local overview_lhs = group.overview_toggle
  if overview_lhs == nil then
    overview_lhs = default_overview_toggle
  end
  if type(overview_lhs) == "string" and overview_lhs ~= "" then
    vim.keymap.set("n", overview_lhs, function()
      if group.sidebar_mode == "overview" then
        show_sidebar_files(group)
      else
        show_inspection_overview(group)
      end
    end, {
      buffer = group.sidebar_buf,
      nowait = true,
      silent = true,
      desc = "Toggle Oculus Inspect overview",
    })
  end
  vim.keymap.set("n", "<CR>", function()
    focus_sidebar_selection(group)
  end, {
    buffer = group.sidebar_buf,
    nowait = true,
    silent = true,
    desc = "Open Oculus Inspect sidebar item",
  })
  local next_chunk_lhs = group.next_chunk
  if next_chunk_lhs == nil then
    next_chunk_lhs = default_next_chunk
  end
  if type(next_chunk_lhs) == "string" and next_chunk_lhs ~= "" then
    vim.keymap.set("n", next_chunk_lhs, function()
      select_next_sidebar_chunk(group)
    end, {
      buffer = group.sidebar_buf,
      nowait = true,
      silent = true,
      desc = "Next Oculus changed chunk",
    })
  end
  if group.kind ~= "issue" then
    local version_lhs = group.version_switch
    if version_lhs == nil then
      version_lhs = default_version_switch
    end
    if type(version_lhs) == "string" and version_lhs ~= "" then
      vim.keymap.set("n", version_lhs, function()
        switch_sidebar_version(group)
      end, {
        buffer = group.sidebar_buf,
        nowait = true,
        silent = true,
        desc = "Switch Oculus file version",
      })
    end
    local next_file_lhs = group.next_file
    if next_file_lhs == nil then
      next_file_lhs = default_next_file
    end
    if type(next_file_lhs) == "string" and next_file_lhs ~= "" then
      vim.keymap.set("n", next_file_lhs, function()
        select_next_sidebar_file(group)
      end, {
        buffer = group.sidebar_buf,
        nowait = true,
        silent = true,
        desc = "Next Oculus changed file",
      })
    end
  end
end

local function prepare_inspection_sidebar(group)
  local buf = vim.api.nvim_create_buf(false, true)
  group.sidebar_buf = buf
  group.sidebar_windows = {}
  group.sidebar_visible = false
  group.sidebar_width = inspect_sidebar_width(
    group.sidebar_width_proportion,
    vim.o.columns
  )
  group.sidebar_rows = {}
  group.sidebar_chunk_lines = {}
  group.sidebar_entries = {}
  group.sidebar_lines = {}
  group.sidebar_mode = "files"
  group.sidebar_rendered_mode = nil
  group.overview = group.overview or {}
  group.sidebar_overview_lines = sidebar_overview_lines(
    group.overview,
    group.sidebar_width,
    group.overview_toggle
  )
  local lines = {}
  for index, session in ipairs(group) do
    session.file = session.file or ("file " .. index)
    local chunks = group.kind == "issue"
        and (session.sections or {})
      or (session.hunks or {})
    local total = #chunks
    local row = group.kind == "issue"
        and issue_sidebar_row(
          sidebar_file(session.file),
          group.sidebar_width
        )
      or sidebar_row(
        sidebar_file(session.file),
        group.sidebar_width
      )
    local file_line = #lines + 1
    row.line_number = file_line
    group.sidebar_rows[index] = row
    group.sidebar_chunk_lines[index] = {}
    group.sidebar_entries[file_line] = {
      pair_index = index,
    }
    lines[file_line] = row.line
    for chunk_index, chunk in ipairs(chunks) do
      local chunk_line = #lines + 1
      group.sidebar_chunk_lines[index][chunk_index] = chunk_line
      group.sidebar_entries[chunk_line] = {
        pair_index = index,
        chunk_index = chunk_index,
      }
      lines[chunk_line] = group.kind == "issue"
          and issue_sidebar_section_row(
            chunk,
            chunk_index == total
          )
        or sidebar_chunk_row(
          chunk,
          chunk_index == total
        )
    end
  end
  group.sidebar_lines = lines
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "hide"
  vim.bo[buf].swapfile = false
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  group.sidebar_rendered_mode = "files"
  vim.bo[buf].filetype = "oculus-inspect-files"
end

local function activate_inspection_sidebar(group)
  map_inspection_sidebar_toggle(group)
  sidebar_groups[#sidebar_groups + 1] = group
  open_inspection_sidebar(group)
end

local function sidebar_group_for_buffer(buf)
  for _, group in ipairs(sidebar_groups) do
    if group.sidebar_buf == buf then
      return group
    end
  end
end

local function open_sidebar_selection(group)
  if sidebar_navigating or group.sidebar_mode == "overview" then
    return
  end
  local tab = vim.api.nvim_get_current_tabpage()
  local active_index, role = sidebar_active_item(group, tab)
  local line = vim.api.nvim_win_get_cursor(0)[1]
  local entry = group.sidebar_entries[line]
  local session = entry and group[entry.pair_index] or nil
  role = sidebar_target_role(active_index, role, entry, group)
  local endpoint = sidebar_endpoint(group, session, role)
  if not valid_endpoint(endpoint) then
    return
  end
  local sidebar_win = group.sidebar_windows[endpoint.tab]
  if not sidebar_win or not vim.api.nvim_win_is_valid(sidebar_win) then
    return
  end
  local source_win = vim.api.nvim_get_current_win()
  local source_view = vim.api.nvim_win_call(source_win, function()
    return vim.fn.winsaveview()
  end)
  group.sidebar_anchor_line = nil
  sidebar_navigating = true
  if entry.chunk_index then
    local start
    if group.kind == "issue" then
      local section = session.sections[entry.chunk_index]
      start = section and section.line
    else
      start = render_focused_chunk(session, entry.chunk_index)
        or focused_hunk_start(session.hunks[entry.chunk_index])
    end
    if start then
      set_change_cursor(endpoint.win, start)
    end
  end
  show_inspection_path(endpoint.buf)
  if sidebar_win ~= source_win then
    vim.api.nvim_win_set_cursor(sidebar_win, { line, 0 })
    source_view.lnum = line
    source_view.col = 0
    source_view.curswant = 0
    vim.api.nvim_win_call(sidebar_win, function()
      vim.fn.winrestview(source_view)
    end)
    vim.api.nvim_set_current_win(sidebar_win)
  end
  group.focused_win = sidebar_win
  refresh_sidebar(group, endpoint.tab)
  sidebar_navigating = false
end

select_next_sidebar_chunk = function(group)
  if
    group.sidebar_mode == "overview"
    or vim.api.nvim_get_current_buf() ~= group.sidebar_buf
  then
    return
  end
  local active_index, active_role =
    sidebar_active_item(group, vim.api.nvim_get_current_tabpage())
  local session = active_index and group[active_index] or nil
  local chunk_lines = active_index
      and group.sidebar_chunk_lines[active_index]
    or nil
  if not session or not chunk_lines or #chunk_lines == 0 then
    return
  end

  local line = vim.api.nvim_win_get_cursor(0)[1]
  local entry = group.sidebar_entries[line]
  local current_chunk = entry
      and entry.pair_index == active_index
      and entry.chunk_index
    or sidebar_chunk(group, session, active_role)
    or 0
  local next_chunk = (current_chunk % #chunk_lines) + 1
  vim.api.nvim_win_set_cursor(0, { chunk_lines[next_chunk], 0 })
  open_sidebar_selection(group)
end

focus_sidebar_selection = function(group)
  if
    sidebar_navigating
    or group.sidebar_mode == "overview"
    or vim.api.nvim_get_current_buf() ~= group.sidebar_buf
  then
    return
  end
  local tab = vim.api.nvim_get_current_tabpage()
  local active_index, role = sidebar_active_item(group, tab)
  local line = vim.api.nvim_win_get_cursor(0)[1]
  local entry = group.sidebar_entries[line]
  local session = entry and group[entry.pair_index] or nil
  role = sidebar_target_role(active_index, role, entry, group)
  local endpoint = sidebar_endpoint(group, session, role)
  if not valid_endpoint(endpoint) then
    return
  end

  local chunk_index = entry.chunk_index or 1
  local hunk = group.kind ~= "issue"
      and session.hunks
      and session.hunks[chunk_index]
    or nil
  local section = group.kind == "issue"
      and session.sections
      and session.sections[chunk_index]
    or nil
  group.sidebar_anchor_line = line
  sidebar_navigating = true
  group.sidebar_focus_generation =
    (group.sidebar_focus_generation or 0) + 1
  group.focused_win = nil
  vim.api.nvim_set_current_win(endpoint.win)
  if hunk then
    local start = render_focused_chunk(session, chunk_index)
      or focused_hunk_start(hunk)
    set_change_cursor(endpoint.win, start)
  elseif section then
    set_change_cursor(endpoint.win, section.line)
  end
  show_inspection_path(endpoint.buf)
  refresh_sidebar(group, endpoint.tab)
  sidebar_navigating = false
end

switch_sidebar_version = function(group)
  if
    sidebar_navigating
    or group.sidebar_mode == "overview"
    or vim.api.nvim_get_current_buf() ~= group.sidebar_buf
  then
    return
  end
  local tab = vim.api.nvim_get_current_tabpage()
  local _, role = sidebar_active_item(group, tab)
  local line = vim.api.nvim_win_get_cursor(0)[1]
  local entry = group.sidebar_entries[line]
  local session = entry and group[entry.pair_index] or nil
  if entry and entry.chunk_index and session then
    render_focused_chunk(session, entry.chunk_index)
  end
  local target_role = role == "parent" and "change" or "parent"
  local endpoint = session and session[target_role] or nil
  if not valid_endpoint(endpoint) then
    return
  end
  local sidebar_win = group.sidebar_windows[endpoint.tab]
  if not sidebar_win or not vim.api.nvim_win_is_valid(sidebar_win) then
    return
  end

  local source_win = vim.api.nvim_get_current_win()
  local source_view = vim.api.nvim_win_call(source_win, function()
    return vim.fn.winsaveview()
  end)
  sidebar_navigating = true
  vim.api.nvim_win_set_cursor(sidebar_win, { line, 0 })
  source_view.lnum = line
  source_view.col = 0
  source_view.curswant = 0
  vim.api.nvim_win_call(sidebar_win, function()
    vim.fn.winrestview(source_view)
  end)
  show_inspection_path(endpoint.buf)
  vim.api.nvim_set_current_win(sidebar_win)
  group.focused_win = sidebar_win
  refresh_sidebar(group, endpoint.tab)
  sidebar_navigating = false
end

vim.api.nvim_create_autocmd("TabEnter", {
  group = sync_group,
  callback = function()
    local tab = vim.api.nvim_get_current_tabpage()
    for _, group in ipairs(sidebar_groups) do
      local endpoint = endpoint_for_tab(group, tab)
      if endpoint then
        apply_inspection_filetype(endpoint.buf)
      end
      refresh_sidebar(group, tab)
    end
  end,
})

vim.api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI" }, {
  group = sync_group,
  callback = function(args)
    local group = sidebar_group_for_buffer(args.buf)
    if group
      and vim.api.nvim_get_current_buf() == args.buf
      and group.focused_win == vim.api.nvim_get_current_win()
    then
      local generation = group.sidebar_focus_generation or 0
      local focused_win = group.focused_win
      vim.schedule(function()
        if group.sidebar_focus_generation == generation
          and group.focused_win == focused_win
          and focused_win == vim.api.nvim_get_current_win()
          and vim.api.nvim_get_current_buf() == group.sidebar_buf
        then
          open_sidebar_selection(group)
        end
      end)
      return
    end
    local tab = vim.api.nvim_get_current_tabpage()
    for _, candidate in ipairs(sidebar_groups) do
      candidate.sidebar_focus_generation =
        (candidate.sidebar_focus_generation or 0) + 1
      candidate.focused_win = nil
      refresh_sidebar(candidate, tab)
    end
  end,
})

vim.api.nvim_create_autocmd("WinEnter", {
  group = sync_group,
  callback = function(args)
    local current_win = vim.api.nvim_get_current_win()
    for _, candidate in ipairs(sidebar_groups) do
      if candidate.focused_win ~= current_win then
        candidate.sidebar_focus_generation =
          (candidate.sidebar_focus_generation or 0) + 1
        candidate.focused_win = nil
      end
    end
    local group = sidebar_group_for_buffer(args.buf)
    if group
      and vim.api.nvim_get_current_buf() == args.buf
    then
      group.sidebar_focus_generation =
        (group.sidebar_focus_generation or 0) + 1
      group.focused_win = current_win
      open_sidebar_selection(group)
      return
    end
    local tab = vim.api.nvim_get_current_tabpage()
    for _, candidate in ipairs(sidebar_groups) do
      refresh_sidebar(candidate, tab)
    end
  end,
})

vim.api.nvim_create_autocmd("WinLeave", {
  group = sync_group,
  callback = function(args)
    local group = sidebar_group_for_buffer(args.buf)
    if group and group.focused_win == vim.api.nvim_get_current_win() then
      group.sidebar_focus_generation =
        (group.sidebar_focus_generation or 0) + 1
      group.focused_win = nil
    end
  end,
})

local function comment_session(group, comment)
  local role = comment.side == "parent" and "parent" or "change"
  local fallback
  for _, session in ipairs(group) do
    local file = role == "parent"
        and session.parent_file
      or session.change_file
    if file
      and comparable_path(file) == comparable_path(comment.path)
      and valid_endpoint(session[role])
    then
      fallback = session
      local revision = role == "parent"
          and session.parent_commit
        or session.change_commit
      if
        comment.commit
        and revision
        and revision:lower() == comment.commit:lower()
      then
        return session, session[role], role
      end
    end
  end
  return fallback, fallback and fallback[role] or nil, role
end

local function comment_float(endpoint, comment)
  if not valid_endpoint(endpoint) then
    return nil
  end
  local main_width = vim.api.nvim_win_get_width(endpoint.win)
  local main_height = vim.api.nvim_win_get_height(endpoint.win)
  local width = math.max(1, math.min(50, main_width - 4))
  local lines = vim.split(comment.body, "\n", { plain = true })
  if #lines == 0 then
    lines = { "" }
  end
  for index, line in ipairs(lines) do
    lines[index] = line:gsub("\r$", "")
  end
  local display_rows = 0
  for _, line in ipairs(lines) do
    display_rows = display_rows
      + math.max(
        1,
        math.ceil(vim.fn.strdisplaywidth(line) / width)
      )
  end
  local height = math.max(
    1,
    math.min(8, display_rows, main_height - 2)
  )
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = "markdown"
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false

  local win = vim.api.nvim_open_win(buf, false, {
    relative = "win",
    win = endpoint.win,
    anchor = "SW",
    bufpos = { comment.line - 1, 0 },
    row = 0,
    col = math.max(0, main_width - width - 2),
    width = width,
    height = height,
    style = "minimal",
    border = "rounded",
    title = " Comment ",
    title_pos = "left",
    focusable = false,
    noautocmd = true,
    zindex = 80,
  })
  vim.wo[win].wrap = true
  vim.wo[win].linebreak = true
  vim.wo[win].number = false
  vim.wo[win].relativenumber = false
  vim.wo[win].signcolumn = "no"
  vim.b[buf].oculus_inspect_comment = vim.deepcopy(comment)
  endpoint.comment_buf = buf
  endpoint.comment_win = win
  return {
    buf = buf,
    win = win,
    line = comment.line,
  }
end

local function setup_inspection_comment(group, comment)
  if not comment then
    return
  end
  local session, endpoint, role = comment_session(group, comment)
  if not session or not valid_endpoint(endpoint) then
    return
  end
  local chunk_index =
    revision_hunk_index_at_line(session, role, comment.line)
  if chunk_index then
    local hunk = session.hunks[chunk_index]
    local revision_start = hunk_start(hunk, role)
    local offset = math.max(0, comment.line - revision_start)
    local focused_start =
      render_focused_chunk(session, chunk_index)
        or focused_hunk_start(hunk)
    comment.line = focused_start + offset
  end
  local line_count = vim.api.nvim_buf_line_count(endpoint.buf)
  comment.line = math.min(math.max(1, comment.line), line_count)
  sidebar_navigating = true
  vim.api.nvim_set_current_win(endpoint.win)
  set_change_cursor(endpoint.win, comment.line)
  show_inspection_path(endpoint.buf)
  session.comment = comment_float(endpoint, comment)
  refresh_sidebar(group, endpoint.tab)
  sidebar_navigating = false
end

local spinner_frames = {
  "⠋",
  "⠙",
  "⠹",
  "⠸",
  "⠼",
  "⠴",
  "⠦",
  "⠧",
  "⠇",
  "⠏",
}

local function stop_loading(loading)
  if not loading or loading.stopped then
    return
  end
  loading.stopped = true
  if loading.timer and not loading.timer:is_closing() then
    loading.timer:stop()
    loading.timer:close()
  end
end

local function emit_loading(loading, event, ...)
  local lifecycle = loading and loading.lifecycle
  local callback = lifecycle and lifecycle[event]
  if type(callback) == "function" then
    pcall(callback, ...)
    return true
  end
  return false
end

local function start_loading(lifecycle)
  local loading = {
    frame = 1,
    stopped = false,
    lifecycle = lifecycle,
  }
  emit_loading(loading, "on_progress", spinner_frames[1])

  loading.timer = vim.uv.new_timer()
  loading.timer:start(120, 120, vim.schedule_wrap(function()
    if loading.stopped then
      return
    end
    loading.frame = (loading.frame % #spinner_frames) + 1
    local frame = spinner_frames[loading.frame]
    emit_loading(loading, "on_progress", frame)
  end))
  return loading
end

local function show_loading_error(loading, message)
  stop_loading(loading)
  if not emit_loading(loading, "on_complete", message) then
    vim.schedule(function()
      vim.notify(
        "Oculus: " .. tostring(message),
        vim.log.levels.WARN
      )
    end)
  end
end

local function load_tab(
  endpoint,
  path,
  file,
  role,
  inspection,
  pair_index
)
  if not vim.api.nvim_tabpage_is_valid(endpoint.tab) then
    error("an inspection tab was closed before it finished opening")
  end
  vim.api.nvim_set_current_tabpage(endpoint.tab)
  if vim.api.nvim_win_is_valid(endpoint.win) then
    vim.api.nvim_set_current_win(endpoint.win)
  end
  local working_directory = inspection_directory(path, file)
  vim.cmd("tcd " .. vim.fn.fnameescape(working_directory))
  vim.cmd("enew")
  local buf = vim.api.nvim_get_current_buf()
  local lines = role == "change"
      and inspection.change_lines
    or inspection.parent_lines
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines or { "" })
  local filetype = file and vim.filetype.match({ filename = file }) or nil
  if filetype then
    vim.bo[buf].filetype = filetype
  end
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "hide"
  vim.bo[buf].swapfile = false
  vim.bo[buf].modifiable = false
  vim.bo[buf].readonly = true
  vim.b[buf].oculus_inspect_repository = path
  vim.b[buf].oculus_inspect_directory = working_directory
  vim.b[buf].oculus_inspect_source_path =
    file and vim.fs.joinpath(path, file) or nil
  local state = {
    kind = inspection.kind,
    role = role,
    commit = role == "change"
        and inspection.commit
      or inspection.parent,
    parent_commit = inspection.parent,
    change_commit = inspection.commit,
    repository = path,
    directory = working_directory,
    source_path = file and vim.fs.joinpath(path, file) or nil,
    loading = false,
    pair_index = pair_index,
    commit_index = inspection.commit_index,
    file_index = inspection.file_index,
    file_count = inspection.file_count,
    file = file,
    parent_file = inspection.parent_file,
    change_file = inspection.change_file,
    status = inspection.status,
  }
  vim.t.oculus_inspect = state
  vim.b[buf].oculus_inspect = vim.deepcopy(state)
  show_inspection_path(buf)
  local loaded = {
    tab = vim.api.nvim_get_current_tabpage(),
    win = vim.api.nvim_get_current_win(),
    buf = vim.api.nvim_get_current_buf(),
  }
  vim.wo[loaded.win].signcolumn = "yes"
  vim.wo[loaded.win].wrap = false
  return loaded
end

local function make_inspection_tab()
  vim.cmd("tabnew")
  return {
    tab = vim.api.nvim_get_current_tabpage(),
    win = vim.api.nvim_get_current_win(),
    buf = vim.api.nvim_get_current_buf(),
  }
end

local function apply_inspection_window_options(win, options)
  if not vim.api.nvim_win_is_valid(win) or type(options) ~= "table" then
    return
  end
  if type(options.number) == "boolean" then
    vim.wo[win].number = options.number
  end
  if type(options.relativenumber) == "boolean" then
    vim.wo[win].relativenumber = options.relativenumber
  end
  if type(options.winhighlight) == "string" then
    vim.wo[win].winhighlight = options.winhighlight
  end
  vim.wo[win].cursorline = true
  vim.wo[win].cursorlineopt = "line"
  prevent_window_dimming(win)
end

local function open_tabs(
  inspections,
  loading,
  comment,
  info,
  number_options,
  opts,
  done
)
  local staging_tab = vim.api.nvim_get_current_tabpage()
  local staging_win = vim.api.nvim_get_current_win()
  local previous_lazyredraw = vim.o.lazyredraw
  inspection_tabs_loading = true
  vim.o.lazyredraw = true
  local function restore_staging_window()
    if vim.api.nvim_tabpage_is_valid(staging_tab) then
      vim.api.nvim_set_current_tabpage(staging_tab)
    end
    if vim.api.nvim_win_is_valid(staging_win) then
      vim.api.nvim_set_current_win(staging_win)
    end
  end
  local ok, err = pcall(function()
    local inspection_sessions = {
      sidebar_toggle = opts.inspect_sidebar_toggle,
      sidebar_width_proportion = opts.inspect_sidebar_width,
      overview_toggle = opts.inspect_overview_toggle,
      version_switch = opts.inspect_version_switch,
      next_chunk = opts.inspect_next_chunk,
      next_file = opts.inspect_next_file,
      overview = inspection_overview(info),
    }
    for index, paths in ipairs(inspections) do
      inspection_sessions[index] = {
        file = paths.change_file or paths.parent_file,
        parent_file = paths.parent_file,
        change_file = paths.change_file,
        parent_commit = paths.parent,
        change_commit = paths.commit,
        parent_repository = paths.repository,
        change_repository = paths.repository,
        changes = paths.changes,
        hunks = paths.hunks,
        parent_content = vim.deepcopy(paths.parent_lines),
        change_content = vim.deepcopy(paths.change_lines),
        parent_lines = change_lines(paths.hunks, "parent"),
        change_lines = change_lines(paths.hunks),
        active_chunk = paths.hunks[1] and 1 or nil,
      }
    end

    -- Build the complete changed-file list before the first Inspect tab is
    -- created, so the first visible tab already has a ready sidebar.
    prepare_inspection_sidebar(inspection_sessions)

    for index, paths in ipairs(inspections) do
      local session = inspection_sessions[index]
      local parent_tab = make_inspection_tab()
      local parent = load_tab(
        parent_tab,
        paths.repository,
        paths.parent_file,
        paths.parent_role or "parent",
        paths,
        index
      )
      apply_inspection_window_options(parent.win, number_options)
      local change_tab = make_inspection_tab()
      local change = load_tab(
        change_tab,
        paths.repository,
        paths.change_file,
        "change",
        paths,
        index
      )
      apply_inspection_window_options(change.win, number_options)
      next_session = next_session + 1
      session.parent = parent
      session.change = change
      sessions[next_session] = session
      local focused_start = session.active_chunk
          and render_focused_chunk(session, session.active_chunk)
        or nil
      if not focused_start then
        apply_change_signs(parent.buf, change.buf, {})
      end
      map_file_navigation(
        parent,
        session,
        "parent",
        inspection_sessions
      )
      map_file_navigation(
        change,
        session,
        "change",
        inspection_sessions
      )
      if focused_start then
        set_change_cursor(parent.win, focused_start)
      elseif session.parent_lines[1] then
        set_change_cursor(parent.win, session.parent_lines[1])
      else
        sync_window(parent.win)
      end
    end
    restore_staging_window()
    activate_inspection_sidebar(inspection_sessions)
    for _, session in ipairs(inspection_sessions) do
      normalize_inspection_view(session.parent.win)
      normalize_inspection_view(session.change.win)
    end
    setup_inspection_comment(inspection_sessions, comment)
    restore_staging_window()

    local first = inspection_sessions[1]
      and inspection_sessions[1].parent
    if not valid_endpoint(first) then
      error("the first inspection tab was not created")
    end
    stop_loading(loading)
    require("oculus.window").close()
    vim.api.nvim_set_current_tabpage(first.tab)
    vim.api.nvim_set_current_win(first.win)
    show_inspection_path(first.buf)
  end)
  inspection_tabs_loading = false
  vim.o.lazyredraw = previous_lazyredraw
  if not ok then
    restore_staging_window()
    vim.cmd("redraw")
    done(nil, "could not open inspection tabs: " .. tostring(err))
    return
  end
  vim.cmd("redraw")
  emit_loading(loading, "on_complete")
  done(inspections)
end

local function blob_lines(output)
  local lines = vim.split(output or "", "\n", { plain = true })
  if #lines > 1 and lines[#lines] == "" then
    table.remove(lines)
  end
  for index, line in ipairs(lines) do
    lines[index] = line:gsub("\r$", "")
  end
  return #lines > 0 and lines or { "" }
end

local function read_revision_file(repository, revision, file, missing, callback)
  if missing then
    callback({ "" })
    return
  end
  run_raw({
    "git",
    "-C",
    repository,
    "show",
    revision .. ":" .. file,
  }, function(output, err)
    if err then
      callback(nil, "could not read inspected file: " .. err)
      return
    end
    callback(blob_lines(output))
  end)
end

local function read_revision_diff(
  repository,
  info,
  pair,
  commit_index,
  callback
)
  run({
    "git",
    "-C",
    repository,
    "diff",
    "--name-status",
    "-M",
    pair.parent,
    pair.commit,
    "--",
  }, function(changes, diff_err)
    if diff_err then
      callback(nil, "could not read commit changes: " .. diff_err)
      return
    end
    local changed_files = parse_changed_files(changes)
    local inspections = {}
    local file_index = 1
    local function read_file_diff()
      local changed_file = changed_files[file_index]
      if not changed_file then
        callback(inspections)
        return
      end

      local parent_file = changed_file.old_path
      local change_file = changed_file.new_path
      local diff_command = {
        "git",
        "-C",
        repository,
        "diff",
        "--no-color",
        "--no-ext-diff",
        "--unified=0",
        "-M",
        pair.parent,
        pair.commit,
        "--",
        parent_file,
      }
      if change_file ~= parent_file then
        diff_command[#diff_command + 1] = change_file
      end
      run(diff_command, function(patch, patch_err)
        if patch_err then
          callback(nil, "could not read file hunks: " .. patch_err)
          return
        end
        read_revision_file(
          repository,
          pair.parent,
          parent_file,
          changed_file.status == "A",
          function(parent_lines, parent_err)
            if parent_err then
              callback(nil, parent_err)
              return
            end
            read_revision_file(
              repository,
              pair.commit,
              change_file,
              changed_file.status == "D",
              function(change_lines_value, change_err)
                if change_err then
                  callback(nil, change_err)
                  return
                end
                inspections[file_index] = {
                  kind = info.kind,
                  parent = pair.parent,
                  commit = pair.commit,
                  parent_role = info.kind == "pull_request"
                      and "old"
                    or "parent",
                  repository = repository,
                  parent_file = parent_file,
                  change_file = change_file,
                  parent_lines = parent_lines,
                  change_lines = change_lines_value,
                  changes = changed_files,
                  hunks = parse_hunks(patch),
                  commit_index = commit_index,
                  file_index = file_index,
                  file_count = #changed_files,
                  status = changed_file.status,
                }
                file_index = file_index + 1
                read_file_diff()
              end
            )
          end
        )
      end)
    end
    read_file_diff()
  end)
end

local function prepare_revision(
  repository,
  info,
  pair,
  commit_index,
  callback
)
  read_revision_diff(
    repository,
    info,
    pair,
    commit_index,
    callback
  )
end

local function load_commit_overview(repository, info, commit, callback)
  if info.kind ~= "commit" then
    callback()
    return
  end
  run_raw({
    "git",
    "-C",
    repository,
    "show",
    "--no-patch",
    "--format=%H%x00%P%x00%an%x00%ae%x00%aI%x00%s%x00%b",
    commit,
  }, function(output)
    info.commit_details = parse_commit_overview(output)
    callback()
  end)
end

local function prepare(info, opts, callback)
  ensure_repository(info, opts, function(
    repository,
    repository_err,
    fetch_source
  )
    if repository_err then
      callback(nil, repository_err)
      return
    end
    if not repository then
      callback(nil, "inspect requires a standard local repository")
      return
    end
    fetch_pair(repository, fetch_source, info, function(commits, commit_err)
      if commit_err then
        callback(nil, commit_err)
        return
      end
      load_commit_overview(repository, info, commits.commit, function()
        revision_pairs(repository, info, commits, function(pairs, pairs_err)
          if pairs_err then
            callback(nil, pairs_err)
            return
          end
          local inspections = {}
          local index = 1
          local function prepare_next()
            local pair = pairs[index]
            if not pair then
              if #inspections == 0 then
                callback(
                  nil,
                  "the inspected revisions do not change any files"
                )
                return
              end
              callback(inspections)
              return
            end
            prepare_revision(
              repository,
              info,
              pair,
              index,
              function(commit_inspections, err)
                if err then
                  callback(nil, err)
                  return
                end
                for _, inspection in ipairs(commit_inspections) do
                  inspections[#inspections + 1] = inspection
                end
                index = index + 1
                prepare_next()
              end
            )
          end
          prepare_next()
        end)
      end)
    end)
  end)
end

local function apply_pull_request(info, details)
  local resolved = vim.deepcopy(info)
  for _, key in ipairs({
    "title",
    "body",
    "author",
    "state",
    "draft",
    "merged",
    "html_url",
    "base_sha",
    "base_ref",
    "head_sha",
    "head_ref",
    "fetch_ref",
    "commit_count",
  }) do
    resolved[key] = details[key]
  end
  return resolved
end

local function resolve_target(info, opts, callback)
  if info.kind ~= "pull_request" then
    callback(info)
    return
  end

  local provider = info.forge == "codeberg" and codeberg or github
  provider.pull_request(
    info.owner .. "/" .. info.repo,
    info.number,
    opts,
    function(details, err)
      if not details then
        local message = info.via_issue
            and "this issue activity is not associated with a pull request"
          or (err or "could not resolve pull request")
        callback(nil, message)
        return
      end
      callback(apply_pull_request(info, details))
    end
  )
end

local function resolve_issue_details(info, opts, context, callback)
  local supplied = type(context) == "table"
      and type(context.issue) == "table"
      and vim.deepcopy(context.issue)
    or {}
  local provider = info.forge == "codeberg" and codeberg or github
  provider.issue(
    info.owner .. "/" .. info.repo,
    info.number,
    opts,
    function(details, err)
      details = details or supplied
      if not details
        or (
          type(details.title) ~= "string"
          and type(details.body) ~= "string"
          and type(details.comment) ~= "string"
        )
      then
        callback(nil, err or "could not load issue text")
        return
      end
      for key, value in pairs(supplied) do
        if value ~= nil and value ~= "" then
          if key == "comment" or details[key] == nil or details[key] == "" then
            details[key] = value
          end
        end
      end
      details.number = details.number or info.number
      callback(details)
    end
  )
end

local function append_issue_text(lines, text, fallback)
  if type(text) ~= "string" or vim.trim(text) == "" then
    lines[#lines + 1] = fallback
    return
  end
  for _, line in ipairs(vim.split(text, "\n", { plain = true })) do
    lines[#lines + 1] = line:gsub("\r$", "")
  end
end

local function issue_page_lines(info, details)
  local number = details.number or info.number
  local title = type(details.title) == "string"
      and vim.trim(details.title)
    or ""
  if title == "" then
    title = ("Issue #%s"):format(number)
  end
  local url = details.html_url
    or ("https://%s/%s/%s/issues/%s"):format(
      info.host,
      info.owner,
      info.repo,
      number
    )
  local lines = {
    "# " .. title,
    "",
    ("- Repository: `%s/%s`"):format(info.owner, info.repo),
    ("- Issue: `#%s`"):format(number),
    ("- Forge: `%s`"):format(info.forge),
    ("- URL: %s"):format(url),
    "",
    "## Description",
    "",
  }
  append_issue_text(lines, details.body, "_No description was provided._")
  if type(details.comment) == "string"
    and vim.trim(details.comment) ~= ""
  then
    lines[#lines + 1] = ""
    lines[#lines + 1] = "## Activity comment"
    lines[#lines + 1] = ""
    append_issue_text(lines, details.comment, "")
  end
  return lines
end

local function open_issue_page(
  info,
  details,
  loading,
  number_options,
  done
)
  local staging_tab = vim.api.nvim_get_current_tabpage()
  local staging_win = vim.api.nvim_get_current_win()
  local page
  local ok, err = pcall(function()
    vim.cmd("tabnew")
    local tab = vim.api.nvim_get_current_tabpage()
    local win = vim.api.nvim_get_current_win()
    local buf = vim.api.nvim_get_current_buf()
    next_session = next_session + 1
    vim.api.nvim_buf_set_name(
      buf,
      ("oculus-issue://%s/%s/%s/%s/%d"):format(
        info.host,
        info.owner,
        info.repo,
        details.number or info.number,
        next_session
      )
    )
    vim.api.nvim_buf_set_lines(
      buf,
      0,
      -1,
      false,
      issue_page_lines(info, details)
    )
    vim.bo[buf].buftype = "nofile"
    vim.bo[buf].bufhidden = "wipe"
    vim.bo[buf].swapfile = false
    vim.bo[buf].filetype = "markdown"
    vim.bo[buf].modifiable = false
    vim.bo[buf].readonly = true
    local state = {
      kind = "issue",
      role = "issue",
      forge = info.forge,
      owner = info.owner,
      repo = info.repo,
      issue_number = details.number or info.number,
      issue_title = details.title,
      issue_url = details.html_url,
      loading = false,
    }
    vim.t.oculus_inspect = vim.deepcopy(state)
    vim.b[buf].oculus_inspect = vim.deepcopy(state)
    vim.wo[win].wrap = true
    vim.wo[win].linebreak = true
    vim.wo[win].signcolumn = "no"
    apply_inspection_window_options(win, number_options)
    page = {
      tab = tab,
      win = win,
      buf = buf,
    }
    stop_loading(loading)
    require("oculus.window").close()
    vim.api.nvim_set_current_tabpage(tab)
    vim.api.nvim_set_current_win(win)
    vim.api.nvim_win_set_cursor(win, { 1, 0 })
  end)
  if not ok then
    if vim.api.nvim_tabpage_is_valid(staging_tab) then
      vim.api.nvim_set_current_tabpage(staging_tab)
    end
    if vim.api.nvim_win_is_valid(staging_win) then
      vim.api.nvim_set_current_win(staging_win)
    end
    done(nil, "could not open issue information: " .. tostring(err))
    return
  end
  vim.cmd("redraw")
  emit_loading(loading, "on_complete")
  done(page)
end

local function open_issue(
  info,
  opts,
  context,
  loading,
  number_options,
  done
)
  resolve_issue_details(info, opts, context, function(details, details_err)
    if not details then
      done(nil, details_err)
      return
    end
    open_issue_page(info, details, loading, number_options, done)
  end)
end

function M.open(url, opts, context, lifecycle)
  opts = opts or {}
  local info = parse_target_url(url)
  if not info then
    return nil,
      "inspect currently supports GitHub and Codeberg commit "
        .. "pull request, and issue activity"
  end
  if info.kind ~= "issue" and vim.fn.executable("git") ~= 1 then
    return nil, "inspect requires git"
  end
  if active then
    return nil, "an inspection is already being prepared"
  end
  local number_options = {
    number = vim.wo.number,
    relativenumber = vim.wo.relativenumber,
  }
  local window_ok, window = pcall(require, "oculus.window")
  if window_ok and type(window.inspection_window_options) == "function" then
    number_options = window.inspection_window_options() or number_options
  end
  local comment = context and (context.comment or context) or nil
  if comment then
    info.comment = vim.deepcopy(comment)
  end

  active = true
  local loading_ok, loading = pcall(
    start_loading,
    lifecycle
  )
  if not loading_ok then
    active = false
    return nil, "could not start inspection loading state: "
      .. tostring(loading)
  end
  if info.kind == "issue" then
    open_issue(
      info,
      opts,
      context,
      loading,
      number_options,
      function(_, issue_err)
        active = false
        if issue_err then
          show_loading_error(loading, issue_err)
        end
      end
    )
    return true
  end
  resolve_target(info, opts, function(resolved, resolve_err)
    if resolve_err then
      active = false
      show_loading_error(loading, resolve_err)
      return
    end

    prepare(
      resolved,
      opts,
      function(inspections, err)
        if err then
          active = false
          show_loading_error(loading, err)
          return
        end
        open_tabs(
          inspections,
          loading,
          resolved.comment,
          resolved,
          number_options,
          opts,
          function(_, open_err)
            active = false
            if open_err then
              show_loading_error(loading, open_err)
              return
            end
          end
        )
      end
    )
  end)
  return true
end

M._parse_commit_url = parse_commit_url
M._parse_pull_request_url = parse_pull_request_url
M._parse_issue_url = parse_issue_url
M._parse_target_url = parse_target_url
M._parse_commit_overview = parse_commit_overview
M.activity_comment = activity_comment
M.activity_context = activity_context
M._apply_pull_request = apply_pull_request
M._inspection_overview = inspection_overview
M._sidebar_overview_lines = sidebar_overview_lines
M._first_changed_paths = first_changed_paths
M._parse_changed_files = parse_changed_files
M._inspection_directory = inspection_directory
M._github_repository = github_repository
M._forge_repository = forge_repository
M._download_destination = download_destination
M._offer_repository_download = offer_repository_download
M._find_local_repository = find_local_repository
M._issue_page_lines = issue_page_lines
M._parse_hunks = parse_hunks
M._parse_revision_pairs = parse_revision_pairs
M._blob_lines = blob_lines
M._oil_entry_status = oil_entry_status
M._change_lines = change_lines
M._focused_change_lines = focused_change_lines
M._prevent_window_dimming = prevent_window_dimming
M._refresh_buffer_highlighting = refresh_buffer_highlighting
M._apply_inspection_filetype = apply_inspection_filetype
M._normalize_inspection_view = normalize_inspection_view
M._sidebar_row = sidebar_row
M._inspect_sidebar_width = inspect_sidebar_width
M._sidebar_chunk_row = sidebar_chunk_row
M._sidebar_file = sidebar_file
M._sidebar_target_role = sidebar_target_role
M._comment_float = comment_float

return M
