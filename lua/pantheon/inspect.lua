local M = {}

local github = require("pantheon.github")

local active = false
local change_ns = vim.api.nvim_create_namespace("pantheon_inspect_changes")
local loading_ns = vim.api.nvim_create_namespace("pantheon_inspect_loading")
local oil_ns = vim.api.nvim_create_namespace("pantheon_inspect_oil")
local sessions = {}
local next_session = 0
local next_loading = 0
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

local function parse_commit_url(url)
  if type(url) ~= "string" then
    return nil
  end

  local owner, repo, sha, suffix = url:match(
    "^https?://github%.com/([^/]+)/([^/]+)/commit/([0-9a-fA-F]+)(.*)$"
  )
  if not owner or not repo or not sha then
    return nil
  end

  repo = repo:gsub("%.git$", "")
  if
    not owner:match("^[%w][%w-]*$")
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
    owner = owner,
    repo = repo,
    sha = sha:lower(),
    remote_url = ("https://github.com/%s/%s.git"):format(owner, repo),
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
  if not owner then
    owner, repo, number, suffix = url:match(
      "^https?://github%.com/([^/]+)/([^/]+)/issues/(%d+)(.*)$"
    )
    section = "issues"
  end
  if
    not owner
    or not repo
    or not number
    or not owner:match("^[%w][%w-]*$")
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
    via_issue = section == "issues",
    owner = owner,
    repo = repo,
    number = tonumber(number),
    remote_url = ("https://github.com/%s/%s.git"):format(owner, repo),
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

local function directory(path)
  local stat = vim.uv.fs_stat(path)
  return stat and stat.type == "directory"
end

local function github_repository(url)
  if type(url) ~= "string" then
    return nil
  end
  local owner, repo = url:match("^https?://github%.com/([^/]+)/([^/]+)")
  if not owner then
    owner, repo = url:match("^git@github%.com:([^/]+)/([^/]+)")
  end
  if not owner then
    owner, repo = url:match(
      "^ssh://git@github%.com/([^/]+)/([^/]+)"
    )
  end
  if not owner or not repo then
    return nil
  end
  repo = repo:gsub("[/?#].*$", ""):gsub("%.git$", "")
  return (owner .. "/" .. repo):lower()
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

  local function inspect_next()
    local candidate = candidates[index]
    index = index + 1
    if not candidate then
      callback()
      return
    end

    if candidate.explicit then
      callback(candidate.path)
      return
    end

    run({ "git", "-C", candidate.path, "remote", "-v" }, function(remotes)
      for line in (remotes or ""):gmatch("[^\r\n]+") do
        local url = line:match("^%S+%s+(%S+)%s+%(fetch%)$")
        if github_repository(url) == slug then
          callback(candidate.path)
          return
        end
      end
      inspect_next()
    end)
  end

  inspect_next()
end

local function clone_mirror(source, info, mirror, callback)
  local command
  if source then
    command = {
      "git",
      "clone",
      "--bare",
      "--local",
      source,
      mirror,
    }
  else
    command = {
      "git",
      "clone",
      "--filter=blob:none",
      "--bare",
      info.remote_url,
      mirror,
    }
  end

  run(command, function(_, err)
    if err then
      local origin = source and ("local clone at " .. source)
        or (info.owner .. "/" .. info.repo)
      callback(nil, "could not clone " .. origin .. ": " .. err)
      return
    end
    if not source then
      callback(mirror)
      return
    end
    run({
      "git",
      "--git-dir",
      mirror,
      "remote",
      "set-url",
      "origin",
      info.remote_url,
    }, function(_, remote_err)
      if remote_err then
        callback(nil, "could not configure inspection remote: " .. remote_err)
        return
      end
      callback(mirror)
    end)
  end)
end

local function ensure_mirror(info, root, opts, callback)
  local mirror = vim.fs.joinpath(
    root,
    "repositories",
    info.owner,
    info.repo .. ".git"
  )
  find_local_repository(info, opts, function(source)
    if not source and not opts.inspect_allow_remote_clone then
      local search_root = (opts.inspect_search_paths or {})[1]
      local location = search_root
          and (" under " .. search_root)
        or ""
      callback(
        nil,
        ("no local clone of %s/%s was found%s; remote cloning is disabled")
          :format(info.owner, info.repo, location)
      )
      return
    end

    if source then
      vim.notify(
        "Pantheon: using local clone at " .. source,
        vim.log.levels.INFO
      )
    end
    if directory(mirror) then
      callback(mirror)
      return
    end
    if vim.uv.fs_stat(mirror) then
      callback(nil, "the inspection repository cache is not a directory")
      return
    end

    vim.fn.mkdir(vim.fs.dirname(mirror), "p")
    clone_mirror(source, info, mirror, callback)
  end)
