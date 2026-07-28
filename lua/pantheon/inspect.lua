local M = {}

local github = require("pantheon.github")
local codeberg = require("pantheon.codeberg")

local active = false
local change_ns = vim.api.nvim_create_namespace("pantheon_inspect_changes")
local loading_ns = vim.api.nvim_create_namespace("pantheon_inspect_loading")
local oil_ns = vim.api.nvim_create_namespace("pantheon_inspect_oil")
local sidebar_ns =
  vim.api.nvim_create_namespace("pantheon_inspect_sidebar")
local sessions = {}
local sidebar_groups = {}
local next_session = 0
local syncing = false
local sidebar_navigating = false
local normalize_inspection_view
local refresh_sidebar
local focus_sidebar_selection
local switch_sidebar_version

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
  local section = "pull"
  local forge = "github"
  local host = "github.com"
  if not owner then
    owner, repo, number, suffix = url:match(
      "^https?://github%.com/([^/]+)/([^/]+)/issues/(%d+)(.*)$"
    )
    section = "issues"
  end
  if not owner then
    owner, repo, number, suffix = url:match(
      "^https?://codeberg%.org/([^/]+)/([^/]+)/pulls/(%d+)(.*)$"
    )
    section = "pull"
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
    via_issue = section == "issues",
    owner = owner,
    repo = repo,
    number = tonumber(number),
    remote_url = ("https://%s/%s/%s.git"):format(host, owner, repo),
  }
end

local function parse_target_url(url)
  return parse_commit_url(url) or parse_pull_request_url(url)
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

local function hunk_index_at_line(session, role, line)
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

