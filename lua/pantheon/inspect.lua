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

local function change_lines(hunks)
  local lines = {}
  local seen = {}
  for _, hunk in ipairs(hunks or {}) do
    local line = math.max(1, hunk.new_start)
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
      parent_buf,
      hunk.old_start,
      hunk.old_count,
      hunk.old_count == 0 and "+" or "-",
      hunk.old_count == 0
          and "PantheonInspectAdded"
        or "PantheonInspectRemoved"
    )
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
  vim.api.nvim_win_call(win, function()
    vim.cmd("normal! zz")
  end)
  sync_window(win)
end

local function normalize_inspection_view(win)
  if not vim.api.nvim_win_is_valid(win) then
    return
  end
  vim.api.nvim_win_call(win, function()
    local cursor_line = vim.api.nvim_win_get_cursor(win)[1]
    local keys = vim.api.nvim_replace_termcodes(
      "zt10<C-y>$",
      true,
      false,
      true
    )
    vim.cmd("normal! " .. keys)
    local view = vim.fn.winsaveview()
    view.topline = math.max(1, cursor_line - 10)
    vim.fn.winrestview(view)
  end)
end

local function jump_change(session, direction)
  local win = vim.api.nvim_get_current_win()
  local cursor = vim.api.nvim_win_get_cursor(win)
  local line = next_change_line(
    session.change_lines,
    cursor[1],
    direction
  )
  if line then
    set_change_cursor(win, line)
  end
end

local function map_change_jumps(endpoint, session)
  local function map(lhs, direction, description)
    vim.keymap.set("n", lhs, function()
      jump_change(session, direction)
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
  vim.api.nvim_set_current_tabpage(endpoint.tab)
  vim.api.nvim_set_current_win(endpoint.win)
  show_inspection_path(endpoint.buf)
end

local function next_file_session(group, current)
  local current_index
  for index, session in ipairs(group) do
    if session == current then
      current_index = index
      break
    end
  end
  if not current_index then
    return
  end
  for offset = 1, #group do
    local index = ((current_index + offset - 1) % #group) + 1
    local candidate = group[index]
    if valid_endpoint(candidate.parent)
      and valid_endpoint(candidate.change)
    then
      return candidate
    end
  end
end

local function map_file_navigation(endpoint, session, group, role)
  local function toggle_version()
    select_endpoint(
      role == "parent" and session.change or session.parent
    )
  end
  vim.keymap.set("n", "<Tab>", toggle_version, {
    buffer = endpoint.buf,
    nowait = true,
    silent = true,
    desc = "Toggle Pantheon file version",
  })
  vim.keymap.set("n", "<C-s>", toggle_version, {
    buffer = endpoint.buf,
    nowait = true,
    silent = true,
    desc = "Switch Pantheon file version",
  })
  vim.keymap.set("n", "<C-n>", function()
    local target = next_file_session(group, session)
    if target then
      select_endpoint(target[role])
    end
  end, {
    buffer = endpoint.buf,
    nowait = true,
    silent = true,
    desc = "Next Pantheon changed file",
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

local function refresh_sidebar(group, tab)
  local buf = group.sidebar_buf
  if not buf or not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  local active_index, active_role = sidebar_active_item(group, tab)
  if not active_index then
    return
  end
  vim.api.nvim_set_hl(0, "PantheonInspectSidebarCurrent", {
    link = "CursorLine",
    default = true,
  })
  vim.api.nvim_set_hl(0, "PantheonInspectSidebarRoleActive", {
    link = "Search",
    default = true,
  })
  vim.api.nvim_set_hl(0, "PantheonInspectSidebarRoleInactive", {
    link = "Comment",
    default = true,
  })
  vim.api.nvim_buf_clear_namespace(buf, sidebar_ns, 0, -1)
  for index, session in ipairs(group) do
    local file = session.file
    local change_column = #file + 2
    local parent_column = #file + 4
    if index == active_index then
      vim.api.nvim_buf_set_extmark(buf, sidebar_ns, index - 1, 0, {
        line_hl_group = "PantheonInspectSidebarCurrent",
        hl_eol = true,
      })
    end
    vim.api.nvim_buf_set_extmark(
      buf,
      sidebar_ns,
      index - 1,
      change_column,
      {
        end_col = change_column + 1,
        hl_group = index == active_index
            and active_role == "change"
            and "PantheonInspectSidebarRoleActive"
          or "PantheonInspectSidebarRoleInactive",
        priority = 100,
      }
    )
    vim.api.nvim_buf_set_extmark(
      buf,
      sidebar_ns,
      index - 1,
      parent_column,
      {
        end_col = parent_column + 1,
        hl_group = index == active_index
            and active_role == "parent"
            and "PantheonInspectSidebarRoleActive"
          or "PantheonInspectSidebarRoleInactive",
        priority = 100,
      }
    )
  end
  vim.b[buf].pantheon_inspect_sidebar_active = {
    pair_index = active_index,
    role = active_role,
  }
  local sidebar_win = group.sidebar_windows[tab]
  if sidebar_win and vim.api.nvim_win_is_valid(sidebar_win) then
    vim.api.nvim_win_set_cursor(sidebar_win, { active_index, 0 })
  end
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
  local width = math.min(48, math.max(24, math.floor(vim.o.columns * 0.24)))
  vim.api.nvim_win_set_width(win, width)
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

local function setup_inspection_sidebar(group)
  local active_tab = vim.api.nvim_get_current_tabpage()
  local active_win = vim.api.nvim_get_current_win()
  local buf = vim.api.nvim_create_buf(false, true)
  group.sidebar_buf = buf
  group.sidebar_windows = {}
  local lines = {}
  for index, session in ipairs(group) do
    session.file = session.file or ("file " .. index)
    lines[index] = session.file .. "  C P"
  end
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "hide"
  vim.bo[buf].swapfile = false
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].filetype = "pantheon-inspect-files"
  for _, session in ipairs(group) do
    create_sidebar_window(group, session.parent)
    create_sidebar_window(group, session.change)
  end
  sidebar_groups[#sidebar_groups + 1] = group
  if vim.api.nvim_tabpage_is_valid(active_tab) then
    vim.api.nvim_set_current_tabpage(active_tab)
    if vim.api.nvim_win_is_valid(active_win) then
      vim.api.nvim_set_current_win(active_win)
    end
    refresh_sidebar(group, active_tab)
  end
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
  vim.wo[loaded.win].signcolumn = "yes:2"
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
        change_lines = change_lines(paths.hunks),
      }
      inspection_sessions[#inspection_sessions + 1] = session
      sessions[next_session] = session
      apply_change_signs(parent.buf, change.buf, paths.hunks)
      map_change_jumps(parent, session)
      map_change_jumps(change, session)
      map_file_navigation(
        parent,
        session,
        inspection_sessions,
        "parent"
      )
      map_file_navigation(
        change,
        session,
        inspection_sessions,
        "change"
      )
      if session.change_lines[1] then
        set_change_cursor(change.win, session.change_lines[1])
      else
        sync_window(change.win)
      end
      normalize_inspection_view(parent.win)
      normalize_inspection_view(change.win)
    end
    setup_inspection_sidebar(inspection_sessions)
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

return M