end

local function resolve_revision(mirror, revision, callback)
  run({
    "git",
    "--git-dir",
    mirror,
    "rev-parse",
    revision .. "^{commit}",
  }, callback)
end

local function resolve_pair(mirror, info, callback)
  if info.kind == "pull_request" then
    resolve_revision(mirror, info.base_sha, function(base, base_err)
      if base_err then
        callback(nil, base_err)
        return
      end
      resolve_revision(mirror, info.head_sha, function(head, head_err)
        if head_err then
          callback(nil, head_err)
          return
        end
        callback({ commit = head, parent = base })
      end)
    end)
    return
  end

  resolve_revision(mirror, info.sha, function(commit, resolve_err)
    if resolve_err then
      callback(nil, resolve_err)
      return
    end
    run({
      "git",
      "--git-dir",
      mirror,
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

local function fetch_pair(mirror, info, callback)
  resolve_pair(mirror, info, function(commits)
    if commits then
      callback(commits)
      return
    end

    local command = {
      "git",
      "--git-dir",
      mirror,
      "fetch",
      "--filter=blob:none",
      "origin",
    }
    if info.kind == "pull_request" then
      command[#command + 1] = info.base_sha
      command[#command + 1] =
        ("refs/pull/%d/head"):format(info.number)
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
      resolve_pair(mirror, info, function(resolved, resolve_err)
        if resolve_err then
          callback(nil, "could not resolve commit: " .. resolve_err)
          return
        end
        callback(resolved)
      end)
    end)
  end)
end

local function ensure_worktree(mirror, path, commit, callback)
  if directory(path) then
    run({ "git", "-C", path, "rev-parse", "HEAD" }, function(head, err)
      if err or head ~= commit then
        callback(nil, "the cached worktree at " .. path
          .. " is not at the expected commit")
        return
      end
      callback(path)
    end)
    return
  end
  if vim.uv.fs_stat(path) then
    callback(nil, "the worktree path is not a directory: " .. path)
    return
  end

  vim.fn.mkdir(vim.fs.dirname(path), "p")
  run({
    "git",
    "--git-dir",
    mirror,
    "worktree",
    "add",
    "--detach",
    path,
    commit,
  }, function(_, err)
    if err then
      callback(nil, "could not create worktree: " .. err)
      return
    end
    callback(path)
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

local function session_for_directory(directory)
  for _, session in pairs(sessions) do
    local parent_relative = relative_path(
      session.parent_worktree,
      directory
    )
    if parent_relative ~= nil then
      return session, "parent", parent_relative
    end
    local change_relative = relative_path(
      session.change_worktree,
      directory
    )
    if change_relative ~= nil then
      return session, "change", change_relative
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
  local session, role, relative = session_for_directory(directory)
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

local function set_oil_highlights()
  vim.api.nvim_set_hl(0, "PantheonOilAdded", {
    fg = highlight_foreground("DiagnosticOk", 0x9ae6b4),
  })
  vim.api.nvim_set_hl(0, "PantheonOilDeleted", {
    fg = highlight_foreground("DiagnosticError", 0xf87171),
  })
  vim.api.nvim_set_hl(0, "PantheonOilModified", {
    fg = highlight_foreground("DiagnosticWarn", 0xfbd38d),
  })
  vim.api.nvim_set_hl(0, "PantheonOilRenamed", {
    fg = highlight_foreground("DiagnosticInfo", 0x7dd3fc),
  })
  vim.api.nvim_set_hl(0, "PantheonOilDirectory", {
    fg = highlight_foreground("DiagnosticInfo", 0x7dd3fc),
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

vim.api.nvim_create_autocmd({ "BufEnter", "TextChanged" }, {
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
  map("[c", -1, "Previous Pantheon change")
  map("]c", 1, "Next Pantheon change")
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

local function update_loading_buffer(loading, endpoint, frame)
  if not vim.api.nvim_buf_is_valid(endpoint.buf) then
    return
  end
  local name = ("[Pantheon %d] %s %s"):format(
    loading.id,
    endpoint.label,
    frame
  )
  pcall(vim.api.nvim_buf_set_name, endpoint.buf, name)
  vim.bo[endpoint.buf].modifiable = true
  vim.api.nvim_buf_set_lines(endpoint.buf, 0, -1, false, {
    "",
    ("  %s  Loading %s…"):format(frame, endpoint.description),
    "",
    "  Preparing repository and worktree",
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

local function make_loading_tab(loading, role, label, description)
  vim.cmd("tabnew")
  local endpoint = {
    role = role,
    label = label,
    description = description,
    tab = vim.api.nvim_get_current_tabpage(),
    win = vim.api.nvim_get_current_win(),
    buf = vim.api.nvim_get_current_buf(),
  }
  vim.bo[endpoint.buf].buftype = "nofile"
  vim.bo[endpoint.buf].bufhidden = "wipe"
  vim.bo[endpoint.buf].swapfile = false
  vim.bo[endpoint.buf].filetype = "pantheon-inspect"
  vim.t.pantheon_inspect = {
    role = role,
    loading = true,
  }
  update_loading_buffer(loading, endpoint, spinner_frames[1])
  return endpoint
end

local function start_loading_tabs(info)
  require("pantheon.window").close()
  next_loading = next_loading + 1
  local loading = {
    id = next_loading,
    frame = 1,
    stopped = false,
  }
  local parent_role = info.kind == "pull_request" and "base" or "parent"
  loading.parent = make_loading_tab(
    loading,
    parent_role,
    parent_role == "base" and "Base" or "Parent",
    parent_role .. " revision"
  )
  loading.change = make_loading_tab(
    loading,
    "change",
    "Change",
    info.kind == "pull_request" and "pull request head" or "change revision"
  )

  loading.timer = vim.uv.new_timer()
  loading.timer:start(120, 120, vim.schedule_wrap(function()
    if loading.stopped then
      return
    end
    if not vim.api.nvim_buf_is_valid(loading.parent.buf)
      and not vim.api.nvim_buf_is_valid(loading.change.buf)
    then
      stop_loading(loading)
      return
    end
    loading.frame = (loading.frame % #spinner_frames) + 1
    local frame = spinner_frames[loading.frame]
    update_loading_buffer(loading, loading.parent, frame)
    update_loading_buffer(loading, loading.change, frame)
    vim.cmd.redrawtabline()
  end))
  return loading
end

local function show_loading_error(loading, message)
  stop_loading(loading)
  for _, endpoint in ipairs({ loading.parent, loading.change }) do
    if vim.api.nvim_buf_is_valid(endpoint.buf) then
      pcall(
        vim.api.nvim_buf_set_name,
        endpoint.buf,
        ("[Pantheon %d] Inspect failed"):format(loading.id)
          .. " " .. endpoint.label
      )
      vim.bo[endpoint.buf].modifiable = true
      vim.api.nvim_buf_set_lines(endpoint.buf, 0, -1, false, {
        "",
        "  Inspection failed",
        "",
        "  " .. message,
      })
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

local function load_tab(endpoint, path, file, role, commit)
  if not vim.api.nvim_tabpage_is_valid(endpoint.tab) then
    error("a loading tab was closed before inspection completed")
  end
  vim.api.nvim_set_current_tabpage(endpoint.tab)
  if vim.api.nvim_win_is_valid(endpoint.win) then
    vim.api.nvim_set_current_win(endpoint.win)
  end
  vim.cmd("tcd " .. vim.fn.fnameescape(path))
  if file then
    local target = vim.fs.joinpath(path, file)
    vim.cmd("edit " .. vim.fn.fnameescape(target))
  else
    vim.cmd("enew")
  end
  local state = {
    role = role,
    commit = commit,
    worktree = path,
    loading = false,
  }
  vim.t.pantheon_inspect = state
  local loaded = {
    tab = vim.api.nvim_get_current_tabpage(),
    win = vim.api.nvim_get_current_win(),
    buf = vim.api.nvim_get_current_buf(),
  }
  vim.wo[loaded.win].signcolumn = "yes:2"
  return loaded
end

local function open_tabs(paths, loading, done)
  stop_loading(loading)
  local ok, err = pcall(function()
    local parent = load_tab(
      loading.parent,
      paths.parent_worktree,
      paths.parent_file,
      paths.parent_role or "parent",
      paths.parent
    )
    local change = load_tab(
      loading.change,
      paths.change_worktree,
      paths.change_file,
      "change",
      paths.commit
    )
    next_session = next_session + 1
    local session = {
      parent = parent,
      change = change,
      parent_worktree = paths.parent_worktree,
      change_worktree = paths.change_worktree,
      changes = paths.changes,
      hunks = paths.hunks,
      change_lines = change_lines(paths.hunks),
    }
    sessions[next_session] = session
    apply_change_signs(parent.buf, change.buf, paths.hunks)
    map_change_jumps(parent, session)
    map_change_jumps(change, session)
    if session.change_lines[1] then
      set_change_cursor(change.win, session.change_lines[1])
    else
      sync_window(change.win)
    end
  end)
  if not ok then
    done(nil, "could not open inspection tabs: " .. tostring(err))
    return
  end
  done(paths)
end

local function prepare(info, opts, callback)
  local root = opts.inspect_root
    or vim.fs.joinpath(vim.fn.stdpath("cache"), "pantheon", "inspect")

  ensure_mirror(info, root, opts, function(mirror, mirror_err)
    if mirror_err then
      callback(nil, mirror_err)
      return
    end
    fetch_pair(mirror, info, function(commits, commit_err)
      if commit_err then
        callback(nil, commit_err)
        return
      end

      run({
        "git",
        "--git-dir",
        mirror,
        "worktree",
        "prune",
      }, function(_, prune_err)
        if prune_err then
          callback(nil, "could not prune cached worktrees: " .. prune_err)
          return
        end

        local worktree_root = vim.fs.joinpath(
          root,
          "worktrees",
          info.owner,
          info.repo
        )
        local parent_path = vim.fs.joinpath(
          worktree_root,
          commits.parent
        )
        local change_path = vim.fs.joinpath(
          worktree_root,
          commits.commit
        )

        ensure_worktree(
          mirror,
          parent_path,
          commits.parent,
          function(_, parent_err)
            if parent_err then
              callback(nil, parent_err)
              return
            end
            ensure_worktree(
              mirror,
              change_path,
              commits.commit,
              function(_, change_err)
                if change_err then
                  callback(nil, change_err)
                  return
                end
                run({
                  "git",
                  "--git-dir",
                  mirror,
                  "diff",
                  "--name-status",
                  "-M",
                  commits.parent,
                  commits.commit,
                  "--",
                }, function(changes, diff_err)
                  if diff_err then
                    callback(nil, "could not read commit changes: " .. diff_err)
                    return
                  end
                  local parent_file, change_file =
                    first_changed_paths(changes)
                  local changed_files = parse_changed_files(changes)
                  local diff_command = {
                    "git",
                    "--git-dir",
                    mirror,
                    "diff",
                    "--no-color",
                    "--no-ext-diff",
                    "--unified=0",
                    "-M",
                    commits.parent,
                    commits.commit,
                    "--",
                  }
                  if parent_file then
                    diff_command[#diff_command + 1] = parent_file
                  end
                  if change_file and change_file ~= parent_file then
                    diff_command[#diff_command + 1] = change_file
                  end
                  run(diff_command, function(patch, patch_err)
                    if patch_err then
                      callback(
                        nil,
                        "could not read commit hunks: " .. patch_err
                      )
                      return
                    end
                    callback({
                      kind = info.kind,
                      parent = commits.parent,
                      commit = commits.commit,
                      parent_role = info.kind == "pull_request"
                          and "base"
                        or "parent",
                      parent_worktree = parent_path,
                      change_worktree = change_path,
                      parent_file = parent_file,
                      change_file = change_file,
                      changes = changed_files,
                      hunks = parse_hunks(patch),
                    })
                  end)
                end)
              end
            )
          end
        )
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
  resolved.title = details.title
  return resolved
end

local function resolve_target(info, opts, callback)
  if info.kind ~= "pull_request" then
    callback(info)
    return
  end

  github.pull_request(
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
      "inspect currently supports GitHub commit and pull request activity"
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
  local target = info.kind == "pull_request"
      and ("pull request #" .. info.number)
    or ("commit " .. info.sha:sub(1, 12))
  vim.notify(
    ("Pantheon: preparing %s/%s %s for inspection"):format(
      info.owner,
      info.repo,
      target
    ),
    vim.log.levels.INFO
  )

  resolve_target(info, opts, function(resolved, resolve_err)
    if resolve_err then
      active = false
      show_loading_error(loading, resolve_err)
      vim.notify("Pantheon: " .. resolve_err, vim.log.levels.ERROR)
      return
    end

    prepare(resolved, opts, function(paths, err)
      if err then
        active = false
        show_loading_error(loading, err)
        vim.notify("Pantheon: " .. err, vim.log.levels.ERROR)
        return
      end
      open_tabs(paths, loading, function(_, open_err)
        active = false
        if open_err then
          show_loading_error(loading, open_err)
          vim.notify("Pantheon: " .. open_err, vim.log.levels.ERROR)
          return
        end
        local base = paths.kind == "pull_request" and "base" or "parent"
        vim.notify(
          "Pantheon: " .. base
            .. " and change worktrees opened in new tabs",
          vim.log.levels.INFO
        )
      end)
    end)
  end)
  return true
end

M._parse_commit_url = parse_commit_url
M._parse_pull_request_url = parse_pull_request_url
M._parse_target_url = parse_target_url
M._apply_pull_request = apply_pull_request
M._first_changed_paths = first_changed_paths
M._parse_changed_files = parse_changed_files
M._github_repository = github_repository
M._parse_hunks = parse_hunks
M._oil_entry_status = oil_entry_status
M._change_lines = change_lines
M._next_change_line = next_change_line

return M
