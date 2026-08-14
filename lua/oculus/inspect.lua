local M = {}
M._preload_cache = {}

local github = require("oculus.github")
local codeberg = require("oculus.codeberg")
local browser = require("oculus.browser")

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
local oil_window_contexts = {}
local default_sidebar_toggle = "<leader>oi"
local default_overview_toggle = "<leader>op"
local default_version_keys = {
  old = "<C-s>",
  new = "<C-d>",
}
local default_next_chunk = "<C-Tab>"
local default_previous_chunk = "<S-Tab>"
local changed_file_read_concurrency = 8
local hidden_overview_guicursor = "a:OculusInspectHiddenCursor"
local inspection_statusline_option =
  "%!v:lua.require('oculus.inspect')._inspection_statusline()"
local inspection_sidebar_statusline_option = "[oculus] "
local normalize_inspection_view
local refresh_sidebar
local focus_sidebar_selection
local select_next_sidebar_chunk
local select_previous_sidebar_chunk
local switch_sidebar_version
local close_inspection_sidebar
local open_inspection_sidebar
local ensure_inspection_sidebar_on_tab
local restore_inspection_sidebar_for_buffer
local show_inspection_overview
local show_sidebar_files

function M._use_absolute_treesitter_context_numbers()
  local ok, render = pcall(require, "treesitter-context.render")
  if not ok
    or type(render) ~= "table"
    or type(render.open) ~= "function"
    or render._oculus_absolute_line_numbers
  then
    return
  end
  local original_open = render.open
  render.open = function(win, ...)
    if not vim.api.nvim_win_is_valid(win) then
      return original_open(win, ...)
    end
    local buf = vim.api.nvim_win_get_buf(win)
    if type(vim.b[buf].oculus_inspect) ~= "table"
      or not vim.wo[win].relativenumber
    then
      return original_open(win, ...)
    end

    local had_number = vim.wo[win].number
    vim.api.nvim_win_call(win, function()
      vim.cmd("noautocmd setlocal number norelativenumber")
    end)
    local result = { pcall(original_open, win, ...) }
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_call(win, function()
        vim.cmd(
          "noautocmd setlocal "
            .. (had_number and "number" or "nonumber")
            .. " relativenumber"
        )
      end)
    end
    if not result[1] then
      error(result[2], 0)
    end
    return unpack(result, 2)
  end
  render._oculus_absolute_line_numbers = true
end

function M._refresh_inspection_treesitter_context_highlights()
  local ok, render = pcall(require, "treesitter-context.render")
  if not ok
    or type(render) ~= "table"
    or type(render.open) ~= "function"
    or render._oculus_refresh_inspection_highlights
  then
    return
  end
  local original_open = render.open
  render.open = function(win, ranges, lines, force_hl_update)
    local source_uses_treesitter = false
    local source_buf
    if vim.api.nvim_win_is_valid(win) then
      source_buf = vim.api.nvim_win_get_buf(win)
      if type(vim.b[source_buf].oculus_inspect) == "table" then
        local highlighters = vim.treesitter
            and vim.treesitter.highlighter
            and vim.treesitter.highlighter.active
          or nil
        if highlighters
          and not highlighters[source_buf]
          and vim.treesitter.start
        then
          pcall(vim.treesitter.start, source_buf)
        end
        source_uses_treesitter = highlighters and highlighters[source_buf]
          or false
        local changedtick = vim.api.nvim_buf_get_changedtick(source_buf)
        if vim.b[source_buf].oculus_context_highlight_tick ~= changedtick then
          vim.b[source_buf].oculus_context_highlight_tick = changedtick
          local parser_ok, parser = pcall(
            vim.treesitter.get_parser,
            source_buf
          )
          if parser_ok and parser then
            pcall(parser.parse, parser, true, function()
              vim.schedule(function()
                if vim.api.nvim_win_is_valid(win)
                  and vim.api.nvim_win_get_buf(win) == source_buf
                then
                  original_open(win, ranges, lines, true)
                end
              end)
            end)
          end
        end
        -- The context buffer is reused as its source rows change. Force the
        -- renderer to recopy source Treesitter extmarks so its syntax colors do
        -- not depend on whether the visible text itself changed.
        force_hl_update = true
      end
    end
    local result = { pcall(original_open, win, ranges, lines, force_hl_update) }
    if result[1]
      and source_buf
      and not source_uses_treesitter
      and vim.bo[source_buf].syntax ~= ""
    then
      for _, context_win in ipairs(vim.api.nvim_list_wins()) do
        local config = vim.api.nvim_win_get_config(context_win)
        if vim.w[context_win].treesitter_context
          and config.relative == "win"
          and config.win == win
        then
          vim.api.nvim_buf_call(
            vim.api.nvim_win_get_buf(context_win),
            function()
              vim.cmd("syntax sync fromstart")
            end
          )
          break
        end
      end
    end
    if result[1] and vim.api.nvim_win_is_valid(win) then
      local display_options = {
        "tabstop",
        "shiftwidth",
        "softtabstop",
        "vartabstop",
        "varsofttabstop",
        "expandtab",
        "list",
        "listchars",
      }
      for _, context_win in ipairs(vim.api.nvim_list_wins()) do
        local config = vim.api.nvim_win_get_config(context_win)
        if vim.w[context_win].treesitter_context
          and config.relative == "win"
          and config.win == win
        then
          for _, option in ipairs(display_options) do
            local ok, value = pcall(
              vim.api.nvim_get_option_value,
              option,
              { win = win }
            )
            if ok then
              pcall(
                vim.api.nvim_set_option_value,
                option,
                value,
                { win = context_win }
              )
            end
          end
          break
        end
      end
    end
    if not result[1] then
      error(result[2], 0)
    end
    return unpack(result, 2)
  end
  render._oculus_refresh_inspection_highlights = true
end

function M._enable_inspection_treesitter_context(opts)
  if opts and opts.inspect_treesitter_context == false then
    return false
  end
  local ok, context = pcall(require, "treesitter-context")
  if not ok or type(context) ~= "table" then
    return false
  end
  M._use_absolute_treesitter_context_numbers()
  M._refresh_inspection_treesitter_context_highlights()
  local multiwindow = not opts
    or opts.inspect_treesitter_context_multiwindow ~= false
  local mode = opts and opts.inspect_treesitter_context_mode or "topline"
  if mode ~= "cursor" and mode ~= "topline" then
    mode = "topline"
  end
  local enabled = type(context.enabled) == "function"
    and context.enabled()
  local configured_multiwindow = context.config
    and context.config.multiwindow == true
  local separator_disabled = context.config
    and context.config.separator == false
  local configured_mode = context.config and context.config.mode
  if not enabled
    or configured_multiwindow ~= multiwindow
    or not separator_disabled
    or configured_mode ~= mode
  then
    if type(context.setup) ~= "function" then
      return false
    end
    local setup_ok = pcall(context.setup, {
      enable = true,
      multiwindow = multiwindow,
      separator = false,
      mode = mode,
    })
    if not setup_ok then
      return false
    end
  end
  -- Context is rendered in a separate floating window. Linking its surface to
  -- Normal prevents colorschemes with a panel-style TreesitterContext
  -- background from drawing an apparent divider above inspected code.
  vim.api.nvim_set_hl(0, "TreesitterContext", { link = "Normal" })
  -- nvim-treesitter-context applies this group as a high-priority line
  -- highlight to its final visible row. Keep it background-only: linking it
  -- to Normal supplies a foreground and masks that row's token highlights.
  vim.api.nvim_set_hl(0, "TreesitterContextBottom", { bg = "NONE" })
  vim.api.nvim_set_hl(0, "TreesitterContextLineNumber", {
    link = "Normal",
  })
  vim.api.nvim_set_hl(0, "TreesitterContextLineNumberBottom", {
    link = "TreesitterContextLineNumber",
  })
  vim.api.nvim_set_hl(0, "TreesitterContextSeparator", {
    link = "TreesitterContext",
  })
  return true
end

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

local function map_concurrently(items, limit, worker, callback)
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
      created_at = issue.created_at,
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