local function next_change_line(lines, current, direction)
  if #lines == 0 then
    return nil
  end
  if direction > 0 then
    for _, line in ipairs(lines) do
      if line > current then
        return line
      end
    end
    return lines[1]
  end
  for index = #lines, 1, -1 do
    if lines[index] < current then
      return lines[index]
    end
  end
  return lines[#lines]
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

  local function add(path, explicit)
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
      return
    end
    local candidate = { path = root, explicit = explicit or false }
    seen[key] = candidate
    candidates[#candidates + 1] = candidate
  end

  local function add_search_path(path)
    if type(path) ~= "string" or not directory(path) then
      return
    end
    add(path, false)

    local children = {}
    local scanner = vim.uv.fs_scandir(path)
    if not scanner then
      return
    end
    while true do
      local name, kind = vim.uv.fs_scandir_next(scanner)
      if not name then
        break
      end
      if kind == "directory" or kind == "link" then
        children[#children + 1] = vim.fs.joinpath(path, name)
      end
    end
    table.sort(children, function(left, right)
      local left_matches = vim.fs.basename(left):lower()
        == info.repo:lower()
      local right_matches = vim.fs.basename(right):lower()
        == info.repo:lower()
      if left_matches ~= right_matches then
        return left_matches
      end
      return left:lower() < right:lower()
    end)
    for _, child in ipairs(children) do
      local marker = vim.fs.joinpath(child, ".git")
      if vim.uv.fs_stat(marker) then
        add(child, false)
      end
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
      inspect_next()
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

local function update_session_buffer(win, buf)
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
  local state = vim.b[buf].pantheon_inspect
  if type(state) ~= "table"
    or type(state.source_path) ~= "string"
    or state.source_path == ""
  then
    return
  end
  for _, other in ipairs(vim.api.nvim_list_bufs()) do
    if other ~= buf
      and vim.api.nvim_buf_is_valid(other)
      and type(vim.b[other].pantheon_inspect) == "table"
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
  "PantheonInspectSync",
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
  local root = role == "parent"
      and session.parent_repository
    or session.change_repository
  local relative = relative_path(root, directory)
  if relative ~= nil then
    return session, role, relative
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
  A = { sign = "+", highlight = "PantheonOilAdded" },
  C = { sign = "+", highlight = "PantheonOilAdded" },
  D = { sign = "-", highlight = "PantheonOilDeleted" },
  M = { sign = "~", highlight = "PantheonOilModified" },
  R = { sign = "→", highlight = "PantheonOilRenamed" },
  T = { sign = "~", highlight = "PantheonOilModified" },
  directory = {
    sign = "•",
    highlight = "PantheonOilDirectory",
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
  vim.api.nvim_set_hl(0, "PantheonOilAdded", {
    fg = highlight_foreground("DiagnosticOk", 0x9ae6b4),
    bg = background,
  })
  vim.api.nvim_set_hl(0, "PantheonOilDeleted", {
    fg = highlight_foreground("DiagnosticError", 0xf87171),
    bg = background,
  })
  vim.api.nvim_set_hl(0, "PantheonOilModified", {
    fg = highlight_foreground("DiagnosticWarn", 0xfbd38d),
    bg = background,
  })
  vim.api.nvim_set_hl(0, "PantheonOilRenamed", {
    fg = highlight_foreground("DiagnosticInfo", 0x7dd3fc),
    bg = background,
  })
  vim.api.nvim_set_hl(0, "PantheonOilDirectory", {
    fg = highlight_foreground("DiagnosticInfo", 0x7dd3fc),
    bg = background,
  })
end

set_oil_highlights()

local oil_group = vim.api.nvim_create_augroup(
  "PantheonInspectOil",
  { clear = true }
)

vim.api.nvim_create_autocmd("ColorScheme", {
  group = oil_group,
  callback = set_oil_highlights,
})

local function queue_oil_decorations(buf)
  vim.schedule(function()
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

local function apply_change_signs(parent_buf, change_buf, hunks)
  vim.api.nvim_set_hl(0, "PantheonInspectRemoved", {
    link = "DiffDelete",
    default = true,
  })
  vim.api.nvim_set_hl(0, "PantheonInspectAdded", {
    link = "DiffAdd",
    default = true,
  })
  vim.api.nvim_buf_clear_namespace(parent_buf, change_ns, 0, -1)
  vim.api.nvim_buf_clear_namespace(change_buf, change_ns, 0, -1)

  for _, hunk in ipairs(hunks or {}) do
    place_range(
      change_buf,
      hunk.new_start,
      hunk.new_count,
      hunk.new_count == 0 and "-" or "+",
      hunk.new_count == 0
          and "PantheonInspectRemoved"
        or "PantheonInspectAdded"
    )
  end
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

local function jump_change(session, group, role, direction)
  local win = vim.api.nvim_get_current_win()
  local cursor = vim.api.nvim_win_get_cursor(win)
  local count = #(session.hunks or {})
  if count == 0 then
    return
  end
  local current = hunk_index_at_line(
    session,
    role,
    cursor[1]
  ) or session.active_chunk
  local target
  if current then
    target = ((current + direction - 1) % count) + 1
  else
    local lines = role == "parent"
        and session.parent_lines
      or session.change_lines
    local line = next_change_line(lines, cursor[1], direction)
    for index, hunk in ipairs(session.hunks) do
      if hunk_start(hunk, role) == line then
        target = index
        break
      end
    end
  end
  target = target or 1
  session.active_chunk = target
  set_change_cursor(win, hunk_start(session.hunks[target], role))
  refresh_sidebar(group, vim.api.nvim_get_current_tabpage())
end

local function map_change_jumps(endpoint, session, group, role)
  local function map(lhs, direction, description)
    vim.keymap.set("n", lhs, function()
      jump_change(session, group, role, direction)
    end, {
      buffer = endpoint.buf,
      nowait = true,
      silent = true,
      desc = description,
    })
  end
  map("<C-Left>", -1, "Previous Pantheon change")
  map("<C-Right>", 1, "Next Pantheon change")
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

local function map_file_navigation(endpoint, session, role)
  local function toggle_version()
    select_endpoint(
      role == "parent" and session.change or session.parent
    )
  end
  vim.keymap.set("n", "<C-s>", toggle_version, {
    buffer = endpoint.buf,
    nowait = true,
    silent = true,
    desc = "Switch Pantheon file version",
  })
end

local function sidebar_active_item(group, tab)
  for index, session in ipairs(group) do
    if session.parent.tab == tab then
      return index, "parent"
    end
    if session.change.tab == tab then
      return index, "change"
    end
  end
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
  return normalized:match("([^/]+)$") or normalized
end

local function sidebar_row(file, width)
  local prefix = "• "
  local suffix = "P C"
  local path_width = math.max(
    1,
    width
      - vim.fn.strdisplaywidth(prefix)
      - vim.fn.strdisplaywidth(suffix)
      - 1
  )
  local path = truncate_path(file, path_width)
  local body = prefix .. path
  local padding = math.max(
    1,
    width
      - vim.fn.strdisplaywidth(body)
      - vim.fn.strdisplaywidth(suffix)
  )
  local line = body .. string.rep(" ", padding) .. suffix
  return {
    line = line,
    parent_column = #line - 3,
    change_column = #line - 1,
  }
end

local function sidebar_chunk_row(hunk, last)
  local branch = last and "└─" or "├─"
  local first = hunk.new_start
  local last_line = first + math.max(0, (hunk.new_count or 0) - 1)
  return ("  %s %d-%d"):format(
    branch,
    first,
    last_line
  )
end

local function sidebar_chunk(session, role)
  local endpoint = role == "parent"
      and session.parent
    or session.change
  if not valid_endpoint(endpoint) then
    return
  end
  local line = vim.api.nvim_win_get_cursor(endpoint.win)[1]
  local index = hunk_index_at_line(session, role, line)
  if index then
    session.active_chunk = index
  end
  return index or session.active_chunk
end

refresh_sidebar = function(group, tab)
  local buf = group.sidebar_buf
  if not buf or not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  local active_index, active_role = sidebar_active_item(group, tab)
  if not active_index then
    return
  end
  local normal_hl =
    vim.api.nvim_get_hl(0, { name = "Normal", link = false })
  local parent_hl =
    vim.api.nvim_get_hl(0, { name = "DiagnosticError", link = false })
  vim.api.nvim_set_hl(0, "PantheonInspectSidebarParent", {
    fg = parent_hl.fg or 0xe06c75,
    bg = normal_hl.bg,
    default = true,
  })
  vim.api.nvim_set_hl(0, "PantheonInspectSidebarParentActive", {
    fg = parent_hl.fg or 0xe06c75,
    bg = normal_hl.bg,
    underline = true,
    default = true,
  })
  vim.api.nvim_set_hl(0, "PantheonInspectSidebarChange", {
    fg = 0x00c853,
    bg = normal_hl.bg,
    default = true,
  })
  vim.api.nvim_set_hl(0, "PantheonInspectSidebarChangeActive", {
    fg = 0x00c853,
    bg = normal_hl.bg,
    underline = true,
    default = true,
  })
  local active_chunk = sidebar_chunk(group[active_index], active_role)
  vim.api.nvim_buf_clear_namespace(buf, sidebar_ns, 0, -1)
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
            and "PantheonInspectSidebarParentActive"
          or "PantheonInspectSidebarParent",
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
            and "PantheonInspectSidebarChangeActive"
          or "PantheonInspectSidebarChange",
        priority = 100,
      }
    )
  end
  vim.b[buf].pantheon_inspect_sidebar_active = {
    pair_index = active_index,
    role = active_role,
    chunk_index = active_chunk,
    chunk_count = #(group[active_index].hunks or {}),
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
  vim.wo[win].cursorline = false
  group.sidebar_windows[endpoint.tab] = win
  vim.api.nvim_set_current_win(endpoint.win)
end

local function endpoint_for_tab(group, tab)
  local index, role = sidebar_active_item(group, tab)
  local session = index and group[index] or nil
  return session and role and session[role] or nil
end

local function close_inspection_sidebar(group)
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

local function open_inspection_sidebar(group)
  local origin_tab = vim.api.nvim_get_current_tabpage()
  local origin_win = vim.api.nvim_get_current_win()
  group.sidebar_windows = {}
  group.sidebar_visible = true
  sidebar_navigating = true
  for _, session in ipairs(group) do
    create_sidebar_window(group, session.parent)
    create_sidebar_window(group, session.change)
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

local function map_inspection_sidebar_toggle(group)
  local opts = {
    nowait = true,
    silent = true,
    desc = "Toggle Pantheon Inspect sidebar",
  }
  local function map_buffer(buf)
    for _, lhs in ipairs({ "<C-i>", "<Tab>" }) do
      vim.keymap.set("n", lhs, function()
        toggle_inspection_sidebar(group)
      end, vim.tbl_extend("force", opts, {
        buffer = buf,
      }))
    end
  end
  for _, session in ipairs(group) do
    for _, endpoint in ipairs({ session.parent, session.change }) do
      if valid_endpoint(endpoint) then
        map_buffer(endpoint.buf)
      end
    end
  end
  map_buffer(group.sidebar_buf)
  vim.keymap.set("n", "<CR>", function()
    focus_sidebar_selection(group)
  end, {
    buffer = group.sidebar_buf,
    nowait = true,
    silent = true,
    desc = "Open Pantheon Inspect sidebar item",
  })
  vim.keymap.set("n", "<C-s>", function()
    switch_sidebar_version(group)
  end, {
    buffer = group.sidebar_buf,
    nowait = true,
    silent = true,
    desc = "Switch Pantheon file version",
  })
end

local function setup_inspection_sidebar(group)
  local buf = vim.api.nvim_create_buf(false, true)
  group.sidebar_buf = buf
  group.sidebar_windows = {}
  group.sidebar_visible = false
  group.sidebar_width =
    math.min(28, math.max(20, vim.o.columns - 20))
  group.sidebar_rows = {}
  group.sidebar_chunk_lines = {}
  group.sidebar_entries = {}
  group.sidebar_lines = {}
  local lines = {}
  for index, session in ipairs(group) do
    session.file = session.file or ("file " .. index)
    local total = #(session.hunks or {})
    local row = sidebar_row(
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
    for chunk_index, hunk in ipairs(session.hunks or {}) do
      local chunk_line = #lines + 1
      group.sidebar_chunk_lines[index][chunk_index] = chunk_line
      group.sidebar_entries[chunk_line] = {
        pair_index = index,
        chunk_index = chunk_index,
      }
      lines[chunk_line] = sidebar_chunk_row(
        hunk,
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
  vim.bo[buf].filetype = "pantheon-inspect-files"
  map_inspection_sidebar_toggle(group)
  sidebar_groups[#sidebar_groups + 1] = group
  local first = group[1] and group[1].parent or nil
  if valid_endpoint(first) then
    vim.api.nvim_set_current_win(first.win)
    show_inspection_path(first.buf)
    open_inspection_sidebar(group)
  end
end

local function sidebar_group_for_buffer(buf)
  for _, group in ipairs(sidebar_groups) do
    if group.sidebar_buf == buf then
      return group
    end
  end
end

local function open_sidebar_selection(group)
  if sidebar_navigating then
    return
  end
  local tab = vim.api.nvim_get_current_tabpage()
  local _, role = sidebar_active_item(group, tab)
  local line = vim.api.nvim_win_get_cursor(0)[1]
  local entry = group.sidebar_entries[line]
  local session = entry and group[entry.pair_index] or nil
  local endpoint = session and role and session[role] or nil
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
  if entry.chunk_index then
    session.active_chunk = entry.chunk_index
    set_change_cursor(
      endpoint.win,
      hunk_start(session.hunks[entry.chunk_index], role)
    )
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

focus_sidebar_selection = function(group)
  if
    sidebar_navigating
    or vim.api.nvim_get_current_buf() ~= group.sidebar_buf
  then
    return
  end
  local tab = vim.api.nvim_get_current_tabpage()
  local _, role = sidebar_active_item(group, tab)
  local line = vim.api.nvim_win_get_cursor(0)[1]
  local entry = group.sidebar_entries[line]
  local session = entry and group[entry.pair_index] or nil
  local endpoint = session and role and session[role] or nil
  if not valid_endpoint(endpoint) then
    return
  end

  local chunk_index = entry.chunk_index or 1
  local hunk = session.hunks and session.hunks[chunk_index] or nil
  sidebar_navigating = true
  group.sidebar_focus_generation =
    (group.sidebar_focus_generation or 0) + 1
  group.focused_win = nil
  vim.api.nvim_set_current_win(endpoint.win)
  if hunk then
    session.active_chunk = chunk_index
    set_change_cursor(endpoint.win, hunk_start(hunk, role))
  end
  show_inspection_path(endpoint.buf)
  refresh_sidebar(group, endpoint.tab)
  sidebar_navigating = false
end

switch_sidebar_version = function(group)
  if
    sidebar_navigating
    or vim.api.nvim_get_current_buf() ~= group.sidebar_buf
  then
    return
  end
  local tab = vim.api.nvim_get_current_tabpage()
  local _, role = sidebar_active_item(group, tab)
  local line = vim.api.nvim_win_get_cursor(0)[1]
  local entry = group.sidebar_entries[line]
  local session = entry and group[entry.pair_index] or nil
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

local function update_loading_buffer(endpoint, frame)
  if not vim.api.nvim_buf_is_valid(endpoint.buf) then
    return
  end
  vim.bo[endpoint.buf].modifiable = true
  vim.api.nvim_buf_set_lines(endpoint.buf, 0, -1, false, {
    "",
    ("  %s  Loading %s…"):format(frame, endpoint.description),
    "",
    "  Preparing repository and revisions",
  })
  vim.bo[endpoint.buf].modifiable = false
  vim.api.nvim_buf_clear_namespace(endpoint.buf, loading_ns, 0, -1)
  vim.api.nvim_buf_add_highlight(
    endpoint.buf,
    loading_ns,
    "DiagnosticInfo",
    1,
    0,
    -1
  )
end

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

local function make_loading_tab(role, description)
  vim.cmd("tabnew")
  local endpoint = {
    role = role,
    description = description,
    tab = vim.api.nvim_get_current_tabpage(),
    win = vim.api.nvim_get_current_win(),
    buf = vim.api.nvim_get_current_buf(),
  }
  vim.bo[endpoint.buf].buftype = "nofile"
  vim.bo[endpoint.buf].bufhidden = "wipe"
  vim.bo[endpoint.buf].swapfile = false
  vim.t.pantheon_inspect = {
    role = role,
    loading = true,
  }
  update_loading_buffer(endpoint, spinner_frames[1])
  return endpoint
end

local function loading_endpoints(loading)
  local endpoints = {}
  for _, pair in ipairs(loading.pairs or {}) do
    endpoints[#endpoints + 1] = pair.parent
    endpoints[#endpoints + 1] = pair.change
  end
  return endpoints
end

local function loading_pair_labels(info, inspection, index)
  local commit_index = inspection and inspection.commit_index or index
  local file_index = inspection and inspection.file_index or 1
  local file = inspection
      and (inspection.change_file or inspection.parent_file)
    or nil
  local prefix = info.kind == "pull_request"
      and ("Commit %d File %d"):format(commit_index, file_index)
    or ("File %d"):format(file_index)
  local suffix = file and (" (" .. file .. ")") or ""
  return {
    parent_description = prefix:lower() .. " old version" .. suffix,
    change_description = prefix:lower() .. " new version" .. suffix,
  }
end

local function configure_loading_pair(loading, info, pair, inspection, index)
  local labels = loading_pair_labels(info, inspection, index)
  pair.parent.description = labels.parent_description
  pair.change.description = labels.change_description
  for _, endpoint in ipairs({ pair.parent, pair.change }) do
    if vim.api.nvim_tabpage_is_valid(endpoint.tab) then
      vim.api.nvim_tabpage_set_var(endpoint.tab, "pantheon_inspect", {
        role = endpoint.role,
        loading = true,
        pair_index = index,
        commit_index = inspection and inspection.commit_index or nil,
        file_index = inspection and inspection.file_index or nil,
        file = inspection
            and (inspection.change_file or inspection.parent_file)
          or nil,
      })
    end
    update_loading_buffer(
      endpoint,
      spinner_frames[loading.frame] or spinner_frames[1]
    )
  end
end

local function add_loading_pair(loading, info, index, inspection)
  local pair = {
    parent = make_loading_tab(
      info.kind == "pull_request" and "old" or "parent",
      "old file version"
    ),
    change = make_loading_tab(
      "change",
      "new file version"
    ),
  }
  loading.pairs[#loading.pairs + 1] = pair
  configure_loading_pair(loading, info, pair, inspection, index)
  loading.parent = loading.pairs[1].parent
  loading.change = loading.pairs[1].change
end

local function sync_loading_tabs(loading, info, inspections)
  for index, inspection in ipairs(inspections) do
    if not loading.pairs[index] then
      add_loading_pair(loading, info, index, inspection)
    else
      configure_loading_pair(
        loading,
        info,
        loading.pairs[index],
        inspection,
        index
      )
    end
  end
end

local function start_loading_tabs(info)
  require("pantheon.window").close()
  local loading = {
    frame = 1,
    stopped = false,
    pairs = {},
  }
  add_loading_pair(loading, info, 1)

  loading.timer = vim.uv.new_timer()
  loading.timer:start(120, 120, vim.schedule_wrap(function()
    if loading.stopped then
      return
    end
    local endpoints = loading_endpoints(loading)
    local valid = false
    for _, endpoint in ipairs(endpoints) do
      valid = valid or vim.api.nvim_buf_is_valid(endpoint.buf)
    end
    if not valid then
      stop_loading(loading)
      return
    end
    loading.frame = (loading.frame % #spinner_frames) + 1
    local frame = spinner_frames[loading.frame]
    for _, endpoint in ipairs(endpoints) do
      update_loading_buffer(endpoint, frame)
    end
    vim.cmd.redrawtabline()
  end))
  return loading
end

local function show_loading_error(loading, message)
  stop_loading(loading)
  for _, endpoint in ipairs(loading_endpoints(loading)) do
    if vim.api.nvim_buf_is_valid(endpoint.buf) then
      vim.bo[endpoint.buf].modifiable = true
      local error_lines = {
        "",
        "  Inspection failed",
        "",
      }
      for _, line in ipairs(vim.split(
        tostring(message),
        "\n",
        { plain = true }
      )) do
        error_lines[#error_lines + 1] = "  " .. line:gsub("\r$", "")
      end
      vim.api.nvim_buf_set_lines(
        endpoint.buf,
        0,
        -1,
        false,
        error_lines
      )
      vim.bo[endpoint.buf].modifiable = false
      vim.api.nvim_buf_clear_namespace(endpoint.buf, loading_ns, 0, -1)
      vim.api.nvim_buf_add_highlight(
        endpoint.buf,
        loading_ns,
        "DiagnosticError",
        1,
        0,
        -1
      )
      if vim.api.nvim_tabpage_is_valid(endpoint.tab) then
        vim.api.nvim_tabpage_set_var(endpoint.tab, "pantheon_inspect", {
          role = endpoint.role,
          loading = false,
          error = message,
        })
      end
    end
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
    error("a loading tab was closed before inspection completed")
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
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.bo[buf].modifiable = false
  vim.bo[buf].readonly = true
  vim.b[buf].pantheon_inspect_repository = path
  vim.b[buf].pantheon_inspect_directory = working_directory
  vim.b[buf].pantheon_inspect_source_path =
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
  vim.t.pantheon_inspect = state
  vim.b[buf].pantheon_inspect = vim.deepcopy(state)
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

local function open_tabs(inspections, loading, done)
  stop_loading(loading)
  local ok, err = pcall(function()
    if #loading.pairs ~= #inspections then
      error("loading tab count does not match inspection file count")
    end
    local inspection_sessions = {}
    for index, paths in ipairs(inspections) do
      local loading_pair = loading.pairs[index]
      local parent = load_tab(
        loading_pair.parent,
        paths.repository,
        paths.parent_file,
        paths.parent_role or "parent",
        paths,
        index
      )
      local change = load_tab(
        loading_pair.change,
        paths.repository,
        paths.change_file,
        "change",
        paths,
        index
      )
      next_session = next_session + 1
      local session = {
        parent = parent,
        change = change,
        file = paths.change_file or paths.parent_file,
        parent_repository = paths.repository,
        change_repository = paths.repository,
        changes = paths.changes,
        hunks = paths.hunks,
        parent_lines = change_lines(paths.hunks, "parent"),
        change_lines = change_lines(paths.hunks),
        active_chunk = paths.hunks[1] and 1 or nil,
      }
      inspection_sessions[#inspection_sessions + 1] = session
      sessions[next_session] = session
      apply_change_signs(parent.buf, change.buf, paths.hunks)
      map_change_jumps(
        parent,
        session,
        inspection_sessions,
        "parent"
      )
      map_change_jumps(
        change,
        session,
        inspection_sessions,
        "change"
      )
      map_file_navigation(
        parent,
        session,
        "parent"
      )
      map_file_navigation(
        change,
        session,
        "change"
      )
      if session.parent_lines[1] then
        set_change_cursor(parent.win, session.parent_lines[1])
      else
        sync_window(parent.win)
      end
    end
    setup_inspection_sidebar(inspection_sessions)
    for _, session in ipairs(inspection_sessions) do
      normalize_inspection_view(session.parent.win)
      normalize_inspection_view(session.change.win)
    end
  end)
  if not ok then
    done(nil, "could not open inspection tabs: " .. tostring(err))
    return
  end
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

local function prepare(info, opts, on_pairs, callback)
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
              callback(nil, "the inspected revisions do not change any files")
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
              on_pairs(inspections)
              index = index + 1
              prepare_next()
            end
          )
        end
        prepare_next()
      end)
    end)
  end)
end

local function apply_pull_request(info, details)
  local resolved = vim.deepcopy(info)
  resolved.base_sha = details.base_sha
  resolved.base_ref = details.base_ref
  resolved.head_sha = details.head_sha
  resolved.head_ref = details.head_ref
  resolved.fetch_ref = details.fetch_ref
  resolved.commit_count = details.commit_count
  resolved.title = details.title
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

function M.open(url, opts)
  opts = opts or {}
  local info = parse_target_url(url)
  if not info then
    return nil,
      "inspect currently supports GitHub and Codeberg commit "
        .. "and pull request activity"
  end
  if vim.fn.executable("git") ~= 1 then
    return nil, "inspect requires git"
  end
  if active then
    return nil, "an inspection is already being prepared"
  end

  active = true
  local loading_ok, loading = pcall(start_loading_tabs, info)
  if not loading_ok then
    active = false
    return nil, "could not open inspection loading tabs: "
      .. tostring(loading)
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
      function(inspections)
        sync_loading_tabs(loading, resolved, inspections)
      end,
      function(inspections, err)
        if err then
          active = false
          show_loading_error(loading, err)
          return
        end
        open_tabs(inspections, loading, function(_, open_err)
          active = false
          if open_err then
            show_loading_error(loading, open_err)
            return
          end
        end)
      end
    )
  end)
  return true
end

M._parse_commit_url = parse_commit_url
M._parse_pull_request_url = parse_pull_request_url
M._parse_target_url = parse_target_url
M._apply_pull_request = apply_pull_request
M._first_changed_paths = first_changed_paths
M._parse_changed_files = parse_changed_files
M._inspection_directory = inspection_directory
M._github_repository = github_repository
M._forge_repository = forge_repository
M._download_destination = download_destination
M._offer_repository_download = offer_repository_download
M._parse_hunks = parse_hunks
M._parse_revision_pairs = parse_revision_pairs
M._blob_lines = blob_lines
M._oil_entry_status = oil_entry_status
M._change_lines = change_lines
M._next_change_line = next_change_line
M._normalize_inspection_view = normalize_inspection_view
M._sidebar_row = sidebar_row
M._sidebar_chunk_row = sidebar_chunk_row
M._sidebar_file = sidebar_file

return M