local function preserve_cursorline_text_highlighting(win)
  if not vim.api.nvim_win_is_valid(win) then
    return false
  end
  local mappings = {}
  for _, mapping in ipairs(vim.split(
    vim.wo[win].winhighlight,
    ",",
    { trimempty = true }
  )) do
    if not mapping:match("^CursorLine:") then
      mappings[#mappings + 1] = mapping
    end
  end
  mappings[#mappings + 1] =
    "CursorLine:OculusInspectCursorLine"
  vim.wo[win].winhighlight = table.concat(mappings, ",")
  return true
end

function M._use_native_cursorline_highlighting(win)
  if not vim.api.nvim_win_is_valid(win) then
    return false
  end
  local mappings = {}
  for _, mapping in ipairs(vim.split(
    vim.wo[win].winhighlight,
    ",",
    { trimempty = true }
  )) do
    if not mapping:match("^CursorLine:") then
      mappings[#mappings + 1] = mapping
    end
  end
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

local function inspection_statusline_path(state)
  if type(state) ~= "table"
    or type(state.repository) ~= "string"
    or state.repository == ""
  then
    return nil
  end
  local repository = vim.fs.normalize(state.repository)
  local repository_folder = vim.fs.basename(repository)
  local file = type(state.file) == "string" and state.file or nil
  if not file or file == "" then
    file = type(state.source_path) == "string"
        and vim.fs.basename(state.source_path)
      or nil
  end
  if not file or file == "" then
    return repository_folder
  end
  file = file:gsub("\\", "/"):gsub("^/+", "")
  return repository_folder .. "/" .. file
end

local function inspection_buffer_name(state)
  if type(state) ~= "table"
    or type(state.source_path) ~= "string"
    or state.source_path == ""
  then
    return nil
  end
  local revision = type(state.commit) == "string"
      and state.commit:sub(1, 12)
    or "revision"
  local role = tostring(state.role or "inspect"):gsub("[^%w_-]", "-")
  local pair = tostring(state.pair_index or "0")
  return ("%s@oculus-%s-%s-%s"):format(
    state.source_path,
    role,
    revision,
    pair
  )
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
  local statusline_path = inspection_statusline_path(state)
  if statusline_path then
    vim.b[buf].oculus_inspect_statusline_path = statusline_path
    for _, win in ipairs(vim.api.nvim_list_wins()) do
      if vim.api.nvim_win_get_buf(win) == buf then
        vim.wo[win].statusline = inspection_statusline_option
      end
    end
  end
  local buffer_name = inspection_buffer_name(state)
  if buffer_name
    and vim.api.nvim_buf_get_name(buf) ~= buffer_name
  then
    pcall(vim.api.nvim_buf_set_name, buf, buffer_name)
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

local oil_change_marker = {
  sign = "•",
  highlight = "OculusOilChange",
}

local oil_status = {
  A = oil_change_marker,
  C = oil_change_marker,
  D = oil_change_marker,
  M = oil_change_marker,
  R = oil_change_marker,
  T = oil_change_marker,
  directory = oil_change_marker,
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

local function entered_oil_subdirectory(previous, current)
  if type(previous) ~= "string"
    or previous == ""
    or type(current) ~= "string"
    or current == ""
  then
    return false
  end
  previous = comparable_path(previous)
  current = comparable_path(current)
  return current ~= previous
    and current:sub(1, #previous + 1) == previous .. "/"
end

local function first_changed_oil_file_line(
  buf,
  session,
  role,
  relative,
  oil
)
  local listing_ready = false
  for line = 1, vim.api.nvim_buf_line_count(buf) do
    local entry = oil.get_entry_on_line(buf, line)
    listing_ready = listing_ready or entry ~= nil
    if entry
      and entry.name
      and entry.name ~= ".."
      and entry.type ~= "directory"
    then
      local path = relative == ""
          and entry.name
        or (relative .. "/" .. entry.name)
      local status = oil_entry_status(session, role, path, false)
      if status and status ~= "directory" then
        return line, true
      end
    end
  end
  return nil, listing_ready
end

local function focus_first_changed_oil_file(
  buf,
  context,
  directory,
  oil
)
  local session, role, relative = session_directory(
    context.session,
    context.role,
    directory
  )
  if not session then
    return
  end
  local line, listing_ready = first_changed_oil_file_line(
    buf,
    session,
    role,
    relative,
    oil
  )
  if not line then
    return false, listing_ready
  end
  local wins = vim.fn.win_findbuf(buf)
  local win = vim.api.nvim_get_current_buf() == buf
      and vim.api.nvim_get_current_win()
    or wins[1]
  if not win or not vim.api.nvim_win_is_valid(win) then
    return false, listing_ready
  end
  vim.api.nvim_win_set_cursor(win, { line, 0 })
  return true, true
end

local function oil_context_for_window(win)
  local context = oil_window_contexts[win]
  return context and context.active and context or nil
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
      oil_window_contexts[context.win] = nil
      local group = context.group
      if context.restore_sidebar
        and group
        and not group.sidebar_visible
        and open_inspection_sidebar
      then
        context.restore_sidebar = false
        local endpoint = context.session and context.session[context.role]
        open_inspection_sidebar(group, endpoint and endpoint.tab or nil)
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
  local context = oil_contexts[buf] or oil_context_for_window(win)
  if context then
    oil_contexts[buf] = context
    vim.b[buf].oculus_inspect_oil_origin = {
      directory = context.directory,
      filename = context.filename,
      source_buf = context.source_buf,
    }
    local descended = entered_oil_subdirectory(
      context.current_directory,
      directory
    )
    if descended then
      context.pending_changed_file_directory = directory
    elseif context.pending_changed_file_directory
      and comparable_path(context.pending_changed_file_directory)
        ~= comparable_path(directory)
    then
      context.pending_changed_file_directory = nil
    end
    context.current_directory = directory
    if context.win ~= win then
      oil_window_contexts[context.win] = nil
    end
    context.win = win
    oil_window_contexts[win] = context
    activate_oil_context(context)
    local focused_changed_file = false
    local listing_ready = false
    if context.pending_changed_file_directory
      and comparable_path(context.pending_changed_file_directory)
        == comparable_path(directory)
    then
      focused_changed_file, listing_ready =
        focus_first_changed_oil_file(
          buf,
          context,
          directory,
          oil
        )
      if focused_changed_file or listing_ready then
        context.pending_changed_file_directory = nil
      end
    end
    if not focused_changed_file
      and comparable_path(directory)
        == comparable_path(context.directory)
    then
      focus_oil_origin(buf, context, oil)
    end
    map_oil_origin_selection(buf, context, oil)
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
    session = session,
    role = role,
    current_directory = directory,
    win = win,
  }
  vim.b[buf].oculus_inspect_oil_origin = {
    directory = context.directory,
    filename = context.filename,
    source_buf = context.source_buf,
  }

  local group = sidebar_group_for_session(session)
  context.group = group
  oil_contexts[buf] = context
  activate_oil_context(context)
  oil_window_contexts[win] = context

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
  vim.api.nvim_set_hl(0, "OculusOilChange", {
    fg = 0xfbd38d,
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

vim.api.nvim_create_autocmd("WinClosed", {
  group = oil_group,
  callback = function(args)
    local win = tonumber(args.match)
    if win then
      oil_window_contexts[win] = nil
    end
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
  local overview_section =
    vim.api.nvim_get_hl(0, { name = "Function", link = false })
  local cursorline =
    vim.api.nvim_get_hl(0, { name = "CursorLine", link = false })
  vim.api.nvim_set_hl(0, "OculusInspectRemoved", {
    fg = 0xfee2e2,
    bg = 0x991b1b,
  })
  vim.api.nvim_set_hl(0, "OculusInspectAdded", {
    fg = 0xdcfce7,
    bg = 0x166534,
  })
  vim.api.nvim_set_hl(0, "OculusIssueSection", {
    fg = diagnostic_info.fg or 0x61afef,
    bg = normal.bg,
  })
  overview_section.underline = true
  overview_section.sp = overview_section.sp or overview_section.fg
  vim.api.nvim_set_hl(
    0,
    "OculusInspectOverviewSection",
    overview_section
  )
  vim.api.nvim_set_hl(0, "OculusInspectAgentModelSelected", {
    fg = diagnostic_info.fg or 0x61afef,
    bold = true,
  })
  vim.api.nvim_set_hl(0, "OculusInspectQueueCurrent", {
    fg = diagnostic_info.fg or 0x61afef,
    bold = true,
  })
  vim.api.nvim_set_hl(0, "OculusInspectHiddenCursor", {
    fg = normal.bg,
    bg = normal.bg,
    blend = 100,
    nocombine = true,
  })
  vim.api.nvim_set_hl(0, "OculusInspectCursorLine", {
    bg = cursorline.bg,
    sp = cursorline.sp,
    blend = cursorline.blend,
    bold = cursorline.bold,
    italic = cursorline.italic,
    underline = cursorline.underline,
    undercurl = cursorline.undercurl,
    underdouble = cursorline.underdouble,
    underdotted = cursorline.underdotted,
    underdashed = cursorline.underdashed,
    strikethrough = cursorline.strikethrough,
  })
end

set_change_highlights()

vim.api.nvim_create_autocmd("ColorScheme", {
  group = oil_group,
  callback = set_change_highlights,
})

local function apply_change_signs(parent_buf, change_buf, hunks, status)
  set_change_highlights()
  vim.api.nvim_buf_clear_namespace(parent_buf, change_ns, 0, -1)
  vim.api.nvim_buf_clear_namespace(change_buf, change_ns, 0, -1)
  if status == "A" then
    return
  end

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

function M._sync_buffer_syntax(buf)
  for _, win in ipairs(vim.fn.win_findbuf(buf)) do
    vim.api.nvim_win_call(win, function()
      vim.cmd("syntax sync fromstart")
    end)
  end
end

function M._enable_inspection_syntax(buf)
  local filetype = vim.bo[buf].filetype
  if filetype == "" then
    return false
  end
  if vim.bo[buf].syntax == "" then
    vim.bo[buf].syntax = filetype
  end
  if vim.b[buf].current_syntax == nil then
    vim.api.nvim_buf_call(buf, function()
      vim.cmd(
        "silent! runtime! syntax/"
          .. vim.fn.fnameescape(filetype)
          .. ".vim"
      )
    end)
  end
  M._sync_buffer_syntax(buf)
  return vim.bo[buf].syntax ~= ""
end

local function refresh_buffer_highlighting(buf, force)
  if not vim.api.nvim_buf_is_valid(buf)
    or type(vim.b[buf].oculus_inspect) ~= "table"
  then
    return false
  end
  local changedtick = vim.api.nvim_buf_get_changedtick(buf)
  if vim.b[buf].oculus_inspect_highlight_engine == "syntax" then
    if vim.b[buf].oculus_inspect_syntax_changedtick == changedtick
      and not force
    then
      return true
    end
    local syntax_enabled = M._enable_inspection_syntax(buf)
    if syntax_enabled then
      vim.b[buf].oculus_inspect_syntax_changedtick = changedtick
    end
    return syntax_enabled
  end
  if (vim.b[buf].oculus_inspect_highlighting_changedtick == changedtick
      or vim.b[buf].oculus_inspect_highlighting_pending_tick == changedtick
      or vim.b[buf].oculus_inspect_syntax_changedtick == changedtick)
    and not force
  then
    return true
  end

  local syntax = vim.bo[buf].syntax
  if syntax ~= "" then
    M._sync_buffer_syntax(buf)
  end

  local highlighters = vim.treesitter
      and vim.treesitter.highlighter
      and vim.treesitter.highlighter.active
    or nil
  local treesitter_start_ok = false
  if highlighters and not highlighters[buf] and vim.treesitter.start then
    treesitter_start_ok = pcall(vim.treesitter.start, buf)
  end
  if highlighters and highlighters[buf] then
    local parser_ok, parser = pcall(vim.treesitter.get_parser, buf)
    if parser_ok and parser then
      pcall(parser.invalidate, parser, true)
      vim.b[buf].oculus_inspect_highlighting_pending_tick = changedtick
      local parse_ok = pcall(parser.parse, parser, true, function()
        if vim.api.nvim_buf_is_valid(buf) then
          vim.schedule(function()
            if vim.api.nvim_buf_is_valid(buf) then
              if vim.b[buf].oculus_inspect_highlighting_pending_tick
                  == changedtick
              then
                if vim.api.nvim_buf_get_changedtick(buf) == changedtick then
                  vim.b[buf].oculus_inspect_highlighting_changedtick =
                    changedtick
                end
                vim.b[buf].oculus_inspect_highlighting_pending_tick = nil
              end
              vim.cmd("redraw")
            end
          end)
        end
      end)
      if not parse_ok then
        if vim.b[buf].oculus_inspect_highlighting_pending_tick
            == changedtick
        then
          vim.b[buf].oculus_inspect_highlighting_pending_tick = nil
        end
        return false
      end
    else
      return false
    end
  else
    local syntax_enabled = M._enable_inspection_syntax(buf)
    if syntax_enabled and not treesitter_start_ok then
      vim.b[buf].oculus_inspect_syntax_changedtick = changedtick
    end
    return syntax_enabled and not treesitter_start_ok
  end

  if not inspection_tabs_loading then
    vim.cmd("redraw")
  end
  return true
end

function M._synchronize_inspection_highlighting(parent_buf, change_buf)
  if not vim.api.nvim_buf_is_valid(parent_buf)
    or not vim.api.nvim_buf_is_valid(change_buf)
  then
    return nil
  end
  local buffers = { parent_buf, change_buf }
  if vim.bo[parent_buf].filetype ~= vim.bo[change_buf].filetype then
    for _, buf in ipairs(buffers) do
      refresh_buffer_highlighting(buf, true)
    end
    return "mixed"
  end

  for _, buf in ipairs(buffers) do
    vim.b[buf].oculus_inspect_highlight_engine = nil
    refresh_buffer_highlighting(buf, true)
  end
  local highlighters = vim.treesitter
      and vim.treesitter.highlighter
      and vim.treesitter.highlighter.active
    or nil
  if highlighters
    and highlighters[parent_buf]
    and highlighters[change_buf]
  then
    for _, buf in ipairs(buffers) do
      vim.b[buf].oculus_inspect_highlight_engine = "treesitter"
    end
    return "treesitter"
  end

  for _, buf in ipairs(buffers) do
    if highlighters and highlighters[buf] and vim.treesitter.stop then
      pcall(vim.treesitter.stop, buf)
    end
    vim.b[buf].oculus_inspect_highlight_engine = "syntax"
    vim.b[buf].oculus_inspect_highlighting_changedtick = nil
    vim.b[buf].oculus_inspect_highlighting_pending_tick = nil
    if M._enable_inspection_syntax(buf) then
      vim.b[buf].oculus_inspect_syntax_changedtick =
        vim.api.nvim_buf_get_changedtick(buf)
    end
  end
  return "syntax"
end

local function apply_inspection_filetype(buf, force_refresh)
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
    vim.b[buf].oculus_inspect_highlighting_changedtick = nil
    vim.b[buf].oculus_inspect_highlighting_pending_tick = nil
    vim.b[buf].oculus_inspect_syntax_changedtick = nil
    vim.bo[buf].filetype = filetype
  end
  local reliquary_ok, reliquary = pcall(require, "reliquary")
  if reliquary_ok
    and type(reliquary) == "table"
    and type(reliquary.apply) == "function"
  then
    pcall(reliquary.apply, buf)
  end
  local window_ok, window = pcall(require, "oculus.window")
  if window_ok and type(window.refresh_window_highlights) == "function" then
    local highlight_source_win
    for _, candidate in ipairs(vim.fn.win_findbuf(buf)) do
      if vim.api.nvim_win_is_valid(candidate) then
        highlight_source_win = candidate
        break
      end
    end
    window.refresh_window_highlights(highlight_source_win)
  end
  refresh_buffer_highlighting(buf, force_refresh)
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
  }, session.status)
  refresh_buffer_highlighting(session.change.buf)
  return start
end

local function render_full_file(session)
  if not replace_inspection_lines(
    session.change,
    session.change_content or {}
  ) then
    return false
  end
  session.active_chunk = nil
  session.focused_start = nil
  session.focused_chunks = false
  apply_change_signs(
    session.parent.buf,
    session.change.buf,
    session.hunks,
    session.status
  )
  refresh_buffer_highlighting(session.change.buf)
  return true
end

local function position_change_cursor(win, line)
  if not vim.api.nvim_win_is_valid(win) then
    return false
  end
  local buf = vim.api.nvim_win_get_buf(win)
  local line_count = vim.api.nvim_buf_line_count(buf)
  line = math.min(math.max(1, line), line_count)
  vim.api.nvim_win_set_cursor(win, { line, 0 })
  normalize_inspection_view(win)
  return true
end

local function set_change_cursor(win, line)
  if not position_change_cursor(win, line) then
    return
  end
  sync_window(win)
end

local function show_file_top(win)
  set_change_cursor(win, 1)
  vim.api.nvim_win_call(win, function()
    local view = vim.fn.winsaveview()
    view.lnum = 1
    view.col = 0
    view.curswant = 0
    view.topline = 1
    view.leftcol = 0
    vim.fn.winrestview(view)
  end)
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
      "zt10<C-y>$",
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

local function remember_session_role(session, role)
  if session
    and (role == "parent" or role == "change" or role == "issue")
  then
    session.last_role = role
  end
end

local function select_endpoint(endpoint, session, role, group)
  if not valid_endpoint(endpoint) then
    return
  end
  remember_session_role(session, role)
  sidebar_navigating = true
  vim.api.nvim_set_current_tabpage(endpoint.tab)
  vim.api.nvim_set_current_win(endpoint.win)
  show_inspection_path(endpoint.buf)
  sidebar_navigating = false
  vim.schedule(function()
    if valid_endpoint(endpoint) then
      refresh_buffer_highlighting(endpoint.buf, false)
    end
  end)
  if group and ensure_inspection_sidebar_on_tab then
    ensure_inspection_sidebar_on_tab(group, endpoint.tab)
  end
end

local function move_cursor_to_line_start(win, line)
  if not win or not vim.api.nvim_win_is_valid(win) then
    return
  end
  if line then
    set_change_cursor(win, line)
  end
  vim.api.nvim_win_call(win, function()
    vim.cmd("normal! ^")
  end)
  if line then
    sync_window(win)
  end
end

local function inspection_chunks(group, session)
  return group.kind == "issue"
      and (session.sections or {})
    or (session.hunks or {})
end

local function next_inspection_chunk(group, session, current_chunk)
  local current_index
  for index, candidate in ipairs(group) do
    if candidate == session then
      current_index = index
      break
    end
  end
  if not current_index then
    return
  end
  local current_chunks = inspection_chunks(group, session)
  if current_chunk < #current_chunks then
    return session, current_index, current_chunk + 1
  end
  for offset = 1, #group do
    local index = ((current_index + offset - 1) % #group) + 1
    local candidate = group[index]
    local chunks = inspection_chunks(group, candidate)
    if #chunks > 0 then
      return candidate, index, 1
    end
  end
end

local function previous_inspection_chunk(group, session, current_chunk)
  local current_index
  for index, candidate in ipairs(group) do
    if candidate == session then
      current_index = index
      break
    end
  end
  if not current_index then
    return
  end
  if current_chunk > 1 then
    return session, current_index, current_chunk - 1
  end
  for offset = 1, #group do
    local index = ((current_index - offset - 1) % #group) + 1
    local candidate = group[index]
    local chunks = inspection_chunks(group, candidate)
    if #chunks > 0 then
      return candidate, index, #chunks
    end
  end
end

local function progressed_chunk_role(_, current_role)
  return current_role
end

local function chunk_navigation_role(
  group,
  current_session,
  current_role,
  target_session,
  forward
)
  if target_session ~= current_session and target_session.last_role then
    return target_session.last_role
  end
  if forward then
    return progressed_chunk_role(group, current_role)
  end
  return current_role
end

local function chunk_start_for_role(
  hunk,
  role,
  change_start,
  change_content
)
  if role == "parent" then
    return hunk_start(hunk, "parent")
  end
  for offset = 0, math.max(0, hunk.new_count or 0) - 1 do
    local line = change_content
      and change_content[(hunk.new_start or 1) + offset]
    if type(line) == "string" and line:find("%S") then
      return change_start + offset
    end
  end
  return change_start
end

local function render_chunk_for_role(session, role, chunk_index)
  local hunk = session.hunks and session.hunks[chunk_index] or nil
  if not hunk then
    return
  end
  local change_start = render_focused_chunk(session, chunk_index)
    or focused_hunk_start(hunk)
  return chunk_start_for_role(
    hunk,
    role,
    change_start,
    session.change_content
  )
end

local function focus_inspection_chunk(group, session, role, chunk_index)
  local endpoint = group.kind == "issue"
      and session.issue
    or session[role]
  if not valid_endpoint(endpoint) then
    return
  end
  local chunks = inspection_chunks(group, session)
  local start
  if group.kind == "issue" then
    session.active_chunk = chunk_index
    start = chunks[chunk_index] and chunks[chunk_index].line
  else
    start = render_chunk_for_role(session, role, chunk_index)
  end
  select_endpoint(endpoint, session, role, group)
  if start then
    move_cursor_to_line_start(endpoint.win, start)
  end
  show_inspection_path(endpoint.buf)
  refresh_sidebar(group, endpoint.tab)
  return endpoint
end

local function map_file_navigation(endpoint, session, role, group)
  local function select_version(target_role)
    if role == target_role then
      return
    end
    local target = session[target_role]
    select_endpoint(target, session, target_role, group)
    if valid_endpoint(target) then
      refresh_sidebar(group, target.tab)
    end
  end
  local function map_version(lhs, target_role, description)
    if type(lhs) == "string" and lhs ~= "" then
      vim.keymap.set("n", lhs, function()
        select_version(target_role)
      end, {
        buffer = endpoint.buf,
        nowait = true,
        silent = true,
        desc = description,
      })
    end
  end
  if not group.patch_suggestions then
    local old_lhs = group.old_version
    if old_lhs == nil then
      old_lhs = default_version_keys.old
    end
    local new_lhs = group.new_version
    if new_lhs == nil then
      new_lhs = default_version_keys.new
    end
    map_version(old_lhs, "parent", "Open Oculus old file version")
    map_version(new_lhs, "change", "Open Oculus new file version")
  end
  local next_chunk_lhs = group.next_chunk
  if next_chunk_lhs == nil then
    next_chunk_lhs = default_next_chunk
  end
  if
    type(next_chunk_lhs) == "string"
    and next_chunk_lhs ~= ""
  then
    vim.keymap.set("n", next_chunk_lhs, function()
      select_next_sidebar_chunk(group, role)
    end, {
      buffer = endpoint.buf,
      nowait = true,
      silent = true,
      desc = "Next Oculus changed chunk",
    })
  end
  local previous_chunk_lhs = group.previous_chunk
  if previous_chunk_lhs == nil then
    previous_chunk_lhs = default_previous_chunk
  end
  if
    type(previous_chunk_lhs) == "string"
    and previous_chunk_lhs ~= ""
  then
    vim.keymap.set("n", previous_chunk_lhs, function()
      select_previous_sidebar_chunk(group, role)
    end, {
      buffer = endpoint.buf,
      nowait = true,
      silent = true,
      desc = "Previous Oculus changed chunk",
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

local function sidebar_target_role(
  active_index,
  active_role,
  entry,
  group,
  preferred_role
)
  if group and group.kind == "issue" then
    return "issue"
  end
  if entry and entry.pair_index ~= active_index then
    local session = group and group[entry.pair_index]
    return session and session.last_role
      or preferred_role
      or "parent"
  end
  return preferred_role or active_role
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

local function sort_inspections(inspections)
  local ordered = {}
  local first_commit_by_path = {}
  local commit_indices = {}
  for index, inspection in ipairs(inspections or {}) do
    local path = inspection.change_file
      or inspection.parent_file
      or inspection.file
      or ""
    path = path:gsub("\\", "/"):gsub("^%./", ""):gsub("/+$", "")
    local parent = path:match("^(.*)/[^/]+$") or ""
    local name = path:match("([^/]+)$") or path
    local depth = 0
    for _ in parent:gmatch("[^/]+") do
      depth = depth + 1
    end
    ordered[index] = {
      inspection = inspection,
      index = index,
      depth = depth,
      parent = parent:lower(),
      name = name:lower(),
      path = path:lower(),
    }
    local commit_index = tonumber(inspection.commit_index)
    if commit_index then
      commit_indices[commit_index] = true
      local first = first_commit_by_path[path:lower()]
      if not first or commit_index < first then
        first_commit_by_path[path:lower()] = commit_index
      end
    end
  end
  local multi_commit = vim.tbl_count(commit_indices) > 1
  table.sort(ordered, function(left, right)
    if multi_commit then
      local left_commit = first_commit_by_path[left.path]
      local right_commit = first_commit_by_path[right.path]
      if left_commit ~= right_commit then
        return (left_commit or math.huge) < (right_commit or math.huge)
      end
    end
    if left.depth ~= right.depth then
      return left.depth < right.depth
    end
    if left.parent ~= right.parent then
      return left.parent < right.parent
    end
    if left.name ~= right.name then
      return left.name < right.name
    end
    if left.path ~= right.path then
      return left.path < right.path
    end
    if multi_commit
      and left.inspection.commit_index ~= right.inspection.commit_index
    then
      return left.inspection.commit_index < right.inspection.commit_index
    end
    if multi_commit
      and left.inspection.file_index ~= right.inspection.file_index
    then
      return left.inspection.file_index < right.inspection.file_index
    end
    return left.index < right.index
  end)
  for index, item in ipairs(ordered) do
    inspections[index] = item.inspection
  end
  return inspections
end

local function sidebar_file(file)
  local normalized = file:gsub("\\", "/"):gsub("/+$", "")
  return normalized:match("([^/]+)$") or normalized
end

local function sidebar_row(file, width, version)
  local prefix = "• "
  local suffix = "P C"
  local version_text = version and (" v.%d"):format(version) or ""
  local path_width = math.max(
    1,
    width
      - vim.fn.strdisplaywidth(prefix)
      - vim.fn.strdisplaywidth(suffix)
      - vim.fn.strdisplaywidth(version_text)
      - 2
  )
  local path = truncate_path(file, path_width)
  local body = prefix .. path .. version_text
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
    version_column = version
        and (#prefix + #path + 1)
      or nil,
    version_end_column = version
        and (#prefix + #path + #version_text)
      or nil,
  }
end

function M._assign_sidebar_versions(group)
  local counts = {}
  for index, session in ipairs(group or {}) do
    session.file = session.file or ("file " .. index)
    session.sidebar_version = nil
    session.sidebar_version_count = nil
    local key = session.file
      :gsub("\\", "/")
      :gsub("^%./", "")
      :gsub("/+$", "")
    counts[key] = (counts[key] or 0) + 1
  end

  local versions = {}
  for _, session in ipairs(group or {}) do
    local key = session.file
      :gsub("\\", "/")
      :gsub("^%./", "")
      :gsub("/+$", "")
    if counts[key] > 1 then
      versions[key] = (versions[key] or 0) + 1
      session.sidebar_version = versions[key]
      session.sidebar_version_count = counts[key]
    end
  end
  return group
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
  local suffix = delta ~= 0 and (" (" .. delta_text .. ")") or ""
  return ("  %s %d-%d%s"):format(
    branch,
    first,
    last_line,
    suffix
  )
end

local function inspection_overview(info)
  local overview = vim.deepcopy(info or {})
  local route = overview.kind == "issue"
      and ("issues/" .. tostring(overview.number))
    or overview.kind == "pull_request" and (
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

local function utc_timestamp(year, month, day, hour, minute, second)
  year = month <= 2 and year - 1 or year
  local era = math.floor(year / 400)
  local year_of_era = year - era * 400
  local month_index = month > 2 and month - 3 or month + 9
  local day_of_year = math.floor((153 * month_index + 2) / 5) + day - 1
  local day_of_era = year_of_era * 365
    + math.floor(year_of_era / 4)
    - math.floor(year_of_era / 100)
    + day_of_year
  local days = era * 146097 + day_of_era - 719468
  return days * 86400 + hour * 3600 + minute * 60 + second
end

local overview_months = {
  "January",
  "February",
  "March",
  "April",
  "May",
  "June",
  "July",
  "August",
  "September",
  "October",
  "November",
  "December",
}

local function overview_date(timestamp)
  if type(timestamp) ~= "string" or timestamp == "" then
    return "Unknown"
  end
  local year, month, day, hour, minute, second, sign, offset_hour,
    offset_minute = timestamp:match(
      "^(%d%d%d%d)%-(%d%d)%-(%d%d)T(%d%d):(%d%d):(%d%d)([+-])(%d%d):(%d%d)$"
    )
  if not year then
    year, month, day, hour, minute, second = timestamp:match(
      "^(%d%d%d%d)%-(%d%d)%-(%d%d)T(%d%d):(%d%d):(%d%d)Z$"
    )
  end
  if not year then
    return timestamp
  end
  local opened = utc_timestamp(
    tonumber(year),
    tonumber(month),
    tonumber(day),
    tonumber(hour),
    tonumber(minute),
    tonumber(second)
  )
  if sign then
    local offset = tonumber(offset_hour) * 3600
      + tonumber(offset_minute) * 60
    opened = opened + (sign == "+" and -offset or offset)
  end
  local local_date = os.date("*t", opened)
  return ("%s %d, %d"):format(
    overview_months[local_date.month],
    local_date.day,
    local_date.year
  )
end

local function sidebar_overview_lines(overview, width)
  width = math.max(12, tonumber(width) or 28)
  local details = overview.commit_details or {}
  local is_pull_request = overview.kind == "pull_request"
  local is_issue = overview.kind == "issue"
  local lines = {
    "OVERVIEW",
    "",
  }
  local function field(label, value)
    if value == nil or value == "" then
      return
    end
    lines[#lines + 1] = "  " .. label
    append_sidebar_text(lines, value, width, "  ")
    lines[#lines + 1] = ""
  end
  local function value_or(value, fallback)
    return type(value) == "string" and vim.trim(value) ~= ""
        and value
      or fallback
  end
  field("Title", value_or(
    (is_pull_request or is_issue) and overview.title or details.subject,
    "Untitled"
  ))
  field("Description", value_or(
    (is_pull_request or is_issue) and overview.body or details.body,
    "No description provided."
  ))
  local author
  if is_pull_request or is_issue then
    author = overview.author and ("@" .. overview.author)
  else
    author = details.author_name or ""
    if details.author_email and details.author_email ~= "" then
      author = author .. " <" .. details.author_email .. ">"
    end
  end
  field("Author", value_or(author, "Unknown"))
  if is_pull_request or is_issue then
    field(
      is_issue and "Issue number" or "PR number",
      "#" .. tostring(overview.number or "")
    )
    local status = overview.merged and "Merged"
      or overview.draft and "Draft"
      or (
        type(overview.state) == "string"
          and overview.state:gsub("^%l", string.upper)
        or nil
      )
    field("Status", value_or(status, "Unknown"))
  end
  field(
    "Date",
    overview_date(overview.created_at or details.authored_at)
  )
  if lines[#lines] == "" then
    table.remove(lines)
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
  if group.patch_suggestions then
    local endpoint = sidebar_endpoint(
      group,
      group[active_index],
      active_role
    )
    if valid_endpoint(endpoint) then
      vim.wo[endpoint.win].cursorline = true
      vim.wo[endpoint.win].cursorlineopt = "line"
      M._use_native_cursorline_highlighting(endpoint.win)
      if sidebar_win and vim.api.nvim_win_is_valid(sidebar_win) then
        vim.wo[sidebar_win].cursorline = true
        vim.wo[sidebar_win].cursorlineopt = "line"
        vim.api.nvim_win_set_hl_ns(
          sidebar_win,
          vim.api.nvim_get_hl_ns({ winid = endpoint.win })
        )
        M._use_native_cursorline_highlighting(sidebar_win)
      end
    end
  end
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
  if sidebar_cursor_line and not sidebar_is_focused then
    group.sidebar_navigation_line = sidebar_cursor_line
  end
  if sidebar_cursor_line
    and sidebar_win
    and vim.api.nvim_win_is_valid(sidebar_win)
    and vim.api.nvim_win_get_buf(sidebar_win) == buf
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
      if row.version_column then
        vim.api.nvim_buf_set_extmark(
          buf,
          sidebar_ns,
          row.line_number - 1,
          row.version_column,
          {
            end_col = row.version_end_column,
            hl_group = "Comment",
            priority = 90,
          }
        )
      end
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
  local saved_state = group.sidebar_window_states
      and group.sidebar_window_states[endpoint.tab]
    or nil
  vim.api.nvim_set_current_tabpage(endpoint.tab)
  vim.api.nvim_set_current_win(endpoint.win)
  vim.cmd("botright vsplit")
  local win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(win, group.sidebar_buf)
  vim.api.nvim_win_set_width(
    win,
    saved_state and saved_state.width or group.sidebar_width
  )
  vim.wo[win].winfixwidth = true
  vim.wo[win].number = false
  vim.wo[win].relativenumber = false
  vim.wo[win].signcolumn = "no"
  vim.wo[win].foldcolumn = "0"
  vim.wo[win].wrap = false
  vim.wo[win].cursorline = true
  vim.wo[win].cursorlineopt = "line"
  vim.wo[win].statusline = inspection_sidebar_statusline_option
  prevent_window_dimming(win)
  if group.patch_suggestions then
    vim.api.nvim_win_set_hl_ns(
      win,
      vim.api.nvim_get_hl_ns({ winid = endpoint.win })
    )
    M._use_native_cursorline_highlighting(win)
  else
    set_change_highlights()
    preserve_cursorline_text_highlighting(win)
  end
  group.sidebar_windows[endpoint.tab] = win
  if saved_state then
    vim.api.nvim_win_set_cursor(win, saved_state.cursor)
    vim.api.nvim_win_call(win, function()
      vim.fn.winrestview(saved_state.view)
    end)
    group.sidebar_window_states[endpoint.tab] = nil
  end
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
  group.sidebar_window_states = group.sidebar_window_states or {}
  sidebar_navigating = true
  for tab, win in pairs(group.sidebar_windows or {}) do
    if vim.api.nvim_tabpage_is_valid(tab)
      and vim.api.nvim_win_is_valid(win)
    then
      group.sidebar_window_states[tab] = {
        cursor = vim.api.nvim_win_get_cursor(win),
        view = vim.api.nvim_win_call(win, function()
          return vim.fn.winsaveview()
        end),
        width = vim.api.nvim_win_get_width(win),
      }
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

open_inspection_sidebar = function(group, target_tab, restore_only)
  if group.sidebar_displaced_by_foreign then
    return
  end
  local origin_tab = vim.api.nvim_get_current_tabpage()
  local origin_win = vim.api.nvim_get_current_win()
  group.sidebar_windows = {}
  group.sidebar_visible = true
  sidebar_navigating = true
  if target_tab then
    local endpoint = endpoint_for_tab(group, target_tab)
    if endpoint then
      create_sidebar_window(group, endpoint)
    end
  else
    for _, session in ipairs(group) do
      if group.kind == "issue" then
        create_sidebar_window(group, session.issue)
      else
        create_sidebar_window(group, session.parent)
        create_sidebar_window(group, session.change)
      end
    end
  end
  if vim.api.nvim_tabpage_is_valid(origin_tab)
    and vim.api.nvim_win_is_valid(origin_win)
  then
    vim.api.nvim_set_current_tabpage(origin_tab)
    vim.api.nvim_set_current_win(origin_win)
  end
  sidebar_navigating = false
  if not restore_only then
    refresh_sidebar(group, vim.api.nvim_get_current_tabpage())
  end
end

ensure_inspection_sidebar_on_tab = function(group, tab)
  if sidebar_navigating
    or not group.sidebar_visible
    or group.sidebar_displaced_by_foreign
  then
    return
  end
  local sidebar_win = group.sidebar_windows
    and group.sidebar_windows[tab]
  if sidebar_win and vim.api.nvim_win_is_valid(sidebar_win) then
    return
  end
  local endpoint = endpoint_for_tab(group, tab)
  if not valid_endpoint(endpoint) then
    return
  end
  local origin_win = vim.api.nvim_get_current_win()
  sidebar_navigating = true
  create_sidebar_window(group, endpoint)
  if vim.api.nvim_win_is_valid(origin_win) then
    vim.api.nvim_set_current_win(origin_win)
  end
  sidebar_navigating = false
end

local function toggle_inspection_sidebar(group)
  if group.sidebar_displaced_by_foreign then
    group.sidebar_restore_after_foreign =
      not group.sidebar_restore_after_foreign
    return
  end
  if group.sidebar_visible then
    close_inspection_sidebar(group)
  else
    open_inspection_sidebar(
      group,
      vim.api.nvim_get_current_tabpage(),
      true
    )
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

local function overview_window_is_open(group)
  return group.overview_win
    and vim.api.nvim_win_is_valid(group.overview_win)
end

local function hide_overview_cursor(group)
  if group.overview_cursor_hidden then
    vim.o.guicursor = hidden_overview_guicursor
    return
  end
  group.overview_saved_guicursor = vim.o.guicursor
  group.overview_cursor_hidden = true
  vim.o.guicursor = hidden_overview_guicursor
end

local function restore_overview_cursor(group)
  if not group.overview_cursor_hidden then
    return
  end
  local guicursor = group.overview_saved_guicursor
  group.overview_cursor_hidden = nil
  group.overview_saved_guicursor = nil
  vim.o.guicursor = guicursor or ""
end

local function close_overview_window(group)
  local win = group.overview_win
  local buf = group.overview_buf
  if group.overview_scroll_autocmd then
    pcall(vim.api.nvim_del_autocmd, group.overview_scroll_autocmd)
    group.overview_scroll_autocmd = nil
  end
  if group.overview_highlight_autocmd then
    pcall(vim.api.nvim_del_autocmd, group.overview_highlight_autocmd)
    group.overview_highlight_autocmd = nil
  end
  if win and vim.api.nvim_win_is_valid(win) then
    group.overview_view = vim.api.nvim_win_call(win, function()
      return vim.fn.winsaveview()
    end)
  end
  if M._overview_ui and M._overview_ui.close_footer then
    M._overview_ui.close_footer(group)
  end
  if M._overview_ui and M._overview_ui.close_agent_window then
    M._overview_ui.close_agent_window(group, false)
  end
  if M._overview_ui and M._overview_ui.close_queue_sidebar then
    M._overview_ui.close_queue_sidebar(group)
  end
  group.overview_win = nil
  group.overview_buf = nil
  restore_overview_cursor(group)
  if win and vim.api.nvim_win_is_valid(win) then
    vim.api.nvim_win_close(win, true)
  end
  if buf and vim.api.nvim_buf_is_valid(buf) then
    vim.api.nvim_buf_delete(buf, { force = true })
  end
end

function M._discard_previous_inspections()
  if #sidebar_groups == 0 then
    return
  end

  local function stop_process(process)
    if process and type(process.kill) == "function" then
      pcall(process.kill, process, 15)
    end
  end

  local previous_groups = sidebar_groups
  sidebar_groups = {}
  M._tab_navigation_source = nil
  local discarded_sessions = {}
  local tabs = {}
  local buffers = {}

  for _, group in ipairs(previous_groups) do
    group.discarded = true
    if M._overview_ui and M._overview_ui.stop_agent_spinner then
      M._overview_ui.stop_agent_spinner(group)
    end
    stop_process(group.overview_agent_model_process)
    stop_process(group.overview_agent_process)
    group.overview_agent_model_process = nil
    group.overview_agent_process = nil
    group.overview_agent_mode = nil
    close_overview_window(group)
    if group.sidebar_buf then
      buffers[group.sidebar_buf] = true
    end
    for _, session in ipairs(group) do
      discarded_sessions[session] = true
      local endpoints = group.kind == "issue"
          and { session.issue }
        or { session.parent, session.change }
      for _, endpoint in ipairs(endpoints) do
        if endpoint then
          if endpoint.tab
            and vim.api.nvim_tabpage_is_valid(endpoint.tab)
          then
            tabs[endpoint.tab] = true
          end
          if endpoint.buf
            and vim.api.nvim_buf_is_valid(endpoint.buf)
            and type(vim.b[endpoint.buf].oculus_inspect) == "table"
          then
            buffers[endpoint.buf] = true
          end
        end
      end
    end
  end

  for id, session in pairs(sessions) do
    if discarded_sessions[session] then
      sessions[id] = nil
    end
  end

  local current_tab = vim.api.nvim_get_current_tabpage()
  local ordered_tabs = {}
  for tab in pairs(tabs) do
    if tab ~= current_tab then
      ordered_tabs[#ordered_tabs + 1] = tab
    end
  end
  if tabs[current_tab] then
    ordered_tabs[#ordered_tabs + 1] = current_tab
  end
  for _, tab in ipairs(ordered_tabs) do
    if vim.api.nvim_tabpage_is_valid(tab) then
      pcall(vim.api.nvim_tabpage_close, tab, true)
    end
  end
  for buf in pairs(buffers) do
    if vim.api.nvim_buf_is_valid(buf) then
      pcall(vim.api.nvim_buf_delete, buf, { force = true })
    end
  end
end

function M._close_inspection_workflow(group)
  if type(group) ~= "table" then
    return false
  end

  local workflow = group
  for _, candidate in ipairs(sidebar_groups) do
    if candidate.overview_patch_group == group then
      workflow = candidate
      break
    end
  end
  local workflow_groups = {}
  for index = #sidebar_groups, 1, -1 do
    local candidate = sidebar_groups[index]
    if candidate == workflow
      or candidate == workflow.overview_patch_group
    then
      candidate.discarded = true
      candidate.close_notified = true
      table.remove(sidebar_groups, index)
      workflow_groups[#workflow_groups + 1] = candidate
    end
  end
  if #workflow_groups == 0 then
    workflow_groups[1] = workflow
  end

  M._tab_navigation_source = nil
  local tabs = {}
  local inspection_buffers = {}
  local sidebar_buffers = {}
  for _, candidate in ipairs(workflow_groups) do
    if M._overview_ui and M._overview_ui.stop_agent_spinner then
      M._overview_ui.stop_agent_spinner(candidate)
    end
    for _, process in ipairs({
      candidate.overview_agent_model_process,
      candidate.overview_agent_process,
    }) do
      if process and type(process.kill) == "function" then
        pcall(process.kill, process, 15)
      end
    end
    candidate.overview_agent_model_process = nil
    candidate.overview_agent_process = nil
    candidate.overview_agent_mode = nil
    if candidate.sidebar_buf then
      sidebar_buffers[candidate.sidebar_buf] = true
    end
    for _, session in ipairs(candidate) do
      local endpoints = candidate.kind == "issue"
          and { session.issue }
        or { session.parent, session.change }
      for _, endpoint in ipairs(endpoints) do
        if endpoint then
          if endpoint.tab and vim.api.nvim_tabpage_is_valid(endpoint.tab) then
            tabs[endpoint.tab] = true
          end
          if endpoint.buf
            and vim.api.nvim_buf_is_valid(endpoint.buf)
            and type(vim.b[endpoint.buf].oculus_inspect) == "table"
          then
            inspection_buffers[endpoint.buf] = true
          end
        end
      end
    end
    close_overview_window(candidate)
    if close_inspection_sidebar then
      close_inspection_sidebar(candidate)
    end
  end

  for id, session in pairs(sessions) do
    for _, candidate in ipairs(workflow_groups) do
      for _, workflow_session in ipairs(candidate) do
        if session == workflow_session then
          sessions[id] = nil
          break
        end
      end
    end
  end

  local current_tab = vim.api.nvim_get_current_tabpage()
  local ordered_tabs = {}
  for tab in pairs(tabs) do
    if tab ~= current_tab then
      ordered_tabs[#ordered_tabs + 1] = tab
    end
  end
  if tabs[current_tab] then
    ordered_tabs[#ordered_tabs + 1] = current_tab
  end
  for _, tab in ipairs(ordered_tabs) do
    if vim.api.nvim_tabpage_is_valid(tab) then
      pcall(vim.api.nvim_tabpage_close, tab, true)
    end
  end
  for buf in pairs(sidebar_buffers) do
    if vim.api.nvim_buf_is_valid(buf) then
      pcall(vim.api.nvim_buf_delete, buf, { force = true })
    end
  end
  for buf in pairs(inspection_buffers) do
    if vim.api.nvim_buf_is_valid(buf) then
      pcall(vim.api.nvim_buf_delete, buf, { force = true })
    end
  end

  local lifecycle = workflow.inspection_lifecycle
  local callback = lifecycle and lifecycle.on_closed
  if type(callback) == "function" then
    pcall(callback)
  end
  return true
end

local function overview_window_config(config, _)
  config = vim.deepcopy(config or {})
  if type(config.width) == "number" then
    local width = math.max(1, config.width - 12)
    config.col = (tonumber(config.col) or 0)
      + math.floor((config.width - width) / 2)
    config.width = width
  end
  if type(config.height) == "number" then
    local height = math.max(1, config.height - 3)
    config.row = (tonumber(config.row) or 0)
      + math.ceil((config.height - height) / 2)
    config.height = height
  end
  config.footer = nil
  config.footer_pos = nil
  config.zindex = 70
  return config
end

M._overview_ui = {
  footer_ns = vim.api.nvim_create_namespace("oculus_inspect_overview_footer"),
  agent_spinner_ns = vim.api.nvim_create_namespace(
    "oculus_inspect_overview_agent_spinner"
  ),
  agent_spinner_frames = {
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
  },
  section_labels = {
    Title = true,
    Description = true,
    Author = true,
    ["PR number"] = true,
    ["Issue number"] = true,
    Status = true,
    Date = true,
    ["Agent explanation"] = true,
    ["Agent suggestion"] = true,
  },
}

function M._overview_ui.persistence_key(group)
  local overview = group and group.overview or {}
  local details = overview.commit_details or {}
  local repository = overview.owner and overview.repo
      and (overview.owner .. "/" .. overview.repo)
    or overview.url
    or require("oculus.agent").repository(group)
  local identifier = overview.number
    or details.sha
    or overview.sha
    or overview.url
  if type(repository) ~= "string"
    or repository == ""
    or identifier == nil
  then
    return
  end
  return table.concat({
    tostring(overview.forge or "github"):lower(),
    repository:lower(),
    tostring(overview.kind or "activity"):lower(),
    tostring(identifier):lower(),
  }, ":")
end

function M._overview_ui.restore_persisted(group)
  local key = M._overview_ui.persistence_key(group)
  local cache = group and group.inspect_overviews or nil
  local saved = key and type(cache) == "table" and cache[key] or nil
  if type(saved) ~= "table" then
    return false
  end
  if type(saved.explanation) == "string" and saved.explanation ~= "" then
    group.overview_agent_explanation = saved.explanation
    group.overview_agent_explanation_model = saved.explanation_model
    group.overview_agent_explanation_telemetry = vim.deepcopy(
      saved.explanation_telemetry
    )
  end
  if type(saved.locations) == "table" then
    group.overview_agent_locations = {}
    for _, location in ipairs(saved.locations) do
      if #group.overview_agent_locations == 3 then
        break
      end
      if type(location) == "table"
        and type(location.path) == "string"
        and location.path ~= ""
      then
        group.overview_agent_locations[#group.overview_agent_locations + 1] = {
          path = location.path,
          line = tonumber(location.line),
          reason = location.reason,
        }
      end
    end
    group.overview_agent_patch_model = saved.patch_model
    group.overview_agent_patch_telemetry = vim.deepcopy(
      saved.patch_telemetry
    )
    group.overview_agent_selected_location_index =
      #group.overview_agent_locations > 0
        and math.min(
          math.max(tonumber(saved.selected_location) or 1, 1),
          #group.overview_agent_locations
        )
      or nil
    group.overview_agent_selected_locations = {}
    for _, index in ipairs(saved.selected_locations or {}) do
      index = tonumber(index)
      if index and group.overview_agent_locations[index] then
        group.overview_agent_selected_locations[index] = true
      end
    end
  end
  if group.overview_agent_locations ~= nil then
    group.overview_agent_request_kind = "patch_locations"
    group.overview_agent_mode = "patch_locations"
  elseif group.overview_agent_explanation then
    group.overview_agent_request_kind = "explanation"
    group.overview_agent_mode = "explanation"
  end
  return group.overview_agent_mode ~= nil
end

function M._overview_ui.persist(group)
  if not group or group.persist_inspect_overviews == false then
    return false
  end
  local key = M._overview_ui.persistence_key(group)
  if not key or type(group.state_file) ~= "string"
    or group.state_file == ""
  then
    return false
  end
  local cache = group.inspect_overviews
  if type(cache) ~= "table" then
    cache = {}
    group.inspect_overviews = cache
  end
  local selected = {}
  for index, enabled in pairs(
    group.overview_agent_selected_locations or {}
  ) do
    if enabled then
      selected[#selected + 1] = index
    end
  end
  table.sort(selected)
  cache[key] = {
    explanation = group.overview_agent_explanation,
    explanation_model = group.overview_agent_explanation_model,
    explanation_telemetry = vim.deepcopy(
      group.overview_agent_explanation_telemetry
    ),
    locations = vim.deepcopy(group.overview_agent_locations),
    patch_model = group.overview_agent_patch_model,
    patch_telemetry = vim.deepcopy(group.overview_agent_patch_telemetry),
    selected_location = group.overview_agent_selected_location_index,
    selected_locations = selected,
    updated_at = os.time(),
  }
  local config = group.persistence_config or {}
  config.inspect_overviews = cache
  local ok, err = require("oculus.storage").save(
    group.state_file,
    config
  )
  if not ok then
    vim.notify(
      "Oculus could not save inspect overview data: " .. tostring(err),
      vim.log.levels.ERROR
    )
    return false
  end
  return true
end

function M._overview_ui.float_lines(overview, width)
  local lines = sidebar_overview_lines(overview, width)
  if lines[1] == "OVERVIEW" then
    table.remove(lines, 1)
    if lines[1] == "" then
      table.remove(lines, 1)
    end
  end
  return lines
end

function M._overview_ui.close_footer(group)
  if M._overview_ui.stop_close_spinner then
    M._overview_ui.stop_close_spinner(group)
  end
  local win = group.overview_footer_win
  local buf = group.overview_footer_buf
  group.overview_footer_win = nil
  group.overview_footer_buf = nil
  if win and vim.api.nvim_win_is_valid(win) then
    vim.api.nvim_win_close(win, true)
  end
  if buf and vim.api.nvim_buf_is_valid(buf) then
    vim.api.nvim_buf_delete(buf, { force = true })
  end
end

function M._overview_ui.close_queue_sidebar(group)
  local win = group.overview_queue_win
  local buf = group.overview_queue_buf
  if group.overview_queue_cursor_autocmd then
    pcall(vim.api.nvim_del_autocmd, group.overview_queue_cursor_autocmd)
    group.overview_queue_cursor_autocmd = nil
  end
  group.overview_queue_win = nil
  group.overview_queue_buf = nil
  if win and vim.api.nvim_win_is_valid(win) then
    vim.api.nvim_win_close(win, true)
  end
  if buf and vim.api.nvim_buf_is_valid(buf) then
    vim.api.nvim_buf_delete(buf, { force = true })
  end
end

function M._overview_ui.refresh_queue_sidebar(group)
  if not group then
    for _, candidate in ipairs(sidebar_groups) do
      if candidate.overview_win
        and vim.api.nvim_win_is_valid(candidate.overview_win)
      then
        M._overview_ui.refresh_queue_sidebar(candidate)
      end
    end
    return
  end
  local ok, snapshot = pcall(function()
    return require("oculus.window").inspect_queue_snapshot()
  end)
  if not ok or type(snapshot) ~= "table" then
    return
  end
  local entries = {}
  if snapshot.active then
    entries[#entries + 1] = { entry = snapshot.active, current = true }
  end
  for _, entry in ipairs(snapshot.pending or {}) do
    entries[#entries + 1] = { entry = entry, current = false }
  end
  if #entries == 0 then
    M._overview_ui.close_queue_sidebar(group)
    local overview_win = group.overview_win
    local original = group.overview_original_config
    if overview_win
      and vim.api.nvim_win_is_valid(overview_win)
      and original
    then
      vim.api.nvim_win_set_config(overview_win, vim.deepcopy(original))
    end
    if original and original.width then
      group.overview_content_width = math.max(12, original.width - 4)
      M._overview_ui.render(group)
    end
    return
  end
  local function queue_sidebar_label(entry)
    local title = type(entry.title) == "string" and vim.trim(entry.title) or ""
    if title == "" then
      local info = entry.url and parse_target_url(entry.url) or nil
      if info then
        title = (info.kind == "pull_request" and "PR #" .. tostring(info.number)
            or info.kind == "issue" and "Issue #" .. tostring(info.number)
            or "Commit " .. tostring(info.sha or ""))
          .. " · " .. tostring(info.owner or "") .. "/" .. tostring(info.repo or "")
      else
        title = tostring(entry.url or "Queued activity")
      end
    end
    return title:gsub("%s+", " ")
  end
  local overview_win = group.overview_win
  if not overview_win or not vim.api.nvim_win_is_valid(overview_win) then
    return
  end
  local current_config = vim.api.nvim_win_get_config(overview_win)
  local base_config = group.overview_original_config
      or current_config
  local total_width = tonumber(base_config.width)
      or vim.api.nvim_win_get_width(overview_win)
  local total_col = tonumber(base_config.col) or 0
  local total_height = tonumber(base_config.height)
      or vim.api.nvim_win_get_height(overview_win)
  local width = math.min(32, math.max(20, math.floor(total_width * 0.35)))
  local overview_config = vim.deepcopy(base_config)
  if current_config.width ~= overview_config.width
    or current_config.col ~= overview_config.col
  then
    vim.api.nvim_win_set_config(overview_win, overview_config)
  end
  local left_content_width = math.max(12, total_width - width - 4)
  if group.overview_content_width ~= left_content_width then
    group.overview_content_width = left_content_width
    M._overview_ui.render(group)
  end
  local col = math.max(0, math.min(
    total_col + total_width - width - 1,
    math.max(0, vim.o.columns - width - 1)
  ))
  local lines = { "QUEUE", "" }
  local current_line
  local current_index
  for entry_index, item in ipairs(entries) do
    local line = #lines + 1
    local prefix = item.current and "> " or "  "
    lines[line] = prefix .. queue_sidebar_label(item.entry)
    if item.current then
      current_line = line
      current_index = entry_index
    end
  end
  local selected_index = math.min(
    math.max(group.overview_queue_cursor or current_index or 1, 1),
    #entries
  )
  group.overview_queue_cursor = selected_index
  local buf = group.overview_queue_buf
  if not buf or not vim.api.nvim_buf_is_valid(buf) then
    buf = vim.api.nvim_create_buf(false, true)
    group.overview_queue_buf = buf
    vim.bo[buf].buftype = "nofile"
    vim.bo[buf].bufhidden = "wipe"
    vim.bo[buf].swapfile = false
    vim.bo[buf].filetype = "oculus-inspect-overview-queue"
  end
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.api.nvim_buf_clear_namespace(buf, sidebar_ns, 0, -1)
  if current_line then
    vim.api.nvim_buf_set_extmark(buf, sidebar_ns, current_line - 1, 0, {
      end_col = #(lines[current_line] or ""),
      hl_group = "OculusInspectQueueCurrent",
      priority = 110,
    })
  end
  local config = {
    relative = "editor",
    width = width,
    height = total_height,
    row = tonumber(base_config.row) or 0,
    col = col,
    style = "minimal",
    border = { "", "", "", "", "", "", "", "│" },
    zindex = (tonumber(overview_config.zindex) or 70) + 1,
  }
  local win = group.overview_queue_win
  if win and vim.api.nvim_win_is_valid(win) then
    vim.api.nvim_win_set_config(win, config)
  else
    local focus = vim.api.nvim_get_current_win()
    win = vim.api.nvim_open_win(buf, true, config)
    group.overview_queue_win = win
    if focus and vim.api.nvim_win_is_valid(focus) then
      vim.api.nvim_set_current_win(focus)
    end
  end
  vim.wo[win].wrap = false
  vim.wo[win].number = false
  vim.wo[win].relativenumber = false
  vim.wo[win].cursorline = false
  vim.wo[win].signcolumn = "no"
  vim.wo[win].winhighlight = table.concat({
    "Normal:OculusNormal",
    "NormalFloat:OculusNormal",
    "FloatBorder:WinSeparator",
  }, ",")
  require("oculus.window").apply_window_highlights(
    win,
    group.overview_highlight_source_win
  )
  if not group.overview_queue_cursor_autocmd then
    group.overview_queue_cursor_autocmd = vim.api.nvim_create_autocmd(
      "CursorMoved",
      {
        group = sync_group,
        buffer = buf,
        callback = function()
          if not group.overview_queue_win
            or not vim.api.nvim_win_is_valid(group.overview_queue_win)
            or vim.api.nvim_get_current_win() ~= group.overview_queue_win
          then
            return
          end
          local line = vim.api.nvim_win_get_cursor(group.overview_queue_win)[1]
          if line > 2 then
            require("oculus.window").select_inspect_queue(line - 2)
          end
        end,
      }
    )
  end
end

function M._overview_ui.move_queue_cursor(group, direction)
  if not group.overview_queue_win
    or not vim.api.nvim_win_is_valid(group.overview_queue_win)
    or not group.overview_queue_buf
    or not vim.api.nvim_buf_is_valid(group.overview_queue_buf)
  then
    return false
  end
  local count = math.max(0,
    vim.api.nvim_buf_line_count(group.overview_queue_buf) - 2)
  if count == 0 then
    return false
  end
  local index = (group.overview_queue_cursor or 1) + (direction < 0 and -1 or 1)
  if index < 1 then
    index = count
  elseif index > count then
    index = 1
  end
  group.overview_queue_cursor = index
  M._overview_ui.refresh_queue_sidebar(group)
  return true
end

function M._overview_ui.render_footer(group)
  local overview_win = group.overview_win
  if not overview_win or not vim.api.nvim_win_is_valid(overview_win) then
    return
  end
  local overview_config = vim.api.nvim_win_get_config(overview_win)
  local width = vim.api.nvim_win_get_width(overview_win)
  local height = vim.api.nvim_win_get_height(overview_win)
  local config = {
    relative = "editor",
    width = width,
    height = 2,
    row = (tonumber(overview_config.row) or 0) + height - 1,
    col = (tonumber(overview_config.col) or 0) + 1,
    style = "minimal",
    focusable = false,
    zindex = (tonumber(overview_config.zindex) or 70) + 1,
  }
  local buf = group.overview_footer_buf
  if not buf or not vim.api.nvim_buf_is_valid(buf) then
    buf = vim.api.nvim_create_buf(false, true)
    group.overview_footer_buf = buf
    vim.bo[buf].buftype = "nofile"
    vim.bo[buf].bufhidden = "wipe"
    vim.bo[buf].swapfile = false
    vim.bo[buf].filetype = "oculus-inspect-overview-footer"
    vim.b[buf].oculus_inspect_overview_footer = true
  end
  local issue_patches = require("oculus.agent").needs_patch_locations(group)
  local close_spinner = group.overview_close_spinner_frame
      and M._overview_ui.agent_spinner_frames[
        group.overview_close_spinner_frame
      ]
    or nil
  local close_command = close_spinner
      and ("c close " .. close_spinner)
    or "c close"
  local commands = issue_patches
      and "  p path   e explain   b browser   " .. close_command
    or "  e explain   b browser   " .. close_command
  local close_spinner_col = close_spinner
      and (#commands - #close_spinner)
    or nil
  if #(group.overview_agent_locations or {}) > 0
    and group.overview_agent_mode == "patch_locations"
  then
    local path_commands = "<Space> toggle   <CR> open paths"
    local padding = math.max(
      1,
      width
        - 2
        - vim.fn.strdisplaywidth(commands)
        - vim.fn.strdisplaywidth(path_commands)
    )
    commands = commands
      .. string.rep(" ", padding)
      .. path_commands
  end
  local footer_lines = {
    "  " .. string.rep("─", math.max(1, width - 4)),
    commands,
  }
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, footer_lines)
  vim.bo[buf].modifiable = false
  vim.api.nvim_buf_clear_namespace(
    buf,
    M._overview_ui.footer_ns,
    0,
    -1
  )
  vim.api.nvim_buf_set_extmark(
    buf,
    M._overview_ui.footer_ns,
    0,
    2,
    {
      end_col = #footer_lines[1],
      hl_group = "WinSeparator",
      priority = 100,
    }
  )
  vim.api.nvim_buf_set_extmark(
    buf,
    M._overview_ui.footer_ns,
    1,
    2,
    {
      end_col = #footer_lines[2],
      hl_group = "Comment",
      priority = 100,
    }
  )
  if close_spinner_col then
    vim.api.nvim_buf_set_extmark(
      buf,
      M._overview_ui.footer_ns,
      1,
      close_spinner_col,
      {
        end_col = close_spinner_col + #close_spinner,
        hl_group = "DiagnosticInfo",
        priority = 101,
      }
    )
  end

  local footer_win = group.overview_footer_win
  if footer_win and vim.api.nvim_win_is_valid(footer_win) then
    vim.api.nvim_win_set_config(footer_win, config)
  else
    footer_win = vim.api.nvim_open_win(buf, false, config)
    group.overview_footer_win = footer_win
  end
  vim.wo[footer_win].wrap = false
  vim.wo[footer_win].cursorline = false
  vim.wo[footer_win].number = false
  vim.wo[footer_win].relativenumber = false
  vim.wo[footer_win].signcolumn = "no"
  vim.wo[footer_win].winhighlight = table.concat({
    "Normal:OculusNormal",
    "NormalFloat:OculusNormal",
  }, ",")
  require("oculus.window").apply_window_highlights(
    footer_win,
    group.overview_highlight_source_win
  )
end

function M._overview_ui.stop_close_spinner(group)
  local timer = group.overview_close_spinner_timer
  group.overview_close_spinner_timer = nil
  group.overview_close_spinner_frame = nil
  if timer then
    pcall(timer.stop, timer)
    if not timer:is_closing() then
      timer:close()
    end
  end
end

function M._overview_ui.start_close_spinner(group)
  if not overview_window_is_open(group) then
    return
  end
  M._overview_ui.stop_close_spinner(group)
  group.overview_close_spinner_frame = 1
  M._overview_ui.render_footer(group)
  local timer = vim.uv.new_timer()
  if not timer then
    return
  end
  group.overview_close_spinner_timer = timer
  timer:start(80, 80, vim.schedule_wrap(function()
    if group.overview_close_spinner_timer ~= timer
      or not overview_window_is_open(group)
    then
      return
    end
    group.overview_close_spinner_frame = (
      group.overview_close_spinner_frame
        % #M._overview_ui.agent_spinner_frames
    ) + 1
    M._overview_ui.render_footer(group)
  end))
end

function M._overview_ui.content_height(group)
  local win = group.overview_win
  if not win or not vim.api.nvim_win_is_valid(win) then
    return 1
  end
  local height = vim.api.nvim_win_get_height(win)
  local footer = group.overview_footer_win
  if footer and vim.api.nvim_win_is_valid(footer) then
    height = height - vim.api.nvim_win_get_height(footer)
  end
  return math.max(1, height)
end

function M._overview_ui.clamp_scroll(group)
  local win = group.overview_win
  local buf = group.overview_buf
  if not win
    or not buf
    or not vim.api.nvim_win_is_valid(win)
    or not vim.api.nvim_buf_is_valid(buf)
  then
    return false
  end
  local line_count = vim.api.nvim_buf_line_count(buf)
  local height = M._overview_ui.content_height(group)
  local max_topline = math.max(1, line_count - height + 2)
  local changed = false
  vim.api.nvim_win_call(win, function()
    local view = vim.fn.winsaveview()
    local topline = math.max(1, math.min(max_topline, view.topline))
    if topline == view.topline then
      return
    end
    view.topline = topline
    view.topfill = 0
    vim.fn.winrestview(view)
    changed = true
  end)
  return changed
end

function M._overview_ui.schedule_highlight_refresh(group)
  vim.schedule(function()
    if not overview_window_is_open(group) then
      return
    end
    require("oculus.window").apply_window_highlights(
      group.overview_win,
      group.overview_highlight_source_win
    )
  end)
end

function M._overview_ui.render(group)
  local buf = group.overview_buf
  if not buf or not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  local lines = M._overview_ui.float_lines(
    group.overview,
    group.overview_content_width or 28
  )
  group.overview_agent_model_lines = nil
  group.overview_agent_heading_line = nil
  group.overview_agent_location_lines = nil
  group.overview_agent_location_heading_line = nil
  local function append_active_state(kind)
    if group.overview_agent_request_kind ~= kind then
      return false
    end
    if group.overview_agent_mode == "models" then
      local targets = {}
      for _, model in ipairs(group.overview_agent_models or {}) do
        lines[#lines + 1] = ("  %s  %s"):format(
          model.display_name,
          model.id
        )
        targets[#lines] = model
      end
      group.overview_agent_model_lines = targets
    elseif group.overview_agent_mode == "error" then
      append_sidebar_text(
        lines,
        group.overview_agent_error or "Agent request failed.",
        group.overview_content_width or 28,
        "  "
      )
    end
    return group.overview_agent_mode == "models"
      or group.overview_agent_mode == "error"
      or group.overview_agent_mode == "generating"
      or group.overview_agent_mode == "loading_models"
  end

  local function append_explanation()
    local active = group.overview_agent_request_kind == "explanation"
      and group.overview_agent_mode ~= nil
    if not active and not group.overview_agent_explanation then
      return
    end
    lines[#lines + 1] = ""
    local heading = "  Agent explanation"
    if group.overview_agent_explanation_model
    then
      heading = heading
        .. " ("
        .. tostring(group.overview_agent_explanation_model)
        .. ")"
    end
    lines[#lines + 1] = heading
    if active then
      group.overview_agent_heading_line = #lines
    end
    if not append_active_state("explanation")
      and group.overview_agent_explanation
    then
      append_sidebar_text(
        lines,
        group.overview_agent_explanation,
        group.overview_content_width or 28,
        "  "
      )
    end
  end

  local function append_patch_locations()
    local active = group.overview_agent_request_kind == "patch_locations"
      and group.overview_agent_mode ~= nil
    if not active and group.overview_agent_locations == nil then
      return
    end
    lines[#lines + 1] = ""
    local heading = "  Agent suggestion"
    if group.overview_agent_patch_model then
      heading = heading
        .. " ("
        .. tostring(group.overview_agent_patch_model)
        .. ")"
    end
    lines[#lines + 1] = heading
    group.overview_agent_location_heading_line = #lines
    if active then
      group.overview_agent_heading_line = #lines
    end
    if append_active_state("patch_locations") then
      return
    end
    local locations = group.overview_agent_locations or {}
    if #locations == 0 then
      lines[#lines + 1] = "  No likely locations identified."
      return
    end
    group.overview_agent_location_lines = {}
    group.overview_agent_selected_location_index = math.min(
      math.max(group.overview_agent_selected_location_index or 1, 1),
      #locations
    )
    for index, location in ipairs(locations) do
      local location_line = #lines + 1
      local display_path = location.path
      if location.line then
        display_path = display_path .. ":" .. tostring(location.line)
      end
      local selected_locations =
        group.overview_agent_selected_locations or {}
      local marker = selected_locations[index] and "[x]" or "[ ]"
      append_sidebar_text(
        lines,
        ("%s %d. %s"):format(marker, index, display_path),
        group.overview_content_width or 28,
        "  "
      )
      group.overview_agent_location_lines[location_line] = {
        index = index,
        location = location,
      }
      if location.reason then
        append_sidebar_text(
          lines,
          location.reason,
          group.overview_content_width or 28,
          "     "
        )
      end
      if index < #locations then
        lines[#lines + 1] = ""
      end
    end
  end

  append_explanation()
  append_patch_locations()
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.api.nvim_buf_clear_namespace(buf, sidebar_ns, 0, -1)
  vim.api.nvim_buf_clear_namespace(
    buf,
    M._overview_ui.footer_ns,
    0,
    -1
  )
  vim.api.nvim_buf_clear_namespace(
    buf,
    M._overview_ui.agent_spinner_ns,
    0,
    -1
  )
  for index, line in ipairs(lines) do
    local label = line:match("^  (.-)%s*$")
    if M._overview_ui.section_labels[label]
      or (label and label:match("^Agent explanation"))
      or (label and label:match("^Agent suggestion"))
    then
      vim.api.nvim_buf_set_extmark(buf, sidebar_ns, index - 1, 2, {
        end_col = #line,
        hl_group = "OculusInspectOverviewSection",
        priority = 100,
      })
    end
  end
  local selected = group.overview_agent_selected_line
  if group.overview_agent_mode == "models"
    and selected
    and group.overview_agent_model_lines
    and group.overview_agent_model_lines[selected]
  then
    vim.api.nvim_buf_set_extmark(buf, sidebar_ns, selected - 1, 2, {
      end_col = #(lines[selected] or ""),
      hl_group = "OculusInspectAgentModelSelected",
      hl_mode = "combine",
      priority = 90,
    })
  end
  if group.overview_agent_selected_location_index
    and group.overview_agent_mode == "patch_locations"
  then
    for line, target in pairs(
      group.overview_agent_location_lines or {}
    ) do
      if target.index == group.overview_agent_selected_location_index then
        vim.api.nvim_buf_set_extmark(buf, sidebar_ns, line - 1, 2, {
          end_col = #(lines[line] or ""),
          hl_group = "OculusInspectAgentModelSelected",
          hl_mode = "combine",
          priority = 90,
        })
        break
      end
    end
  end
  if group.overview_agent_mode == "generating"
    or group.overview_agent_mode == "loading_models"
  then
    M._overview_ui.draw_agent_spinner(group)
  end
  if overview_window_is_open(group)
    and vim.api.nvim_get_current_win() == group.overview_win
  then
    hide_overview_cursor(group)
  end
  if overview_window_is_open(group) then
    M._overview_ui.render_footer(group)
  end
  return lines
end

function M._overview_ui.draw_agent_spinner(group)
  local buf = group.overview_buf
  local line = group.overview_agent_heading_line
  if (group.overview_agent_mode ~= "generating"
      and group.overview_agent_mode ~= "loading_models")
    or not buf
    or not line
    or not vim.api.nvim_buf_is_valid(buf)
  then
    return
  end
  vim.api.nvim_buf_clear_namespace(
    buf,
    M._overview_ui.agent_spinner_ns,
    0,
    -1
  )
  local frames = M._overview_ui.agent_spinner_frames
  local frame = frames[group.overview_agent_spinner_frame or 1]
  vim.api.nvim_buf_set_extmark(
    buf,
    M._overview_ui.agent_spinner_ns,
    line - 1,
    0,
    {
      virt_text = { { " " .. frame, "DiagnosticInfo" } },
      virt_text_pos = "eol",
      hl_mode = "combine",
    }
  )
end

function M._overview_ui.stop_agent_spinner(group)
  local timer = group.overview_agent_spinner_timer
  group.overview_agent_spinner_timer = nil
  group.overview_agent_spinner_frame = nil
  if timer then
    pcall(timer.stop, timer)
    if not timer:is_closing() then
      timer:close()
    end
  end
  local buf = group.overview_buf
  if buf and vim.api.nvim_buf_is_valid(buf) then
    vim.api.nvim_buf_clear_namespace(
      buf,
      M._overview_ui.agent_spinner_ns,
      0,
      -1
    )
  end
end

function M._overview_ui.start_agent_spinner(group)
  M._overview_ui.stop_agent_spinner(group)
  group.overview_agent_spinner_frame = 1
  M._overview_ui.draw_agent_spinner(group)
  local timer = vim.uv.new_timer()
  if not timer then
    return
  end
  group.overview_agent_spinner_timer = timer
  timer:start(80, 80, vim.schedule_wrap(function()
    if group.overview_agent_spinner_timer ~= timer
      or (group.overview_agent_mode ~= "generating"
        and group.overview_agent_mode ~= "loading_models")
    then
      return
    end
    group.overview_agent_spinner_frame =
      (group.overview_agent_spinner_frame
        % #M._overview_ui.agent_spinner_frames) + 1
    M._overview_ui.draw_agent_spinner(group)
  end))
end

function M._overview_ui.scroll_to_bottom(group)
  local win = group.overview_win
  local buf = group.overview_buf
  if not win
    or not buf
    or not vim.api.nvim_win_is_valid(win)
    or not vim.api.nvim_buf_is_valid(buf)
  then
    return
  end
  local line_count = vim.api.nvim_buf_line_count(buf)
  local height = M._overview_ui.content_height(group)
  local topline = math.max(1, line_count - height + 2)
  vim.api.nvim_win_set_cursor(win, { line_count, 0 })
  vim.api.nvim_win_call(win, function()
    local view = vim.fn.winsaveview()
    view.topline = topline
    vim.fn.winrestview(view)
  end)
end

function M._overview_ui.close_agent_window(group, return_to_overview)
  M._overview_ui.stop_agent_spinner(group)
  group.overview_agent_model_lines = nil
  if return_to_overview and overview_window_is_open(group) then
    vim.api.nvim_set_current_win(group.overview_win)
  end
end

function M._overview_ui.restore_model_selection(group)
  if group.overview_agent_mode ~= "models" then
    return false
  end
  local function restore(targets, selected_line)
    if targets and selected_line and targets[selected_line] then
      return selected_line
    end
    local first
    for line in pairs(targets or {}) do
      if not first or line < first then
        first = line
      end
    end
    return first
  end

  local changed = false
  if group.overview_agent_mode == "models" then
    local selected = restore(
      group.overview_agent_model_lines,
      group.overview_agent_selected_line
    )
    if selected ~= group.overview_agent_selected_line then
      group.overview_agent_selected_line = selected
      changed = true
    end
  end
  return changed
end

function M._overview_ui.render_models(group, models, err)
  if group.overview_agent_mode ~= "loading_models" then
    return
  end
  M._overview_ui.stop_agent_spinner(group)
  group.overview_agent_model_process = nil
  if err then
    group.overview_agent_mode = "error"
    group.overview_agent_error = "Could not load Codex models: "
      .. tostring(err)
    M._overview_ui.render(group)
    M._overview_ui.scroll_to_bottom(group)
    return
  end
  group.overview_agent_mode = "models"
  group.overview_agent_models = models or {}
  M._overview_ui.render(group)
  local model_lines = {}
  for line in pairs(group.overview_agent_model_lines or {}) do
    model_lines[#model_lines + 1] = line
  end
  table.sort(model_lines)
  group.overview_agent_selected_line = model_lines[1]
  M._overview_ui.render(group)
  M._overview_ui.scroll_to_bottom(group)
  if group.overview_agent_selected_line
    and overview_window_is_open(group)
  then
    vim.api.nvim_win_set_cursor(group.overview_win, {
      group.overview_agent_selected_line,
      0,
    })
  end
end

function M._overview_ui.select_agent_model(group)
  local model = group.overview_agent_model_lines
    and group.overview_agent_model_lines[group.overview_agent_selected_line]
  if model then
    if group.overview_agent_request_kind == "patch_locations" then
      M._overview_ui.open_patch_locations(group, model)
    else
      M._overview_ui.open_explanation(group, model)
    end
  end
end

function M._overview_ui.move_model_cursor(group, direction)
  local targets = group.overview_agent_model_lines or {}
  if group.overview_agent_mode ~= "models" then
    return
  end
  local lines = {}
  for line in pairs(targets) do
    lines[#lines + 1] = line
  end
  table.sort(lines)
  if #lines == 0 then
    return
  end
  local current = group.overview_agent_selected_line or lines[1]
  local current_index = 1
  for index, line in ipairs(lines) do
    if line >= current then
      current_index = index
      break
    end
  end
  local next_index = ((current_index + direction - 1) % #lines) + 1
  group.overview_agent_selected_line = lines[next_index]
  M._overview_ui.render(group)
  if overview_window_is_open(group) then
    vim.api.nvim_win_set_cursor(group.overview_win, {
      group.overview_agent_selected_line,
      0,
    })
  end
end

function M._overview_ui.selected_patch_location(group)
  local selected = group.overview_agent_selected_location_index
  for line, target in pairs(
    group.overview_agent_location_lines or {}
  ) do
    if target.index == selected then
      return target.location, line
    end
  end
end

function M._overview_ui.focus_patch_locations(group)
  if group.overview_agent_mode == "patch_locations"
    or #(group.overview_agent_locations or {}) == 0
  then
    return false
  end
  group.overview_agent_request_kind = "patch_locations"
  group.overview_agent_mode = "patch_locations"
  group.overview_agent_selected_location_index = math.min(
    math.max(group.overview_agent_selected_location_index or 1, 1),
    #group.overview_agent_locations
  )
  M._overview_ui.render(group)
  local _, line = M._overview_ui.selected_patch_location(group)
  if line and overview_window_is_open(group) then
    vim.api.nvim_set_current_win(group.overview_win)
    vim.api.nvim_win_set_cursor(group.overview_win, { line, 0 })
  end
  return true
end

function M._overview_ui.unfocus_patch_locations(group)
  if group.overview_agent_mode ~= "patch_locations"
    or group.overview_agent_request_kind ~= "patch_locations"
  then
    return false
  end
  group.overview_agent_mode = nil
  M._overview_ui.render(group)
  if overview_window_is_open(group) then
    vim.api.nvim_set_current_win(group.overview_win)
    hide_overview_cursor(group)
  end
  return true
end

function M._overview_ui.toggle_patch_locations_focus(group)
  if #(group.overview_agent_locations or {}) == 0 then
    return false
  end
  if group.overview_agent_mode == "patch_locations"
    and group.overview_agent_request_kind == "patch_locations"
  then
    M._overview_ui.unfocus_patch_locations(group)
  else
    M._overview_ui.focus_patch_locations(group)
  end
  return true
end

function M._overview_ui.move_location_cursor(group, direction)
  local locations = group.overview_agent_locations or {}
  if group.overview_agent_mode ~= "patch_locations"
    or group.overview_agent_request_kind ~= "patch_locations"
    or #locations == 0
  then
    return false
  end
  local current = group.overview_agent_selected_location_index or 1
  group.overview_agent_selected_location_index =
    ((current + direction - 1) % #locations) + 1
  M._overview_ui.render(group)
  local _, line = M._overview_ui.selected_patch_location(group)
  if line and overview_window_is_open(group) then
    vim.api.nvim_win_set_cursor(group.overview_win, { line, 0 })
  end
  return true
end

function M._overview_ui.toggle_patch_location(group)
  local locations = group.overview_agent_locations or {}
  if group.overview_agent_mode ~= "patch_locations"
    or group.overview_agent_request_kind ~= "patch_locations"
  then
    return false
  end
  local index = group.overview_agent_selected_location_index
  if not index or not locations[index] then
    return false
  end
  group.overview_agent_selected_locations =
    group.overview_agent_selected_locations or {}
  group.overview_agent_selected_locations[index] =
    not group.overview_agent_selected_locations[index]
      and true
    or nil
  require("oculus.telemetry").record(
    "oculus.inspect.patch_location.toggle",
    {
      ["gen_ai.workflow.name"] = "oculus.inspect.patch_locations",
      ["oculus.patch_location.index"] = index,
      ["oculus.patch_location.selected"] =
        group.overview_agent_selected_locations[index] == true,
    },
    group.overview_agent_patch_telemetry
  )
  M._overview_ui.persist(group)
  M._overview_ui.render(group)
  local _, line = M._overview_ui.selected_patch_location(group)
  if line and overview_window_is_open(group) then
    vim.api.nvim_win_set_cursor(group.overview_win, { line, 0 })
  end
  return true
end

function M._overview_ui.patch_location_path(group, location)
  local repository = require("oculus.agent").repository(group)
  if type(repository) ~= "string" or repository == "" then
    return nil, nil, "local repository information is unavailable"
  end
  local path = type(location) == "table" and location.path or nil
  if type(path) ~= "string" or vim.trim(path) == "" then
    return nil, nil, "this patch location has no path"
  end
  repository = vim.fs.normalize(repository)
  path = vim.trim(path):gsub("\\", "/"):gsub("^/+", "")
  local folder = vim.fs.basename(repository)
  if path:lower() == folder:lower() then
    path = ""
  elseif path:sub(1, #folder + 1):lower()
      == (folder .. "/"):lower()
  then
    path = path:sub(#folder + 2)
  end
  local absolute = vim.fs.normalize(vim.fs.joinpath(repository, path))
  local relative = relative_path(repository, absolute)
  if not relative or relative == "" then
    return nil, nil, "the selected path is outside the repository"
  end
  return absolute, relative
end

function M._overview_ui.open_patch_location(group)
  if group.overview_agent_mode ~= "patch_locations"
    or group.overview_agent_request_kind ~= "patch_locations"
  then
    return false
  end
  local locations = group.overview_agent_locations or {}
  local selected = group.overview_agent_selected_locations or {}
  local targets = {}
  for index, location in ipairs(locations) do
    if selected[index] then
      targets[#targets + 1] = location
    end
  end
  if #targets == 0 then
    return false
  end
  local code_options = group.overview_code_window_options or {}
  local repository = require("oculus.agent").repository(group)
  local opened = {}
  for _, location in ipairs(targets) do
    local absolute, relative, path_err =
      M._overview_ui.patch_location_path(group, location)
    local stat = absolute and vim.uv.fs_stat(absolute) or nil
    if not absolute then
      vim.notify("Oculus: " .. tostring(path_err), vim.log.levels.WARN)
    elseif stat and stat.type == "directory" then
      vim.notify(
        "Oculus: the selected patch location is a directory",
        vim.log.levels.WARN
      )
    else
      local ok, open_err = pcall(
        vim.cmd,
        "tabedit " .. vim.fn.fnameescape(absolute)
      )
      if not ok then
        vim.notify(
          "Oculus: could not open patch location: " .. tostring(open_err),
          vim.log.levels.ERROR
        )
      else
        vim.cmd("tcd " .. vim.fn.fnameescape(repository))
        vim.bo.modifiable = true
        vim.bo.readonly = false
        local patch_win = vim.api.nvim_get_current_win()
        local patch_buf = vim.api.nvim_get_current_buf()
        for option, value in pairs(code_options) do
          if option ~= "highlight_namespace" then
            pcall(function()
              vim.wo[patch_win][option] = value
            end)
          end
        end
        vim.wo[patch_win].cursorline = true
        vim.wo[patch_win].cursorlineopt = "line"
        vim.wo[patch_win].statusline = ""
        vim.wo[patch_win].winfixbuf = false
        local oculus_namespace = vim.api.nvim_get_namespaces()
          .oculus_window_highlights
        if oculus_namespace
          and vim.api.nvim_get_hl_ns({ winid = patch_win })
            == oculus_namespace
        then
          vim.api.nvim_win_set_hl_ns(
            patch_win,
            code_options.highlight_namespace or 0
          )
        end
        M._use_native_cursorline_highlighting(patch_win)
        local line_count = vim.api.nvim_buf_line_count(patch_buf)
        local target_line = math.max(
          1,
          math.min(tonumber(location.line) or 1, line_count)
        )
        local target_text = vim.api.nvim_buf_get_lines(
          patch_buf,
          target_line - 1,
          target_line,
          false
        )[1] or ""
        local target_column = #(target_text:match("^%s*") or "")
        vim.api.nvim_win_set_cursor(
          patch_win,
          { target_line, target_column }
        )
        if target_line > 10 then
          vim.api.nvim_win_call(patch_win, function()
            local keys = vim.api.nvim_replace_termcodes(
              "zt10<C-y>",
              true,
              false,
              true
            )
            vim.cmd("normal! " .. keys)
          end)
        end
        opened[#opened + 1] = {
          tab = vim.api.nvim_get_current_tabpage(),
          win = patch_win,
          buf = patch_buf,
          path = relative:gsub("\\", "/"),
          line = target_line,
          location = location,
        }
      end
    end
  end
  if #opened == 0 then
    require("oculus.telemetry").record(
      "oculus.inspect.patch_locations.open",
      {
        ["gen_ai.workflow.name"] = "oculus.inspect.patch_locations",
        ["oculus.patch_locations.requested"] = #targets,
        ["oculus.patch_locations.opened"] = 0,
      },
      group.overview_agent_patch_telemetry,
      "no_location_opened"
    )
    return false
  end
  require("oculus.telemetry").record(
    "oculus.inspect.patch_locations.open",
    {
      ["gen_ai.workflow.name"] = "oculus.inspect.patch_locations",
      ["oculus.patch_locations.requested"] = #targets,
      ["oculus.patch_locations.opened"] = #opened,
    },
    group.overview_agent_patch_telemetry,
    #opened < #targets and "partial_open" or nil
  )
  group.overview_patch_tabs = group.overview_patch_tabs or {}
  for _, patch in ipairs(opened) do
    group.overview_patch_tabs[#group.overview_patch_tabs + 1] = patch
  end
  group.overview_agent_mode = nil
  group.overview_return = nil
  close_overview_window(group)
  local patch_group = M._overview_ui.prepare_patch_sidebar(group, opened)
  group.overview_patch_group = patch_group
  local first = opened[1]
  if vim.api.nvim_tabpage_is_valid(first.tab)
    and vim.api.nvim_win_is_valid(first.win)
  then
    vim.api.nvim_set_current_tabpage(first.tab)
    vim.api.nvim_set_current_win(first.win)
  end
  return true
end

function M._overview_ui.open_model_picker(group, request_kind)
  if not overview_window_is_open(group) then
    return
  end
  M._overview_ui.stop_agent_spinner(group)
  group.overview_agent_request_kind = request_kind or "explanation"
  group.overview_agent_mode = "loading_models"
  group.overview_agent_error = nil
  group.overview_agent_models = nil
  group.overview_agent_model_lines = nil
  group.overview_agent_selected_line = nil
  if group.overview_agent_request_kind == "patch_locations" then
    group.overview_agent_patch_model = nil
    group.overview_agent_selected_locations = nil
  else
    group.overview_agent_explanation_model = nil
  end
  M._overview_ui.render(group)
  M._overview_ui.scroll_to_bottom(group)
  M._overview_ui.start_agent_spinner(group)
  local responded = false
  local process, err = require("oculus.agent").models(function(models, load_err)
    responded = true
    M._overview_ui.render_models(group, models, load_err)
  end)
  if not process then
    M._overview_ui.render_models(group, nil, err)
  elseif not responded then
    group.overview_agent_model_process = process
  end
end

function M._overview_ui.open_browser(group)
  local url = group.overview and group.overview.url
  if type(url) ~= "string" or url == "" then
    vim.notify("Oculus: this item has no browser URL", vim.log.levels.WARN)
    return false
  end
  local ok, err = browser.open(url, group.browser_config or {})
  if not ok and err then
    vim.notify("Oculus: " .. tostring(err), vim.log.levels.ERROR)
    return false
  end
  return true
end

function M._overview_ui.render_explanation(
  group,
  model,
  text,
  err
)
  if group.overview_agent_mode ~= "generating"
    or group.overview_agent_request_kind ~= "explanation"
  then
    return
  end
  M._overview_ui.stop_agent_spinner(group)
  group.overview_agent_explanation_model = model
  if text then
    group.overview_agent_mode = "explanation"
    group.overview_agent_explanation = text
    M._overview_ui.persist(group)
  else
    group.overview_agent_mode = "error"
    group.overview_agent_error = "Generation failed: " .. tostring(err)
  end
  M._overview_ui.render(group)
  M._overview_ui.scroll_to_bottom(group)
end

function M._overview_ui.agent_telemetry_attributes(group)
  local overview = group and group.overview or {}
  local changed_files = {}
  local patch_count = 0
  local patch_bytes = 0
  for _, session in ipairs(group or {}) do
    local file = session.change_file or session.parent_file
    if type(file) == "string" and file ~= "" then
      changed_files[file] = true
    end
    if type(session.patch) == "string" and session.patch ~= "" then
      patch_count = patch_count + 1
      patch_bytes = patch_bytes + #session.patch
    end
  end
  local changed_file_count = vim.tbl_count(changed_files)
  return {
    ["oculus.activity.kind"] = overview.kind
      or (group and group.kind)
      or "unknown",
    ["oculus.activity.forge"] = overview.forge or "unknown",
    ["oculus.activity.changed_file_count"] = changed_file_count,
    ["oculus.activity.patch_count"] = patch_count,
    ["oculus.activity.patch_bytes"] = patch_bytes,
    ["oculus.activity.has_file_changes"] = changed_file_count > 0,
  }
end

function M._overview_ui.open_explanation(group, model)
  local agent = require("oculus.agent")
  local repository = agent.repository(group)
  group.overview_agent_request_kind = "explanation"
  group.overview_agent_mode = "generating"
  group.overview_agent_models = nil
  group.overview_agent_model_lines = nil
  group.overview_agent_selected_line = nil
  group.overview_agent_explanation_model = model.id
  M._overview_ui.render(group)
  M._overview_ui.scroll_to_bottom(group)
  M._overview_ui.start_agent_spinner(group)
  if not repository then
    M._overview_ui.render_explanation(
      group,
      model.id,
      nil,
      "local repository information is unavailable"
    )
    return
  end
  group.overview_agent_pending = true
  local finished = false
  local function finish(explanation, err, metadata)
    if finished then
      return
    end
    finished = true
    group.overview_agent_pending = nil
    group.overview_agent_process = nil
    local normalized = agent.normalize_result(explanation, false, repository)
    local actual_model = metadata and metadata.model or model.id
    local telemetry_context = metadata and metadata.telemetry or nil
    group.overview_agent_explanation = normalized
    group.overview_agent_explanation_model = actual_model
    group.overview_agent_explanation_telemetry = telemetry_context
    require("oculus.telemetry").record(
      "oculus.inspect.agent_result.process",
      {
        ["gen_ai.workflow.name"] = "oculus.inspect.explanation",
        ["oculus.agent.result.valid"] = normalized ~= nil,
      },
      telemetry_context,
      normalized and nil or "invalid_output"
    )
    M._overview_ui.render_explanation(
      group,
      actual_model,
      normalized,
      err or "Codex returned no explanation"
    )
  end
  local process, err = agent.explain({
    cwd = repository,
    prompt = agent.prompt(group),
    model = model.id,
    workflow = "oculus.inspect.explanation",
    output_type = "text",
    telemetry_attributes = M._overview_ui.agent_telemetry_attributes(group),
  }, finish)
  if not process and not finished then
    finish(nil, err)
  elseif not finished then
    group.overview_agent_process = process
  end
end

function M._overview_ui.render_patch_locations(
  group,
  model,
  locations,
  err
)
  if group.overview_agent_mode ~= "generating"
    or group.overview_agent_request_kind ~= "patch_locations"
  then
    return
  end
  M._overview_ui.stop_agent_spinner(group)
  group.overview_agent_patch_model = model
  if locations then
    group.overview_agent_mode = "patch_locations"
    group.overview_agent_locations = {}
    for index = 1, math.min(3, #locations) do
      group.overview_agent_locations[index] = locations[index]
    end
    group.overview_agent_selected_location_index =
      #group.overview_agent_locations > 0 and 1 or nil
    group.overview_agent_selected_locations = {}
    M._overview_ui.persist(group)
  else
    group.overview_agent_mode = "error"
    group.overview_agent_error = "Generation failed: " .. tostring(err)
  end
  M._overview_ui.render(group)
  M._overview_ui.scroll_to_bottom(group)
end

function M._overview_ui.open_patch_locations(group, model)
  local agent = require("oculus.agent")
  local repository = agent.repository(group)
  group.overview_agent_request_kind = "patch_locations"
  group.overview_agent_mode = "generating"
  group.overview_agent_models = nil
  group.overview_agent_model_lines = nil
  group.overview_agent_selected_line = nil
  group.overview_agent_patch_model = model.id
  M._overview_ui.render(group)
  M._overview_ui.scroll_to_bottom(group)
  M._overview_ui.start_agent_spinner(group)
  if not repository then
    M._overview_ui.render_patch_locations(
      group,
      model.id,
      nil,
      "local repository information is unavailable"
    )
    return
  end
  group.overview_agent_pending = true
  local finished = false
  local function finish(response, err, metadata)
    if finished then
      return
    end
    finished = true
    group.overview_agent_pending = nil
    group.overview_agent_process = nil
    local _, locations = agent.normalize_result(response, true, repository)
    local actual_model = metadata and metadata.model or model.id
    local telemetry_context = metadata and metadata.telemetry or nil
    group.overview_agent_patch_model = actual_model
    group.overview_agent_patch_telemetry = telemetry_context
    require("oculus.telemetry").record(
      "oculus.inspect.agent_result.process",
      {
        ["gen_ai.workflow.name"] = "oculus.inspect.patch_locations",
        ["oculus.agent.result.valid"] = response ~= nil,
        ["oculus.agent.result.location_count"] = #locations,
      },
      telemetry_context,
      response and nil or "invalid_output"
    )
    M._overview_ui.render_patch_locations(
      group,
      actual_model,
      response and locations or nil,
      err or "Codex returned no patch locations"
    )
  end
  local process, err = agent.explain({
    cwd = repository,
    prompt = agent.patch_locations_prompt(group),
    model = model.id,
    workflow = "oculus.inspect.patch_locations",
    output_type = "json",
    telemetry_attributes = M._overview_ui.agent_telemetry_attributes(group),
  }, finish)
  if not process and not finished then
    finish(nil, err)
  elseif not finished then
    group.overview_agent_process = process
  end
end

show_inspection_overview = function(group)
  if overview_window_is_open(group) then
    vim.api.nvim_set_current_win(group.overview_win)
    return
  end
  local tab = vim.api.nvim_get_current_tabpage()
  local endpoint = endpoint_for_tab(group, tab)
  if not endpoint then
    for _, patch in ipairs(group.overview_patch_tabs or {}) do
      if patch.tab == tab
        and vim.api.nvim_tabpage_is_valid(patch.tab)
        and vim.api.nvim_win_is_valid(patch.win)
        and vim.api.nvim_buf_is_valid(patch.buf)
      then
        endpoint = patch
        break
      end
    end
  end
  if not endpoint then
    return
  end
  local source_win = vim.api.nvim_get_current_win()
  local sidebar_win = group.sidebar_windows
      and group.sidebar_windows[tab]
    or nil
  group.overview_return = {
    tab = tab,
    source = capture_window_state(source_win),
    sidebar = capture_window_state(sidebar_win),
    endpoint = endpoint and capture_window_state(endpoint.win),
    anchor_line = group.sidebar_anchor_line,
  }
  group.overview_code_window_options = {
    number = vim.wo[endpoint.win].number,
    relativenumber = vim.wo[endpoint.win].relativenumber,
    cursorline = vim.wo[endpoint.win].cursorline,
    cursorlineopt = vim.wo[endpoint.win].cursorlineopt,
    cursorcolumn = vim.wo[endpoint.win].cursorcolumn,
    signcolumn = vim.wo[endpoint.win].signcolumn,
    wrap = vim.wo[endpoint.win].wrap,
    linebreak = vim.wo[endpoint.win].linebreak,
    list = vim.wo[endpoint.win].list,
    foldcolumn = vim.wo[endpoint.win].foldcolumn,
    colorcolumn = vim.wo[endpoint.win].colorcolumn,
    spell = vim.wo[endpoint.win].spell,
    winhighlight = vim.wo[endpoint.win].winhighlight,
    highlight_namespace = vim.api.nvim_get_hl_ns({ winid = endpoint.win }),
  }
  group.overview_highlight_source_win = valid_endpoint(endpoint)
      and endpoint.win
    or source_win
  local config = overview_window_config(
    group.overview_window_config,
    group.overview
  )
  group.overview_original_config = vim.deepcopy(config)
  group.overview_content_width =
    math.max(12, (config.width or 28) - 4)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = "oculus-inspect-overview"
  vim.b[buf].oculus_inspect_overview = true

  group.overview_buf = buf
  M._overview_ui.render(group)
  if M._overview_ui.restore_model_selection(group) then
    M._overview_ui.render(group)
  end
  local win = vim.api.nvim_open_win(buf, true, config)
  group.overview_win = win
  M._overview_ui.refresh_queue_sidebar(group)
  group.overview_scroll_autocmd = vim.api.nvim_create_autocmd(
    "WinScrolled",
    {
      group = sync_group,
      pattern = tostring(win),
      callback = function()
        M._overview_ui.clamp_scroll(group)
      end,
    }
  )
  M._overview_ui.render_footer(group)
  if group.overview_agent_mode == "loading_models"
    or group.overview_agent_mode == "generating"
  then
    M._overview_ui.start_agent_spinner(group)
  end
  vim.api.nvim_create_autocmd("WinEnter", {
    group = sync_group,
    buffer = buf,
    callback = function()
      if overview_window_is_open(group)
        and vim.api.nvim_get_current_win() == group.overview_win
      then
        hide_overview_cursor(group)
        M._overview_ui.schedule_highlight_refresh(group)
      end
    end,
  })
  vim.api.nvim_create_autocmd("WinLeave", {
    group = sync_group,
    buffer = buf,
    callback = function()
      restore_overview_cursor(group)
    end,
  })
  hide_overview_cursor(group)
  vim.wo[win].wrap = false
  vim.wo[win].number = false
  vim.wo[win].relativenumber = false
  vim.wo[win].signcolumn = "no"
  vim.wo[win].cursorline = false
  vim.wo[win].winhighlight = table.concat({
    "Normal:OculusNormal",
    "NormalFloat:OculusNormal",
    "FloatBorder:OculusBorder",
    "FloatTitle:OculusBorder",
    "FloatFooter:OculusBorder",
  }, ",")
  require("oculus.window").apply_window_highlights(
    win,
    group.overview_highlight_source_win
  )
  M._overview_ui.schedule_highlight_refresh(group)
  group.overview_highlight_autocmd = vim.api.nvim_create_autocmd(
    "ColorScheme",
    {
      group = sync_group,
      callback = function()
        M._overview_ui.schedule_highlight_refresh(group)
      end,
    }
  )
  vim.keymap.set("n", "<C-Tab>", function()
    M._overview_ui.move_queue_cursor(group, 1)
  end, {
    buffer = buf,
    nowait = true,
    silent = true,
    desc = "Next Oculus overview queue item",
  })
  vim.keymap.set("n", "<S-Tab>", function()
    M._overview_ui.move_queue_cursor(group, -1)
  end, {
    buffer = buf,
    nowait = true,
    silent = true,
    desc = "Previous Oculus overview queue item",
  })
  vim.keymap.set("n", "e", function()
    M._overview_ui.open_model_picker(group, "explanation")
  end, {
    buffer = buf,
    nowait = true,
    silent = true,
    desc = "Choose Oculus explanation model",
  })
  if require("oculus.agent").needs_patch_locations(group) then
    vim.keymap.set("n", "p", function()
      if M._overview_ui.toggle_patch_locations_focus(group) then
        return
      end
      M._overview_ui.open_model_picker(group, "patch_locations")
    end, {
      buffer = buf,
      nowait = true,
      silent = true,
      desc = "Choose Oculus patch-location model",
    })
  end
  vim.keymap.set("n", "<C-c>", function()
    M._overview_ui.unfocus_patch_locations(group)
  end, {
    buffer = buf,
    nowait = true,
    silent = true,
    desc = "Unfocus Oculus patch locations",
  })
  vim.keymap.set("n", "b", function()
    M._overview_ui.open_browser(group)
  end, {
    buffer = buf,
    nowait = true,
    silent = true,
    desc = "Open Oculus inspection item in browser",
  })
  vim.keymap.set("n", "c", function()
    local lifecycle = group.inspection_lifecycle
    local request_close = lifecycle and lifecycle.on_close_requested
    if type(request_close) == "function" then
      M._overview_ui.start_close_spinner(group)
      if request_close(group) then
        return
      end
      M._overview_ui.stop_close_spinner(group)
    end
    M._close_inspection_workflow(group)
  end, {
    buffer = buf,
    nowait = true,
    silent = true,
    desc = "Close Oculus Inspect workflow",
  })
  vim.keymap.set("n", "q", function()
    show_sidebar_files(group)
  end, {
    buffer = buf,
    nowait = true,
    silent = true,
    desc = "Close Oculus Inspect overview",
  })
  local overview_lhs = group.overview_toggle
  if overview_lhs == nil then
    overview_lhs = default_overview_toggle
  end
  if type(overview_lhs) == "string" and overview_lhs ~= "" then
    vim.keymap.set("n", overview_lhs, function()
      show_sidebar_files(group)
    end, {
      buffer = buf,
      nowait = true,
      silent = true,
      desc = "Close Oculus Inspect overview",
    })
  end
  vim.keymap.set("n", "<C-t>", function()
    show_sidebar_files(group)
  end, {
    buffer = buf,
    nowait = true,
    silent = true,
    desc = "Close Oculus Inspect overview",
  })
  local function map_scroll(lhs, direction, desc)
    vim.keymap.set("n", lhs, function()
      if group.overview_agent_mode == "models" then
        M._overview_ui.move_model_cursor(group, direction < 0 and -1 or 1)
        return
      end
      if M._overview_ui.move_location_cursor(
        group,
        direction < 0 and -1 or 1
      ) then
        return
      end
      local view = vim.fn.winsaveview()
      local height = M._overview_ui.content_height(group)
      local line_count = vim.api.nvim_buf_line_count(buf)
      local max_topline = math.max(
        1,
        math.min(line_count, line_count - height + 2)
      )
      local topline = math.max(
        1,
        math.min(max_topline, view.topline + direction)
      )
      if topline == view.topline then
        return
      end
      vim.api.nvim_win_set_cursor(win, { topline, 0 })
      view = vim.fn.winsaveview()
      view.topline = topline
      vim.fn.winrestview(view)
    end, {
      buffer = buf,
      nowait = true,
      silent = true,
      desc = desc,
    })
  end
  map_scroll("k", 1, "Scroll Oculus Inspect overview down")
  map_scroll("<Down>", 1, "Scroll Oculus Inspect overview down")
  map_scroll("i", -1, "Scroll Oculus Inspect overview up")
  map_scroll("<Up>", -1, "Scroll Oculus Inspect overview up")
  map_scroll("<C-k>", 10, "Scroll Oculus Inspect overview down 10 lines")
  vim.keymap.set("n", "<CR>", function()
    if group.overview_agent_mode == "models" then
      M._overview_ui.select_agent_model(group)
    else
      M._overview_ui.open_patch_location(group)
    end
  end, {
    buffer = buf,
    nowait = true,
    silent = true,
    desc = "Select Oculus overview item",
  })
  vim.keymap.set("n", "<Space>", function()
    M._overview_ui.toggle_patch_location(group)
  end, {
    buffer = buf,
    nowait = true,
    silent = true,
    desc = "Toggle Oculus patch location",
  })
  if group.overview_view then
    vim.api.nvim_win_call(win, function()
      vim.fn.winrestview(group.overview_view)
    end)
  end
  vim.api.nvim_set_current_win(win)
end

show_sidebar_files = function(group)
  local return_state = group.overview_return
  sidebar_navigating = true
  group.sidebar_anchor_line = return_state and return_state.anchor_line or nil
  close_overview_window(group)
  set_change_highlights()
  for _, session in ipairs(group) do
    for _, endpoint in ipairs(group.kind == "issue"
        and { session.issue }
      or { session.parent, session.change })
    do
      if valid_endpoint(endpoint) then
        vim.wo[endpoint.win].signcolumn = "yes"
      end
    end
  end
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
    restore_window_state(return_state.source)
    if return_state.source
      and vim.api.nvim_win_is_valid(return_state.source.win)
    then
      vim.api.nvim_set_current_win(return_state.source.win)
      group.focused_win =
          return_state.source.win == (
            group.sidebar_windows
              and group.sidebar_windows[return_state.tab]
          )
        and return_state.source.win
        or nil
    end
  end
  group.overview_return = nil
  group.sidebar_focus_generation =
    (group.sidebar_focus_generation or 0) + 1
  sidebar_navigating = false
end

local function map_inspection_sidebar_toggle(group)
  local sidebar_opts = {
    nowait = true,
    silent = true,
    desc = "Toggle Oculus Inspect sidebar",
  }
  local sidebar_lhs = group.sidebar_toggle
  if sidebar_lhs == nil then
    sidebar_lhs = default_sidebar_toggle
  end
  local overview_lhs = group.overview_toggle
  if overview_lhs == nil then
    overview_lhs = default_overview_toggle
  end
  local next_chunk_lhs = group.next_chunk
  if next_chunk_lhs == nil then
    next_chunk_lhs = default_next_chunk
  end
  local function map_buffer(buf)
    local opts = vim.tbl_extend(
      "force",
      sidebar_opts,
      { buffer = buf }
    )
    local function toggle_sidebar()
      toggle_inspection_sidebar(group)
    end
    local function toggle_overview()
      if overview_window_is_open(group) then
        show_sidebar_files(group)
      else
        show_inspection_overview(group)
      end
    end
    if type(sidebar_lhs) == "string" and sidebar_lhs ~= "" then
      vim.keymap.set("n", sidebar_lhs, toggle_sidebar, opts)
    end
    if type(overview_lhs) == "string" and overview_lhs ~= "" then
      vim.keymap.set("n", overview_lhs, toggle_overview, {
        buffer = buf,
        nowait = true,
        silent = true,
        desc = "Toggle Oculus Inspect overview",
      })
    end
    vim.keymap.set("n", "<C-t>", toggle_overview, {
      buffer = buf,
      nowait = true,
      silent = true,
      desc = "Toggle Oculus Inspect overview",
    })
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
  vim.keymap.set("n", "<CR>", function()
    focus_sidebar_selection(group)
  end, {
    buffer = group.sidebar_buf,
    nowait = true,
    silent = true,
    desc = "Open Oculus Inspect sidebar item",
  })
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
  local previous_chunk_lhs = group.previous_chunk
  if previous_chunk_lhs == nil then
    previous_chunk_lhs = default_previous_chunk
  end
  if
    type(previous_chunk_lhs) == "string"
    and previous_chunk_lhs ~= ""
  then
    vim.keymap.set("n", previous_chunk_lhs, function()
      select_previous_sidebar_chunk(group)
    end, {
      buffer = group.sidebar_buf,
      nowait = true,
      silent = true,
      desc = "Previous Oculus changed chunk",
    })
  end
  if group.kind ~= "issue" then
    local old_lhs = group.old_version
    if old_lhs == nil then
      old_lhs = default_version_keys.old
    end
    local new_lhs = group.new_version
    if new_lhs == nil then
      new_lhs = default_version_keys.new
    end
    local function map_version(lhs, target_role, description)
      if type(lhs) ~= "string" or lhs == "" then
        return
      end
      vim.keymap.set("n", lhs, function()
        switch_sidebar_version(group, target_role)
      end, {
        buffer = group.sidebar_buf,
        nowait = true,
        silent = true,
        desc = description,
      })
    end
    map_version(old_lhs, "parent", "Open Oculus old file version")
    map_version(new_lhs, "change", "Open Oculus new file version")
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
  group.sidebar_rendered_mode = nil
  group.overview = group.overview or {}
  M._assign_sidebar_versions(group)
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
        group.sidebar_width,
        session.sidebar_version
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

local function activate_inspection_sidebar(group, open_immediately)
  map_inspection_sidebar_toggle(group)
  sidebar_groups[#sidebar_groups + 1] = group
  if open_immediately ~= false then
    open_inspection_sidebar(group)
  end
end

function M._overview_ui.prepare_patch_sidebar(source_group, opened)
  if type(opened) ~= "table" or #opened == 0 then
    return
  end
  local group = {}
  for key, value in pairs(source_group) do
    if type(key) ~= "number" then
      group[key] = value
    end
  end
  group.kind = "issue"
  group.discarded = nil
  group.overview_win = nil
  group.overview_buf = nil
  group.overview_footer_win = nil
  group.overview_footer_buf = nil
  group.overview_return = nil
  group.overview_patch_tabs = opened
  group.overview_patch_group = nil
  group.patch_suggestions = true
  group.focused_win = nil
  local repository = require("oculus.agent").repository(source_group)
  for index, patch in ipairs(opened) do
    group[index] = {
      file = patch.path,
      repository = repository,
      sections = {
        {
          line = patch.line,
          last_line = patch.line,
        },
      },
      issue = patch,
      active_chunk = 1,
      last_role = "issue",
    }
  end
  prepare_inspection_sidebar(group)
  for index, patch in ipairs(opened) do
    map_file_navigation(patch, group[index], "issue", group)
  end
  activate_inspection_sidebar(group)
  return group
end

local function sidebar_group_for_buffer(buf)
  for _, group in ipairs(sidebar_groups) do
    if group.sidebar_buf == buf then
      return group
    end
  end
end

local foreign_sidebar_filetypes = {
  aerial = true,
  ["neo-tree"] = true,
  NvimTree = true,
  Outline = true,
  ["symbols-outline"] = true,
}

local function is_foreign_sidebar_window(win)
  if not win or not vim.api.nvim_win_is_valid(win) then
    return false
  end
  local config = vim.api.nvim_win_get_config(win)
  if config.relative and config.relative ~= "" then
    return false
  end
  local buf = vim.api.nvim_win_get_buf(win)
  if sidebar_group_for_buffer(buf)
    or type(vim.b[buf].oculus_inspect) == "table"
  then
    return false
  end
  if foreign_sidebar_filetypes[vim.bo[buf].filetype] then
    return true
  end
  return vim.wo[win].winfixwidth
end

local function inspection_endpoints(group, session)
  return group.kind == "issue"
      and { session.issue }
    or { session.parent, session.change }
end

local function group_foreign_sidebar_state(group)
  local tabs = {}
  local has_endpoint = false
  for _, session in ipairs(group) do
    for _, endpoint in ipairs(inspection_endpoints(group, session)) do
      if valid_endpoint(endpoint) then
        has_endpoint = true
        tabs[endpoint.tab] = true
      end
    end
  end
  for tab in pairs(tabs) do
    for _, win in ipairs(vim.api.nvim_tabpage_list_wins(tab)) do
      if is_foreign_sidebar_window(win) then
        return true, has_endpoint
      end
    end
  end
  return false, has_endpoint
end

local function queue_displaced_sidebar_restore(group)
  if group.sidebar_foreign_restore_pending then
    return
  end
  group.sidebar_foreign_restore_pending = true
  -- WinClosed and its accompanying WinEnter fire before Neovim permits a
  -- replacement split. Recheck on the next event-loop turn before restoring.
  vim.schedule(function()
    group.sidebar_foreign_restore_pending = nil
    local has_foreign_sidebar, has_endpoint =
      group_foreign_sidebar_state(group)
    if not has_endpoint then
      group.sidebar_displaced_by_foreign = nil
      group.sidebar_restore_after_foreign = nil
      return
    end
    if has_foreign_sidebar or not group.sidebar_displaced_by_foreign then
      return
    end
    local restore = group.sidebar_restore_after_foreign
    group.sidebar_displaced_by_foreign = nil
    group.sidebar_restore_after_foreign = nil
    if restore and not group.sidebar_visible then
      open_inspection_sidebar(group)
    end
  end)
end

local function reconcile_foreign_sidebars()
  for _, group in ipairs(sidebar_groups) do
    local has_foreign_sidebar, has_endpoint =
      group_foreign_sidebar_state(group)
    if not has_endpoint then
      group.sidebar_displaced_by_foreign = nil
      group.sidebar_restore_after_foreign = nil
    elseif has_foreign_sidebar then
      if not group.sidebar_displaced_by_foreign
        and group.sidebar_visible
      then
        group.sidebar_displaced_by_foreign = true
        group.sidebar_restore_after_foreign = true
        close_inspection_sidebar(group)
      end
    elseif group.sidebar_displaced_by_foreign then
      queue_displaced_sidebar_restore(group)
    end
  end
end

function M._notify_closed_inspection_groups()
  vim.schedule(function()
    if inspection_tabs_loading then
      return
    end
    for index = #sidebar_groups, 1, -1 do
      local group = sidebar_groups[index]
      local _, has_endpoint = group_foreign_sidebar_state(group)
      if not has_endpoint and not group.discarded and not group.close_notified
      then
        group.close_notified = true
        table.remove(sidebar_groups, index)
        close_overview_window(group)
        if group.sidebar_buf
          and vim.api.nvim_buf_is_valid(group.sidebar_buf)
        then
          pcall(vim.api.nvim_buf_delete, group.sidebar_buf, { force = true })
        end
        local lifecycle = group.inspection_lifecycle
        local callback = lifecycle and lifecycle.on_closed
        if type(callback) == "function" then
          pcall(callback)
        end
      end
    end
  end)
end

vim.api.nvim_create_autocmd({
  "WinNew",
  "WinEnter",
  "BufWinEnter",
  "FileType",
  "WinClosed",
  "TabClosed",
  "BufWipeout",
}, {
  group = sync_group,
  callback = function(args)
    reconcile_foreign_sidebars()
    if args.event == "WinClosed" then
      for _, group in ipairs(sidebar_groups) do
        if group.sidebar_displaced_by_foreign then
          queue_displaced_sidebar_restore(group)
        end
      end
    end
    if args.event == "TabClosed" or args.event == "BufWipeout" then
      M._notify_closed_inspection_groups()
    end
  end,
})

local function inspection_statusline(win)
  win = tonumber(win or vim.g.statusline_winid)
    or vim.api.nvim_get_current_win()
  if not vim.api.nvim_win_is_valid(win) then
    return ""
  end
  local buf = vim.api.nvim_win_get_buf(win)
  local state = vim.b[buf].oculus_inspect
  if type(state) ~= "table" then
    return ""
  end
  local path = vim.b[buf].oculus_inspect_statusline_path
    or inspection_statusline_path(state)
    or ""
  local cursor = vim.api.nvim_win_get_cursor(win)
  return (" %s%%= %d,%d "):format(
    path:gsub("%%", "%%%%"),
    cursor[1],
    cursor[2] + 1
  )
end

local function open_sidebar_selection(group, preferred_role)
  if sidebar_navigating or overview_window_is_open(group) then
    return
  end
  local tab = vim.api.nvim_get_current_tabpage()
  local active_index, role = sidebar_active_item(group, tab)
  local line = vim.api.nvim_win_get_cursor(0)[1]
  local entry = group.sidebar_entries[line]
  local session = entry and group[entry.pair_index] or nil
  role = sidebar_target_role(
    active_index,
    role,
    entry,
    group,
    preferred_role
  )
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
  remember_session_role(session, role)
  sidebar_navigating = true
  if entry.chunk_index then
    local start
    if group.kind == "issue" then
      local section = session.sections[entry.chunk_index]
      start = section and section.line
    else
      start = render_chunk_for_role(
        session,
        role,
        entry.chunk_index
      )
    end
    if start then
      move_cursor_to_line_start(endpoint.win, start)
    end
  else
    if group.kind ~= "issue" then
      render_full_file(session)
    end
    show_file_top(endpoint.win)
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

local function select_sidebar_entry(group, direction, preferred_role)
  if overview_window_is_open(group) then
    return
  end
  local source_is_sidebar = vim.api.nvim_get_current_buf()
    == group.sidebar_buf
  local source_tab = vim.api.nvim_get_current_tabpage()
  local active_index, active_role = sidebar_active_item(group, source_tab)
  if not active_index or #group.sidebar_lines == 0 then
    return
  end

  local line
  if source_is_sidebar then
    line = vim.api.nvim_win_get_cursor(0)[1]
  else
    line = group.sidebar_navigation_line
    local anchored = line and group.sidebar_entries[line] or nil
    if not anchored or anchored.pair_index ~= active_index then
      local active_chunk = sidebar_chunk(
        group,
        group[active_index],
        active_role
      )
      line = active_chunk
          and group.sidebar_chunk_lines[active_index]
          and group.sidebar_chunk_lines[active_index][active_chunk]
        or group.sidebar_rows[active_index].line_number
    end
  end
  local target_line = line
  local entry
  for _ = 1, #group.sidebar_lines do
    target_line = ((target_line - 1 + direction)
      % #group.sidebar_lines) + 1
    entry = group.sidebar_entries[target_line]
    if entry then
      break
    end
  end
  if not entry then
    return
  end
  local session = group[entry.pair_index]
  local role = sidebar_target_role(
    active_index,
    active_role,
    entry,
    group,
    preferred_role
  )
  local endpoint = sidebar_endpoint(group, session, role)
  if not valid_endpoint(endpoint) then
    return
  end
  if not source_is_sidebar then
    if group.sidebar_visible and ensure_inspection_sidebar_on_tab then
      ensure_inspection_sidebar_on_tab(group, endpoint.tab)
    end
    remember_session_role(session, role)
    sidebar_navigating = true
    vim.api.nvim_set_current_tabpage(endpoint.tab)
    vim.api.nvim_set_current_win(endpoint.win)
    if entry.chunk_index then
      local start
      if group.kind == "issue" then
        local section = session.sections[entry.chunk_index]
        start = section and section.line
      else
        start = render_chunk_for_role(
          session,
          role,
          entry.chunk_index
        )
      end
      if start then
        move_cursor_to_line_start(endpoint.win, start)
      end
    else
      if group.kind ~= "issue" then
        render_full_file(session)
      end
      show_file_top(endpoint.win)
    end
    show_inspection_path(endpoint.buf)
    refresh_sidebar(group, endpoint.tab)
    group.sidebar_navigation_line = target_line
    local target_sidebar_win = group.sidebar_windows
        and group.sidebar_windows[endpoint.tab]
      or nil
    if target_sidebar_win
      and vim.api.nvim_win_is_valid(target_sidebar_win)
    then
      vim.api.nvim_win_set_cursor(
        target_sidebar_win,
        { target_line, 0 }
      )
    end
    vim.b[group.sidebar_buf].oculus_inspect_sidebar_active = {
      pair_index = entry.pair_index,
      role = role,
      chunk_index = entry.chunk_index,
      chunk_count = #inspection_chunks(group, session),
    }
    group.focused_win = nil
    sidebar_navigating = false
    return
  end
  local sidebar_win = group.sidebar_windows[endpoint.tab]
  if not sidebar_win or not vim.api.nvim_win_is_valid(sidebar_win) then
    return
  end
  sidebar_navigating = true
  vim.api.nvim_set_current_tabpage(endpoint.tab)
  vim.api.nvim_set_current_win(sidebar_win)
  vim.api.nvim_win_set_cursor(sidebar_win, { target_line, 0 })
  group.focused_win = sidebar_win
  sidebar_navigating = false
  open_sidebar_selection(group, role)
end

select_next_sidebar_chunk = function(group, preferred_role)
  select_sidebar_entry(group, 1, preferred_role)
end

select_previous_sidebar_chunk = function(group, preferred_role)
  select_sidebar_entry(group, -1, preferred_role)
end

focus_sidebar_selection = function(group)
  if
    sidebar_navigating
    or overview_window_is_open(group)
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

  local chunk_index = entry.chunk_index
  local hunk = group.kind ~= "issue"
      and chunk_index
      and session.hunks
      and session.hunks[chunk_index]
    or nil
  local section = group.kind == "issue"
      and chunk_index
      and session.sections
      and session.sections[chunk_index]
    or nil
  group.sidebar_anchor_line = line
  sidebar_navigating = true
  group.sidebar_focus_generation =
    (group.sidebar_focus_generation or 0) + 1
  group.focused_win = nil
  remember_session_role(session, role)
  vim.api.nvim_set_current_win(endpoint.win)
  if hunk then
    local start = render_chunk_for_role(session, role, chunk_index)
    move_cursor_to_line_start(endpoint.win, start)
  elseif section then
    move_cursor_to_line_start(endpoint.win, section.line)
  else
    if group.kind ~= "issue" then
      render_full_file(session)
    end
    show_file_top(endpoint.win)
  end
  show_inspection_path(endpoint.buf)
  refresh_sidebar(group, endpoint.tab)
  sidebar_navigating = false
end

switch_sidebar_version = function(group, target_role)
  if
    sidebar_navigating
    or overview_window_is_open(group)
    or vim.api.nvim_get_current_buf() ~= group.sidebar_buf
  then
    return
  end
  local tab = vim.api.nvim_get_current_tabpage()
  local _, role = sidebar_active_item(group, tab)
  if target_role ~= "parent" and target_role ~= "change" then
    return
  end
  if role == target_role then
    return
  end
  local line = vim.api.nvim_win_get_cursor(0)[1]
  local entry = group.sidebar_entries[line]
  local session = entry and group[entry.pair_index] or nil
  local endpoint = session and session[target_role] or nil
  if not valid_endpoint(endpoint) then
    return
  end
  ensure_inspection_sidebar_on_tab(group, endpoint.tab)
  local sidebar_win = group.sidebar_windows[endpoint.tab]
  if not sidebar_win or not vim.api.nvim_win_is_valid(sidebar_win) then
    return
  end

  local source_win = vim.api.nvim_get_current_win()
  local source_view = vim.api.nvim_win_call(source_win, function()
    return vim.fn.winsaveview()
  end)
  remember_session_role(session, target_role)
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
  move_cursor_to_line_start(sidebar_win)
  sidebar_navigating = false
  vim.schedule(function()
    if valid_endpoint(endpoint) then
      refresh_buffer_highlighting(endpoint.buf, false)
    end
  end)
end

function M._adjacent_inspection_tab(tab, direction)
  local tabs = vim.api.nvim_list_tabpages()
  for index, candidate in ipairs(tabs) do
    if candidate == tab then
      return tabs[((index - 1 + direction) % #tabs) + 1]
    end
  end
end

function M._preserved_version_tab(source, entered_tab)
  local group = source and source.group
  if not group then
    return entered_tab
  end
  local target_index, target_role = sidebar_active_item(group, entered_tab)
  if not target_index then
    return entered_tab
  end

  local target_tab = entered_tab
  if target_index == source.index and target_role ~= source.role then
    local direction = source.role == "parent" and 1 or -1
    target_tab = M._adjacent_inspection_tab(entered_tab, direction)
      or entered_tab
    target_index = sidebar_active_item(group, target_tab)
  end

  if target_index and target_index ~= source.index then
    local session = group[target_index]
    local endpoint = session and session[source.role]
    if valid_endpoint(endpoint) then
      target_tab = endpoint.tab
    end
  end
  return target_tab
end

vim.api.nvim_create_autocmd("TabLeave", {
  group = sync_group,
  callback = function()
    M._tab_navigation_source = nil
    if sidebar_navigating or inspection_tabs_loading then
      return
    end
    local tab = vim.api.nvim_get_current_tabpage()
    for _, group in ipairs(sidebar_groups) do
      local index, role = sidebar_active_item(group, tab)
      if index then
        M._tab_navigation_source = {
          group = group,
          index = index,
          role = role,
        }
        return
      end
    end
  end,
})

vim.api.nvim_create_autocmd("TabEnter", {
  group = sync_group,
  callback = function()
    if sidebar_navigating then
      return
    end
    local source = M._tab_navigation_source
    M._tab_navigation_source = nil
    local tab = vim.api.nvim_get_current_tabpage()
    local target = M._preserved_version_tab(source, tab)
    if target ~= tab and vim.api.nvim_tabpage_is_valid(target) then
      sidebar_navigating = true
      vim.api.nvim_set_current_tabpage(target)
      sidebar_navigating = false
      tab = target
    end
    for _, group in ipairs(sidebar_groups) do
      if not sidebar_navigating then
        local index, role = sidebar_active_item(group, tab)
        remember_session_role(index and group[index] or nil, role)
      end
      ensure_inspection_sidebar_on_tab(group, tab)
      local endpoint = endpoint_for_tab(group, tab)
      if endpoint then
        apply_inspection_filetype(endpoint.buf, false)
        M._enable_inspection_treesitter_context(
          group.persistence_config or {}
        )
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
    if sidebar_navigating then
      return
    end
    local current_win = vim.api.nvim_get_current_win()
    if type(vim.b[args.buf].oculus_inspect) == "table" then
      set_change_highlights()
      vim.wo[current_win].signcolumn = "yes"
    end
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
    if group and group.focused_win then
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
  local initial_undolevels = vim.bo[buf].undolevels
  vim.bo[buf].undolevels = -1
  local lines = role == "change"
      and inspection.change_lines
    or inspection.parent_lines
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines or { "" })
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "hide"
  vim.bo[buf].swapfile = false
  vim.bo[buf].modifiable = true
  vim.bo[buf].readonly = false
  local filetype = file and vim.filetype.match({ filename = file }) or nil
  if filetype then
    vim.bo[buf].filetype = filetype
  end
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
  refresh_buffer_highlighting(buf, false)
  local loaded = {
    tab = vim.api.nvim_get_current_tabpage(),
    win = vim.api.nvim_get_current_win(),
    buf = vim.api.nvim_get_current_buf(),
    initial_undolevels = initial_undolevels,
  }
  vim.wo[loaded.win].signcolumn = "yes"
  vim.wo[loaded.win].wrap = false
  return loaded
end

local function finish_inspection_buffer_initialization(endpoint)
  if not endpoint or not vim.api.nvim_buf_is_valid(endpoint.buf) then
    return
  end
  local undolevels = endpoint.initial_undolevels
  endpoint.initial_undolevels = nil
  if undolevels ~= nil then
    vim.bo[endpoint.buf].undolevels = undolevels
  end
  vim.bo[endpoint.buf].modified = false
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
  preserve_cursorline_text_highlighting(win)
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
  sort_inspections(inspections)
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
    M._discard_previous_inspections()
    local inspection_sessions = {
      inspection_lifecycle = loading and loading.lifecycle,
      sidebar_toggle = opts.inspect_sidebar_toggle,
      sidebar_width_proportion = opts.inspect_sidebar_width,
      overview_toggle = opts.inspect_overview_toggle,
      old_version = opts.inspect_old_version,
      new_version = opts.inspect_new_version,
      next_chunk = opts.inspect_next_chunk,
      previous_chunk = opts.inspect_previous_chunk,
      overview = inspection_overview(info),
      browser_config = { browser_command = opts.browser_command },
      persist_inspect_overviews = opts.persist_inspect_overviews ~= false,
      inspect_overviews = opts.inspect_overviews or {},
      state_file = opts.state_file,
      persistence_config = opts,
      overview_window_config =
        require("oculus.window").window_config(opts),
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
        patch = paths.patch,
        status = paths.status,
        parent_lines = change_lines(paths.hunks, "parent"),
        change_lines = change_lines(paths.hunks),
        active_chunk = paths.hunks[1] and 1 or nil,
        last_role = "parent",
      }
    end

    M._overview_ui.restore_persisted(inspection_sessions)

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
      M._synchronize_inspection_highlighting(parent.buf, change.buf)
      if not focused_start then
        apply_change_signs(parent.buf, change.buf, {}, session.status)
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
      local first_hunk = session.active_chunk
          and session.hunks[session.active_chunk]
        or nil
      if focused_start and first_hunk then
        set_change_cursor(parent.win, chunk_start_for_role(
          first_hunk,
          "parent",
          focused_start,
          session.change_content
        ))
        position_change_cursor(change.win, chunk_start_for_role(
          first_hunk,
          "change",
          focused_start,
          session.change_content
        ))
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
    for _, session in ipairs(inspection_sessions) do
      finish_inspection_buffer_initialization(session.parent)
      finish_inspection_buffer_initialization(session.change)
    end
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
    M._enable_inspection_treesitter_context(opts)
    if loading
      and loading.lifecycle
      and loading.lifecycle.overview_on_open
    then
      show_inspection_overview(inspection_sessions)
    end
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
    local reads = {}
    local tasks = {}
    for file_index, changed_file in ipairs(changed_files) do
      local parent_file = changed_file.old_path
      local change_file = changed_file.new_path
      local read = {
        changed_file = changed_file,
        parent_file = parent_file,
        change_file = change_file,
        parent_lines = changed_file.status == "A" and { "" } or nil,
        change_lines = changed_file.status == "D" and { "" } or nil,
      }
      reads[file_index] = read

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

      tasks[#tasks + 1] = function(done)
        run(diff_command, function(patch, patch_err)
          if patch_err then
            done(nil, "could not read file hunks: " .. patch_err)
            return
          end
          read.patch = patch
          done(true)
        end)
      end
      if changed_file.status ~= "A" then
        tasks[#tasks + 1] = function(done)
          read_revision_file(
            repository,
            pair.parent,
            parent_file,
            false,
            function(parent_lines, parent_err)
              if parent_err then
                done(nil, parent_err)
                return
              end
              read.parent_lines = parent_lines
              done(true)
            end
          )
        end
      end
      if changed_file.status ~= "D" then
        tasks[#tasks + 1] = function(done)
          read_revision_file(
            repository,
            pair.commit,
            change_file,
            false,
            function(change_lines, change_err)
              if change_err then
                done(nil, change_err)
                return
              end
              read.change_lines = change_lines
              done(true)
            end
          )
        end
      end
    end

    map_concurrently(
      tasks,
      changed_file_read_concurrency,
      function(task, _, done)
        task(done)
      end,
      function(_, read_err)
        if read_err then
          callback(nil, read_err)
          return
        end
        local inspections = {}
        for file_index, read in ipairs(reads) do
          local changed_file = read.changed_file
          inspections[file_index] = {
            kind = info.kind,
            parent = pair.parent,
            commit = pair.commit,
            parent_role = info.kind == "pull_request"
                and "old"
              or "parent",
            repository = repository,
            parent_file = read.parent_file,
            change_file = read.change_file,
            parent_lines = read.parent_lines,
            change_lines = read.change_lines,
            patch = read.patch,
            changes = changed_files,
            hunks = parse_hunks(read.patch),
            commit_index = commit_index,
            file_index = file_index,
            file_count = #changed_files,
            status = changed_file.status,
          }
        end
        callback(inspections)
      end
    )
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
    "created_at",
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

local function open_issue_inspection(
  info,
  details,
  repository,
  loading,
  number_options,
  opts,
  done
)
  local staging_tab = vim.api.nvim_get_current_tabpage()
  local staging_win = vim.api.nvim_get_current_win()
  local page
  inspection_tabs_loading = true
  local ok, err = pcall(function()
    M._discard_previous_inspections()
    local resolved = vim.deepcopy(info)
    for _, key in ipairs({
      "number",
      "title",
      "body",
      "author",
      "state",
      "html_url",
      "created_at",
    }) do
      if details[key] ~= nil then
        resolved[key] = details[key]
      end
    end
    if type(details.comment) == "string"
      and vim.trim(details.comment) ~= ""
    then
      local description = type(resolved.body) == "string"
          and vim.trim(resolved.body)
        or ""
      resolved.body = description ~= ""
          and (description .. "\n\nActivity comment\n" .. details.comment)
        or details.comment
    end

    local group = {
      kind = "issue",
      inspection_lifecycle = loading and loading.lifecycle,
      sidebar_toggle = opts.inspect_sidebar_toggle,
      sidebar_width_proportion = opts.inspect_sidebar_width,
      overview_toggle = opts.inspect_overview_toggle,
      old_version = opts.inspect_old_version,
      new_version = opts.inspect_new_version,
      next_chunk = opts.inspect_next_chunk,
      previous_chunk = opts.inspect_previous_chunk,
      overview = inspection_overview(resolved),
      browser_config = { browser_command = opts.browser_command },
      persist_inspect_overviews = opts.persist_inspect_overviews ~= false,
      inspect_overviews = opts.inspect_overviews or {},
      state_file = opts.state_file,
      persistence_config = opts,
      overview_window_config =
        require("oculus.window").window_config(opts),
    }
    local session = {
      file = ("Issue #%s"):format(details.number or info.number),
      repository = repository,
      sections = {},
      last_role = "issue",
    }
    group[1] = session
    M._overview_ui.restore_persisted(group)
    prepare_inspection_sidebar(group)

    local endpoint = make_inspection_tab()
    vim.cmd("tcd " .. vim.fn.fnameescape(repository))
    local tab = endpoint.tab
    local win = endpoint.win
    local buf = endpoint.buf
    next_session = next_session + 1
    local state = {
      kind = "issue",
      role = "issue",
      forge = info.forge,
      owner = info.owner,
      repo = info.repo,
      issue_number = details.number or info.number,
      issue_title = details.title,
      issue_url = details.html_url,
      repository = repository,
      directory = repository,
      loading = false,
    }
    vim.t.oculus_inspect = vim.deepcopy(state)
    vim.b[buf].oculus_inspect = vim.deepcopy(state)
    vim.b[buf].oculus_inspect_repository = repository
    vim.b[buf].oculus_inspect_directory = repository
    vim.b[buf].oculus_inspect_statusline_path = vim.fs.basename(repository)
    vim.bo[buf].buftype = ""
    vim.bo[buf].modifiable = true
    vim.bo[buf].readonly = false
    vim.bo[buf].modified = false
    vim.wo[win].wrap = false
    vim.wo[win].linebreak = false
    vim.wo[win].signcolumn = "yes"
    vim.wo[win].statusline = inspection_statusline_option
    apply_inspection_window_options(win, number_options)
    session.issue = endpoint
    activate_inspection_sidebar(group, false)
    normalize_inspection_view(win)
    page = {
      tab = tab,
      win = win,
      buf = buf,
      group = group,
    }
    stop_loading(loading)
    require("oculus.window").close()
    vim.api.nvim_set_current_tabpage(tab)
    vim.api.nvim_set_current_win(win)
    vim.api.nvim_win_set_cursor(win, { 1, 0 })
    M._enable_inspection_treesitter_context(opts)
    show_inspection_overview(group)
    page.overview_win = group.overview_win
    page.overview_buf = group.overview_buf
  end)
  inspection_tabs_loading = false
  if not ok then
    if vim.api.nvim_tabpage_is_valid(staging_tab) then
      vim.api.nvim_set_current_tabpage(staging_tab)
    end
    if vim.api.nvim_win_is_valid(staging_win) then
      vim.api.nvim_set_current_win(staging_win)
    end
    done(nil, "could not open issue inspection: " .. tostring(err))
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
    ensure_repository(info, opts, function(repository, repository_err)
      if not repository then
        done(nil, repository_err or "could not find the issue repository")
        return
      end
      open_issue_inspection(
        info,
        details,
        repository,
        loading,
        number_options,
        opts,
        done
      )
    end)
  end)
end

M.preload = function(url, opts, context)
  local key = type(url) == "string" and url or nil
  if not key or M._preload_cache[key] then
    return false
  end
  local info = parse_target_url(url)
  if not info then
    return false
  end
  M._preload_cache[key] = { status = "loading" }
  local function failed(err)
    M._preload_cache[key] = { status = "error", error = err }
  end
  if info.kind == "issue" then
    resolve_issue_details(info, opts or {}, context, function(details, err)
      if not details then
        failed(err)
        return
      end
      ensure_repository(info, opts or {}, function(repository, repo_err)
        if not repository then
          failed(repo_err)
          return
        end
        M._preload_cache[key] = {
          status = "ready",
          kind = "issue",
          info = info,
          details = details,
          repository = repository,
        }
      end)
    end)
    return true
  end
  resolve_target(info, opts or {}, function(resolved, resolve_err)
    if not resolved then
      failed(resolve_err)
      return
    end
    prepare(resolved, opts or {}, function(inspections, err)
      if not inspections then
        failed(err)
        return
      end
      M._preload_cache[key] = {
        status = "ready",
        kind = "revision",
        info = resolved,
        inspections = inspections,
      }
    end)
  end)
  return true
end

function M.open(url, opts, context, lifecycle, inspection_window_options)
  opts = opts or {}
  local info = parse_target_url(url)
  if not info then
    return nil,
      "inspect currently supports GitHub and Codeberg commit "
        .. "pull request, and issue activity"
  end
  if vim.fn.executable("git") ~= 1 then
    return nil, "inspect requires git"
  end
  if active then
    return nil, "an inspection is already being prepared"
  end
  local supplied_number_options = type(inspection_window_options) == "table"
  local number_options = supplied_number_options
      and vim.deepcopy(inspection_window_options)
    or {
      number = vim.wo.number,
      relativenumber = vim.wo.relativenumber,
    }
  if not supplied_number_options then
    local window_ok, window = pcall(require, "oculus.window")
    if window_ok and type(window.inspection_window_options) == "function" then
      number_options = window.inspection_window_options() or number_options
    end
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
    local cached = M._preload_cache[url]
    if cached and cached.status == "ready" and cached.kind == "issue" then
      open_issue_inspection(
        cached.info,
        cached.details,
        cached.repository,
        loading,
        number_options,
        opts,
        function(_, issue_err)
          active = false
          if issue_err then
            show_loading_error(loading, issue_err)
          end
        end
      )
      return true
    end
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

    local cached = M._preload_cache[url]
    local function open_prepared(inspections, prepared_info)
      open_tabs(
        inspections,
        loading,
        prepared_info.comment,
        prepared_info,
        number_options,
        opts,
        function(_, open_err)
          active = false
          if open_err then
            show_loading_error(loading, open_err)
          end
        end
      )
    end
    if cached and cached.status == "ready" and cached.kind == "revision" then
      open_prepared(cached.inspections, cached.info)
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
        open_prepared(inspections, resolved)
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
M._overview_window_config = overview_window_config
M._first_changed_paths = first_changed_paths
M._parse_changed_files = parse_changed_files
M._inspection_directory = inspection_directory
M._github_repository = github_repository
M._forge_repository = forge_repository
M._download_destination = download_destination
M._offer_repository_download = offer_repository_download
M._find_local_repository = find_local_repository
M._parse_hunks = parse_hunks
M._parse_revision_pairs = parse_revision_pairs
M._blob_lines = blob_lines
M._oil_entry_status = oil_entry_status
M._entered_oil_subdirectory = entered_oil_subdirectory
M._first_changed_oil_file_line = first_changed_oil_file_line
M._change_lines = change_lines
M._focused_change_lines = focused_change_lines
M._apply_change_signs = apply_change_signs
M._prevent_window_dimming = prevent_window_dimming
M._preserve_cursorline_text_highlighting =
  preserve_cursorline_text_highlighting
M._refresh_buffer_highlighting = refresh_buffer_highlighting
M._apply_inspection_filetype = apply_inspection_filetype
M._normalize_inspection_view = normalize_inspection_view
M._inspection_statusline_path = inspection_statusline_path
M._inspection_buffer_name = inspection_buffer_name
M._inspection_statusline = inspection_statusline
M._inspection_statusline_option = inspection_statusline_option
M._inspection_sidebar_statusline_option =
  inspection_sidebar_statusline_option
M._map_concurrently = map_concurrently
M._sort_inspections = sort_inspections
M._sidebar_row = sidebar_row
M._inspect_sidebar_width = inspect_sidebar_width
M._sidebar_chunk_row = sidebar_chunk_row
M._sidebar_file = sidebar_file
M._sidebar_target_role = sidebar_target_role
M._progressed_chunk_role = progressed_chunk_role
M._chunk_navigation_role = chunk_navigation_role
M._chunk_start_for_role = chunk_start_for_role
M._is_foreign_sidebar_window = is_foreign_sidebar_window
M._inspection_endpoints = inspection_endpoints
M._comment_float = comment_float

return M
