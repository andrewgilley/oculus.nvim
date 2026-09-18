local M = {}
M._preload_cache = {}
local github = require("oculus.github")
local codeberg = require("oculus.codeberg")
local browser = require("oculus.browser")
local active = false
local change_ns = vim.api.nvim_create_namespace("oculus_inspect_changes")
local oil_ns = vim.api.nvim_create_namespace("oculus_inspect_oil")

local oil_group = vim.api.nvim_create_augroup(
  "OculusInspectOil",
  { clear = true }
)

local sidebar_ns = vim.api.nvim_create_namespace("oculus_inspect_sidebar")
M._virtual_counter_ns = vim.api.nvim_create_namespace("oculus_inspect_virtual_counter")
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
local default_version_keys = { old = "<C-s>", new = "<C-d>" }
local default_next_chunk = "<C-Tab>"
local default_previous_chunk = "<S-Tab>"
local hidden_overview_guicursor = "a:OculusInspectHiddenCursor"
local inspection_statusline_option = "%!v:lua.require('oculus.inspect')._inspection_statusline()"
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
local apply_inspection_filetype
local select_endpoint

local context = require("oculus.inspect.context").setup(M, {
  sidebar_groups = sidebar_groups,
})

local ensure_treesitter_safeguards = context.ensure_safeguards
local ensure_context_window_leftcol = context.ensure_leftcol
local rendered_treesitter_contexts = context.rendered
local colorscheme = require("oculus.inspect.colorscheme")
local git = require("oculus.inspect.git")
local patch = require("oculus.inspect.patch")
local target = require("oculus.inspect.target")
local review = require("oculus.inspect.review")

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
    or state.kind == "issue"
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

local function place_sign(buf, line, text, highlight)
  if not vim.api.nvim_buf_is_valid(buf) then
    return
  end

  local line_count = vim.api.nvim_buf_line_count(buf)
  line = math.min(math.max(1, line), line_count)

  vim.api.nvim_buf_set_extmark(buf, change_ns, line - 1, 0, {
    sign_text = text,
    sign_hl_group = highlight,
    priority = 100,
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
    vim.api.nvim_get_hl(0, { name = "CursorLine" })

  local diff_delete = vim.api.nvim_get_hl(0, {
    name = "DiffDelete",
    link = false,
  })

  local diff_add = vim.api.nvim_get_hl(0, { name = "DiffAdd", link = false })

  vim.api.nvim_set_hl(0, "OculusInspectRemoved", {
    fg = diff_delete.fg or 0xfee2e2,
    bg = diff_delete.bg or 0x991b1b,
    default = true,
  })

  vim.api.nvim_set_hl(0, "OculusInspectAdded", {
    fg = diff_add.fg or 0xdcfce7,
    bg = diff_add.bg or 0x166534,
    default = true,
  })

  vim.api.nvim_set_hl(0, "OculusIssueSection", {
    fg = diagnostic_info.fg or 0x61afef,
    bg = normal.bg,
    default = true,
  })

  overview_section.underline = true
  overview_section.sp = overview_section.sp or overview_section.fg
  overview_section.default = true

  vim.api.nvim_set_hl(
    0,
    "OculusInspectOverviewSection",
    overview_section
  )

  vim.api.nvim_set_hl(0, "OculusInspectAgentModelSelected", {
    fg = diagnostic_info.fg or 0x61afef,
    bold = true,
    default = true,
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

  vim.api.nvim_set_hl(0, "OculusInspectVirtualCounter", {
    fg = diagnostic_info.fg or 0x61afef,
    default = true,
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

local function trigger_inspection_treesitter_context(buf)
  if not buf or not vim.api.nvim_buf_is_valid(buf) then
    return
  end

  pcall(vim.api.nvim_exec_autocmds, "CursorMoved", {
    group = "treesitter_context_update",
    buffer = buf,
  })

  pcall(vim.api.nvim_exec_autocmds, "WinScrolled", {
    group = "treesitter_context_update",
    buffer = buf,
  })

  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_buf(win) == buf then
      ensure_context_window_leftcol(win)
    end
  end
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
              trigger_inspection_treesitter_context(buf)
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

  local parent_ft = vim.bo[parent_buf].filetype
  local change_ft = vim.bo[change_buf].filetype

  if parent_ft ~= "" and change_ft == "" then
    vim.bo[change_buf].filetype = parent_ft
    apply_inspection_filetype(change_buf, false)
  elseif change_ft ~= "" and parent_ft == "" then
    vim.bo[parent_buf].filetype = change_ft
    apply_inspection_filetype(parent_buf, false)
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

function apply_inspection_filetype(buf, force_refresh)
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

  local filetype = nil

  if type(filename) == "string" and filename ~= "" then
    local ok, match = pcall(vim.filetype.match, {
      buf = buf,
      filename = filename,
    })

    if ok and type(match) == "string" and match ~= "" then
      filetype = match
    end
  end

  if not filetype then
    local alt_filename = state.change_file or state.parent_file or state.file

    if type(alt_filename) == "string" and alt_filename ~= "" then
      local ok, match = pcall(vim.filetype.match, {
        buf = buf,
        filename = alt_filename,
      })

      if ok and type(match) == "string" and match ~= "" then
        filetype = match
      end
    end
  end

  if not filetype and type(state.filetype) == "string" and state.filetype ~= "" then
    filetype = state.filetype
  end

  local session = state.session

  if not session and state.pair_index then
    for _, group in ipairs(sidebar_groups or {}) do
      if group[state.pair_index] then
        session = group[state.pair_index]
        break
      end
    end
  end

  if not filetype and session then
    if type(session.filetype) == "string" and session.filetype ~= "" then
      filetype = session.filetype
    elseif session.parent
      and session.parent.buf
      and vim.api.nvim_buf_is_valid(session.parent.buf)
      and vim.bo[session.parent.buf].filetype ~= ""
    then
      filetype = vim.bo[session.parent.buf].filetype
    elseif session.change
      and session.change.buf
      and vim.api.nvim_buf_is_valid(session.change.buf)
      and vim.bo[session.change.buf].filetype ~= ""
    then
      filetype = vim.bo[session.change.buf].filetype
    elseif session.parent_content then
      local ok, match = pcall(vim.filetype.match, {
        filename = filename or state.file,
        contents = session.parent_content,
      })

      if ok and type(match) == "string" and match ~= "" then
        filetype = match
      end
    elseif session.change_content then
      local ok, match = pcall(vim.filetype.match, {
        filename = filename or state.file,
        contents = session.change_content,
      })

      if ok and type(match) == "string" and match ~= "" then
        filetype = match
      end
    end

    if filetype then
      session.filetype = filetype
    end
  end

  if not filetype or filetype == "" then
    if vim.bo[buf].filetype ~= "" then
      filetype = vim.bo[buf].filetype
    else
      return
    end
  end

  state.filetype = filetype

  if vim.bo[buf].filetype ~= filetype then
    vim.b[buf].oculus_inspect_highlighting_changedtick = nil
    vim.b[buf].oculus_inspect_highlighting_pending_tick = nil
    vim.b[buf].oculus_inspect_syntax_changedtick = nil
    vim.bo[buf].filetype = filetype
  end

  -- Inspection buffers are scratch buffers, which per-filetype colorscheme
  -- plugins skip, but they show real source code and should get its scheme.
  colorscheme.apply(buf, sidebar_groups)
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

  -- Rewriting identical text still bumps changedtick, which forces a full
  -- re-parse and repaints the tree-sitter context rows on version switches.
  if vim.deep_equal(vim.api.nvim_buf_get_lines(endpoint.buf, 0, -1, false), lines) then
    return true
  end

  vim.api.nvim_buf_set_lines(endpoint.buf, 0, -1, false, lines)
  return true
end

local function render_focused_chunk(session, chunk_index)
  local hunk = session.hunks and session.hunks[chunk_index] or nil

  if not hunk then
    return
  end

  local lines, start = patch.focused_change_lines(
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
  refresh_buffer_highlighting(session.parent.buf)
  M._review.render_marks(session)
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
  refresh_buffer_highlighting(session.parent.buf)
  M._review.render_marks(session)
  return true
end

local function first_nonblank_line(buf, line, max_line)
  if not vim.api.nvim_buf_is_valid(buf) then
    return line
  end

  local line_count = vim.api.nvim_buf_line_count(buf)
  local target = math.min(math.max(1, line or 1), line_count)
  local limit = max_line and math.min(math.max(target, max_line), line_count) or target

  for current = target, limit do
    local text = vim.api.nvim_buf_get_lines(
      buf,
      current - 1,
      current,
      false
    )[1]

    if type(text) == "string" and text:find("%S") then
      return current
    end
  end

  return target
end

local function apply_view_horizontal(view, source_view, text_len, default_col)
  default_col = default_col or 0
  text_len = text_len or 0

  if
    source_view
    and (source_view.leftcol or source_view.skipcol or source_view.col)
  then
    local target_leftcol = source_view.leftcol or 0
    local target_skipcol = source_view.skipcol or 0
    view.leftcol = target_leftcol
    view.skipcol = target_skipcol

    if target_leftcol > 0 then
      if text_len > target_leftcol then
        local desired_col = source_view.col or target_leftcol

        view.col = math.max(
          target_leftcol,
          math.min(desired_col, text_len - 1)
        )

        view.curswant = source_view.curswant or view.col
        view.coladd = 0
      else
        view.col = text_len

        view.coladd = (target_leftcol - text_len)
          + (source_view.coladd or 0)

        view.curswant = source_view.curswant or target_leftcol
      end
    else
      local desired_col = source_view.col or default_col
      view.col = math.min(desired_col, math.max(0, text_len - 1))
      view.curswant = source_view.curswant or view.col
      view.coladd = source_view.coladd or 0
    end
  else
    view.col = default_col
    view.curswant = default_col
    view.coladd = 0
  end
end

local function position_change_cursor(
  win,
  line,
  max_line,
  normalize,
  target_topline,
  source_view
)
  if not vim.api.nvim_win_is_valid(win) then
    return false
  end

  local buf = vim.api.nvim_win_get_buf(win)
  line = first_nonblank_line(buf, line, max_line)

  local horizontal = {
    leftcol = source_view and source_view.leftcol,
    skipcol = source_view and source_view.skipcol,
    col = source_view and source_view.col,
    coladd = source_view and source_view.coladd,
    curswant = source_view and source_view.curswant,
  }

  if horizontal.leftcol == nil and horizontal.skipcol == nil then
    local current_view = vim.api.nvim_win_call(win, function()
      return vim.fn.winsaveview()
    end)

    horizontal.leftcol = current_view.leftcol
    horizontal.skipcol = current_view.skipcol
    horizontal.col = current_view.col
    horizontal.coladd = current_view.coladd
    horizontal.curswant = current_view.curswant
  end

  vim.api.nvim_win_set_cursor(win, { line, 0 })

  if normalize ~= false then
    normalize_inspection_view(win)
  else
    vim.api.nvim_win_call(win, function()
      local text = vim.api.nvim_buf_get_lines(
        buf,
        line - 1,
        line,
        false
      )[1] or ""

      local default_col = (text:find("%S") or 1) - 1
      local view = vim.fn.winsaveview()

      if target_topline then
        view.topline = math.max(1, target_topline)
      elseif source_view and source_view.topline then
        view.topline = math.max(1, source_view.topline)
      end

      view.lnum = line
      apply_view_horizontal(view, source_view, #text, default_col)
      vim.fn.winrestview(view)
    end)
  end

  if normalize ~= false then
    vim.api.nvim_win_call(win, function()
      local text = vim.api.nvim_buf_get_lines(
        buf,
        line - 1,
        line,
        false
      )[1] or ""

      local default_col = (text:find("%S") or 1) - 1
      local view = vim.fn.winsaveview()
      apply_view_horizontal(view, horizontal, #text, default_col)
      vim.fn.winrestview(view)
    end)
  end

  ensure_context_window_leftcol(win)
  return true
end

local function set_change_cursor(
  win,
  line,
  max_line,
  normalize,
  target_topline,
  source_view
)
  if
    not position_change_cursor(
      win,
      line,
      max_line,
      normalize,
      target_topline,
      source_view
    )
  then
    return
  end

  if normalize ~= false then
    sync_window(win)
  end
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
    local buf = vim.api.nvim_win_get_buf(win)
    local line_count = vim.api.nvim_buf_line_count(buf)
    cursor_line = math.min(math.max(1, cursor_line), line_count)

    if cursor_line < 10 then
      vim.cmd("normal! ^")
      return
    end

    local keys = vim.api.nvim_replace_termcodes(
      "zt10<C-y>^",
      true,
      false,
      true
    )

    vim.cmd("normal! " .. keys)

    local text = vim.api.nvim_buf_get_lines(
      buf,
      cursor_line - 1,
      cursor_line,
      false
    )[1] or ""

    local col = (text:find("%S") or 1) - 1

    vim.api.nvim_win_set_cursor(
      win,
      { cursor_line, col }
    )

    local view = vim.fn.winsaveview()
    view.topline = math.max(1, cursor_line - 10)
    view.lnum = cursor_line
    view.col = col
    view.curswant = col
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

select_endpoint = function(endpoint, session, role, group)
  if not valid_endpoint(endpoint) then
    return
  end

  remember_session_role(session, role)
  sidebar_navigating = true
  vim.api.nvim_set_current_tabpage(endpoint.tab)
  vim.api.nvim_set_current_win(endpoint.win)
  show_inspection_path(endpoint.buf)
  sidebar_navigating = false
  apply_inspection_filetype(endpoint.buf, false)

  vim.schedule(function()
    if valid_endpoint(endpoint) then
      apply_inspection_filetype(endpoint.buf, false)
      refresh_buffer_highlighting(endpoint.buf, false)
      trigger_inspection_treesitter_context(endpoint.buf)
    end
  end)

  if group and ensure_inspection_sidebar_on_tab then
    ensure_inspection_sidebar_on_tab(group, endpoint.tab)
  end
end

local function move_cursor_to_line_start(
  win,
  line,
  max_line,
  normalize,
  target_topline,
  source_view
)
  if not win or not vim.api.nvim_win_is_valid(win) then
    return
  end

  local horizontal = {
    leftcol = source_view and source_view.leftcol,
    skipcol = source_view and source_view.skipcol,
    col = source_view and source_view.col,
    coladd = source_view and source_view.coladd,
    curswant = source_view and source_view.curswant,
  }

  if horizontal.leftcol == nil and horizontal.skipcol == nil then
    local current_view = vim.api.nvim_win_call(win, function()
      return vim.fn.winsaveview()
    end)

    horizontal.leftcol = current_view.leftcol
    horizontal.skipcol = current_view.skipcol
    horizontal.col = current_view.col
    horizontal.coladd = current_view.coladd
    horizontal.curswant = current_view.curswant
  end

  if line then
    set_change_cursor(
      win,
      line,
      max_line,
      normalize,
      target_topline,
      source_view
    )
  end

  if normalize ~= false then
    vim.api.nvim_win_call(win, function()
      local buf = vim.api.nvim_win_get_buf(win)
      local current_line = vim.api.nvim_win_get_cursor(win)[1]

      local text = vim.api.nvim_buf_get_lines(
        buf,
        current_line - 1,
        current_line,
        false
      )[1] or ""

      local default_col = (text:find("%S") or 1) - 1
      local view = vim.fn.winsaveview()
      apply_view_horizontal(view, horizontal, #text, default_col)
      vim.fn.winrestview(view)
    end)

    if line then
      sync_window(win)
    end
  end

  ensure_context_window_leftcol(win)
end

local function inspection_chunks(group, session)
  return group.kind == "issue"
      and (session.sections or {})
    or patch.session_hunks(session)
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

local function progressed_chunk_role(group, current_role)
  if group and group.kind == "issue" then
    return "issue"
  end

  return "parent"
end

local function chunk_navigation_role(
  group,
  current_session,
  current_role,
  target_session,
  forward
)
  if group and group.kind == "issue" then
    return "issue"
  end

  if forward then
    return progressed_chunk_role(group, current_role)
  end

  if target_session ~= current_session and target_session and target_session.last_role then
    return target_session.last_role
  end

  return current_role or "parent"
end

local function chunk_start_for_role(
  hunk,
  role,
  change_start
)
  if role == "parent" then
    return patch.hunk_start(hunk, "parent")
  end

  return change_start
end

local function chunk_max_line_for_role(hunk, role, start)
  if not start or not hunk then
    return start
  end

  local count = role == "parent" and hunk.old_count or hunk.new_count
  return start + math.max(0, (count or 1) - 1)
end

local function map_inspection_line(session, source_role, target_role, source_line)
  if not source_line or source_line <= 1 then
    return 1
  end

  if
    not session
    or not session.hunks
    or #session.hunks == 0
    or source_role == target_role
  then
    return source_line
  end

  if session.focused_chunks ~= false and session.focused_start then
    local chunk_index = session.active_chunk or 1
    local hunk = session.hunks[chunk_index]

    if not hunk then
      return source_line
    end

    local parent_start = hunk.old_start == 0 and 1 or hunk.old_start
    local change_start = session.focused_start

    if source_role == "parent" and target_role == "change" then
      if source_line < parent_start then
        return source_line
      elseif source_line < parent_start + math.max(1, hunk.old_count) then
        local offset = source_line - parent_start

        return math.min(
          change_start + offset,
          change_start + math.max(0, (hunk.new_count or 1) - 1)
        )
      else
        local delta = (hunk.new_count or 0) - (hunk.old_count or 0)
        return math.max(1, source_line + delta)
      end
    elseif source_role == "change" and target_role == "parent" then
      if source_line < change_start then
        return source_line
      elseif source_line < change_start + math.max(1, hunk.new_count) then
        local offset = source_line - change_start

        return math.min(
          parent_start + offset,
          parent_start + math.max(0, (hunk.old_count or 1) - 1)
        )
      else
        local delta = (hunk.new_count or 0) - (hunk.old_count or 0)
        return math.max(1, source_line - delta)
      end
    end

    return source_line
  end

  if source_role == "parent" and target_role == "change" then
    local delta = 0

    for _, hunk in ipairs(session.hunks) do
      local old_start = hunk.old_start == 0 and 1 or hunk.old_start
      local old_count = hunk.old_count or 0
      local new_count = hunk.new_count or 0

      if source_line < old_start then
        return math.max(1, source_line + delta)
      elseif source_line < old_start + math.max(1, old_count) then
        local offset = source_line - old_start

        return math.max(
          1,
          hunk.new_start + math.min(offset, math.max(0, new_count - 1))
        )
      else
        delta = delta + (new_count - old_count)
      end
    end

    return math.max(1, source_line + delta)
  elseif source_role == "change" and target_role == "parent" then
    local delta = 0

    for _, hunk in ipairs(session.hunks) do
      local new_start = hunk.new_start == 0 and 1 or hunk.new_start
      local old_count = hunk.old_count or 0
      local new_count = hunk.new_count or 0

      if source_line < new_start then
        return math.max(1, source_line - delta)
      elseif source_line < new_start + math.max(1, new_count) then
        local offset = source_line - new_start

        return math.max(
          1,
          hunk.old_start + math.min(offset, math.max(0, old_count - 1))
        )
      else
        delta = delta + (new_count - old_count)
      end
    end

    return math.max(1, source_line - delta)
  end

  return source_line
end

local function render_chunk_for_role(session, role, chunk_index)
  local hunk = session.hunks and session.hunks[chunk_index] or nil

  if not hunk then
    return
  end

  local change_start = render_focused_chunk(session, chunk_index)
    or patch.focused_hunk_start(hunk)

  return chunk_start_for_role(
    hunk,
    role,
    change_start
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
  local start, max_line

  if group.kind == "issue" then
    session.active_chunk = chunk_index
    start = chunks[chunk_index] and chunks[chunk_index].line
    max_line = start
  else
    local hunk = session.hunks and session.hunks[chunk_index] or nil
    start = render_chunk_for_role(session, role, chunk_index)
    max_line = chunk_max_line_for_role(hunk, role, start)
  end

  select_endpoint(endpoint, session, role, group)

  if start then
    move_cursor_to_line_start(endpoint.win, start, max_line)
  end

  show_inspection_path(endpoint.buf)
  refresh_sidebar(group, endpoint.tab)
  M._refresh_virtual_counters(group, session)
  trigger_inspection_treesitter_context(endpoint.buf)
  return endpoint
end

local function map_file_navigation(endpoint, session, role, group)
  local function select_version(target_role)
    if role == target_role then
      return
    end

    local target = session[target_role]

    if not valid_endpoint(target) then
      return
    end

    local source_win = endpoint.win

    local source_view = (source_win and vim.api.nvim_win_is_valid(source_win))
        and vim.api.nvim_win_call(source_win, function()
          return vim.fn.winsaveview()
        end)
      or session.horizontal_scroll
      or nil

    if source_view then
      session.horizontal_scroll = {
        leftcol = source_view.leftcol,
        skipcol = source_view.skipcol,
        col = source_view.col,
        coladd = source_view.coladd,
        curswant = source_view.curswant,
        topline = source_view.topline,
        lnum = source_view.lnum,
      }
    end

    local chunk_index = session.active_chunk or 1
    local start, max_line

    if group.kind == "issue" then
      local section = session.sections and session.sections[chunk_index]
      start = section and section.line
      max_line = start
    else
      local hunk = session.hunks and session.hunks[chunk_index] or nil
      local raw_start = render_chunk_for_role(session, target_role, chunk_index)

      if type(raw_start) == "number" then
        start = raw_start
      else
        start = 1
      end

      max_line = chunk_max_line_for_role(hunk, target_role, start) or start
    end

    local target_topline = source_view
        and map_inspection_line(session, role, target_role, source_view.topline)
      or nil

    select_endpoint(target, session, target_role, group)
    local target_line = start

    if source_view and source_view.lnum then
      local mapped_lnum = map_inspection_line(
        session,
        role,
        target_role,
        source_view.lnum
      )

      if mapped_lnum and mapped_lnum >= 1 then
        target_line = mapped_lnum
      end
    end

    if target_line then
      move_cursor_to_line_start(
        target.win,
        target_line,
        max_line,
        false,
        target_topline,
        source_view
      )
    elseif source_view and vim.api.nvim_win_is_valid(target.win) then
      vim.api.nvim_win_call(target.win, function()
        local buf = target.buf

        local line = math.min(
          source_view.lnum or 1,
          math.max(1, vim.api.nvim_buf_line_count(buf))
        )

        local text = vim.api.nvim_buf_get_lines(
          buf,
          line - 1,
          line,
          false
        )[1] or ""

        local default_col = (text:find("%S") or 1) - 1
        local view = vim.fn.winsaveview()

        if target_topline then
          view.topline = math.max(1, target_topline)
        elseif source_view.topline then
          view.topline = math.max(1, source_view.topline)
        end

        view.lnum = line
        apply_view_horizontal(view, source_view, #text, default_col)
        vim.fn.winrestview(view)
      end)
    end

    refresh_sidebar(group, target.tab)
    M._refresh_virtual_counters(group, session)
    trigger_inspection_treesitter_context(target.buf)
    ensure_context_window_leftcol(target.win)
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

  M._review.map_keys(endpoint, session, role, group)
end

require("oculus.inspect.counters").setup(M, {
  valid_endpoint = valid_endpoint,
  first_nonblank_line = first_nonblank_line,
  chunk_max_line_for_role = chunk_max_line_for_role,
  chunk_start_for_role = chunk_start_for_role,
  inspection_chunks = inspection_chunks,
})

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
  preferred_role,
  direction
)
  if group and group.kind == "issue" then
    return "issue"
  end

  if direction == 1 then
    return "parent"
  end

  if entry and entry.pair_index ~= active_index then
    local session = group and group[entry.pair_index]

    if direction == -1 then
      return session and session.last_role
        or preferred_role
        or active_role
        or "parent"
    end

    return session and session.last_role
      or preferred_role
      or "parent"
  end

  return preferred_role or active_role or "parent"
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

-- threads is the review thread count label shown after the file name.
local function sidebar_row(file, width, version, threads)
  local prefix = "• "
  local suffix = "P C"
  local version_text = version and (" v.%d"):format(version) or ""
  local thread_text = threads and (" " .. threads) or ""

  local path_width = math.max(
    1,
    width
      - vim.fn.strdisplaywidth(prefix)
      - vim.fn.strdisplaywidth(suffix)
      - vim.fn.strdisplaywidth(version_text)
      - vim.fn.strdisplaywidth(thread_text)
      - 2
  )

  local path = truncate_path(file, path_width)
  local body = prefix .. path .. version_text .. thread_text

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
    thread_column = threads
        and (#prefix + #path + #version_text + 1)
      or nil,
    thread_end_column = threads
        and (#prefix + #path + #version_text + #thread_text)
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
  local first = hunk.source_new_start or hunk.new_start
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

  for _, line in ipairs(review.wrap(
    text,
    width - vim.fn.strdisplaywidth(indent)
  )) do
    lines[#lines + 1] = line == "" and "" or (indent .. line)
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

  if is_pull_request and type(overview.commits) == "table"
    and #overview.commits > 1
  then
    lines[#lines + 1] = "  Commits"

    for _, commit in ipairs(overview.commits) do
      local message = type(commit) == "table"
          and (commit.message
            or (type(commit.commit) == "table" and commit.commit.message))
        or nil

      if type(message) == "string" and vim.trim(message) ~= "" then
        local subject = vim.trim(message):match("^[^\r\n]*")
        append_sidebar_text(lines, "• " .. subject, width, "  ")
      end
    end

    lines[#lines + 1] = ""
  end

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

  if is_pull_request then
    for _, section in ipairs(review.overview_sections(overview)) do
      lines[#lines + 1] = "  " .. section.label

      for _, item in ipairs(section.items) do
        append_sidebar_text(lines, item, width, "  ")
      end

      lines[#lines + 1] = ""
    end
  end

  field(
    "Date",
    overview_date(overview.created_at or details.authored_at)
  )

  if type(overview.local_commit) == "table" then
    local forge = overview.local_commit.forge == "codeberg"
        and "Codeberg"
      or "GitHub"

    field("Source", overview.local_commit.pushed == false
      and "Local clone, not pushed"
      or ("Local clone, not yet listed by %s"):format(forge))
  end

  if overview.remote then
    local context = tonumber(overview.remote_context)

    field("Source", is_issue and "Remote, no local clone"
      or context == math.huge and "Remote, whole changed files"
      or ("Remote, ±%d lines around changes"):format(context or 0))
  end

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

  local index = patch.hunk_index_at_line(session, role, line)

  if index and index ~= session.active_chunk then
    render_focused_chunk(session, index)
    M._refresh_virtual_counters(group, session)
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

  local sidebar_win = group.sidebar_windows
      and group.sidebar_windows[tab]
    or nil

  local sidebar_is_focused = sidebar_win
    and vim.api.nvim_win_is_valid(sidebar_win)
    and vim.api.nvim_get_current_win() == sidebar_win
    and vim.api.nvim_get_current_buf() == buf

  local active_chunk = group[active_index].active_chunk

  if sidebar_is_focused then
    active_chunk = sidebar_chunk(group, group[active_index], active_role)
  end

  vim.api.nvim_buf_clear_namespace(buf, sidebar_ns, 0, -1)

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

      if row.thread_column then
        vim.api.nvim_buf_set_extmark(
          buf,
          sidebar_ns,
          row.line_number - 1,
          row.thread_column,
          {
            end_col = row.thread_end_column,
            hl_group = row.threads_resolved
                and "OculusInspectThreadResolved"
              or "OculusInspectThread",
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

-- Mouse wheel events shift a window by 'mousescroll' lines, which overshoots
-- the compact inspection sidebar; move it a single line per event instead.
local sidebar_mouse_scroll_step = 1

local function sidebar_window_group(win)
  if not win or not vim.api.nvim_win_is_valid(win) then
    return nil
  end

  for _, group in ipairs(sidebar_groups) do
    for _, sidebar_win in pairs(group.sidebar_windows or {}) do
      if sidebar_win == win then
        return group
      end
    end
  end

  return nil
end

local function sidebar_max_topline(win)
  local buf = vim.api.nvim_win_get_buf(win)
  local line_count = vim.api.nvim_buf_line_count(buf)
  local height = vim.api.nvim_win_get_height(win)
  return math.max(1, line_count - height + 1)
end

local function clamp_sidebar_scroll(win)
  if not win or not vim.api.nvim_win_is_valid(win) then
    return false
  end

  local max_topline = sidebar_max_topline(win)
  local changed = false

  vim.api.nvim_win_call(win, function()
    local view = vim.fn.winsaveview()
    local topline = math.max(1, math.min(max_topline, view.topline))

    if topline == view.topline and (view.topfill or 0) == 0 then
      return
    end

    local height = vim.api.nvim_win_get_height(win)
    view.topline = topline
    view.topfill = 0

    view.lnum = math.max(
      topline,
      math.min(topline + height - 1, view.lnum)
    )

    vim.fn.winrestview(view)
    changed = true
  end)

  return changed
end

local function scroll_sidebar_window(win, direction)
  local max_topline = sidebar_max_topline(win)

  vim.api.nvim_win_call(win, function()
    local view = vim.fn.winsaveview()

    local topline = math.max(
      1,
      math.min(
        max_topline,
        view.topline + direction * sidebar_mouse_scroll_step
      )
    )

    if topline == view.topline and (view.topfill or 0) == 0 then
      return
    end

    local height = vim.api.nvim_win_get_height(win)
    view.topline = topline
    view.topfill = 0

    view.lnum = math.max(
      topline,
      math.min(topline + height - 1, view.lnum)
    )

    vim.fn.winrestview(view)
  end)
end

local function mouse_scroll_window()
  local ok, position = pcall(vim.fn.getmousepos)
  local win = ok and position and position.winid or nil

  if not win or win == 0 or not vim.api.nvim_win_is_valid(win) then
    win = vim.api.nvim_get_current_win()
  end

  return win
end

local function mouse_scroll_lines(win)
  local ver = tonumber(string.match(vim.o.mousescroll or "", "ver:(%d+)"))

  if ver == 0 then
    return math.max(1, math.floor(vim.api.nvim_win_get_height(win) / 2))
  end

  return math.max(1, ver or 3)
end

-- Sidebar windows scroll a line at a time and stop at the first and last
-- row; every other window keeps the editor's own wheel behaviour.
local function scroll_window(win, direction)
  if not win or not vim.api.nvim_win_is_valid(win) then
    return
  end

  if sidebar_window_group(win) then
    scroll_sidebar_window(win, direction)
    return
  end

  local keys = vim.api.nvim_replace_termcodes(
    direction > 0 and "<C-e>" or "<C-y>",
    true,
    false,
    true
  )

  pcall(vim.api.nvim_win_call, win, function()
    vim.cmd("normal! " .. mouse_scroll_lines(win) .. keys)
  end)
end

local function scroll_window_under_mouse(direction)
  scroll_window(mouse_scroll_window(), direction)
end

vim.api.nvim_create_autocmd("WinScrolled", {
  group = sync_group,
  callback = function()
    for key in pairs(vim.v.event or {}) do
      local win = tonumber(key)

      if win and sidebar_window_group(win) then
        clamp_sidebar_scroll(win)
      end
    end
  end,
})

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
  vim.wo[win].scrolloff = 0
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
  if group.sidebar_displaced_by_foreign or (group.chunk_view_mode or "sidebar") ~= "sidebar" then
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
  if
    sidebar_navigating
    or not group.sidebar_visible
    or group.sidebar_displaced_by_foreign
    or (group.chunk_view_mode or "sidebar") ~= "sidebar"
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
    group.chunk_view_mode = "sidebar"
    M._clear_virtual_counters(group)

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

-- Per-filetype colorscheme plugins swap the global colorscheme on
-- BufEnter/FileType, and the overview's scratch buffers resolve to their
-- fallback scheme. Pause them while the overview is built or focused so the
-- code's colorscheme stays active.
local suspend_colorscheme = colorscheme.suspend
local resume_colorscheme = colorscheme.resume
local without_colorscheme = colorscheme.without

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

  group.overview_win = nil
  group.overview_buf = nil
  restore_overview_cursor(group)

  if win and vim.api.nvim_win_is_valid(win) then
    vim.api.nvim_win_close(win, true)
  end

  resume_colorscheme(group)

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

local overview_internal = {
  sidebar_ns = sidebar_ns,
  overview_window_is_open = overview_window_is_open,
  append_sidebar_text = append_sidebar_text,
  close_overview_window = close_overview_window,
  without_colorscheme = without_colorscheme,
  hide_overview_cursor = hide_overview_cursor,
  sidebar_overview_lines = sidebar_overview_lines,
  relative_path = relative_path,
}

require("oculus.inspect.overview").setup(M, overview_internal)
local overview_window_config = overview_internal.overview_window_config

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

  if not endpoint
    and group.overview_return
    and group.overview_return.tab
    and vim.api.nvim_tabpage_is_valid(group.overview_return.tab)
  then
    tab = group.overview_return.tab
    vim.api.nvim_set_current_tabpage(tab)
    endpoint = endpoint_for_tab(group, tab)
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

  group.overview_content_width =
    math.max(12, (config.width or 28) - 4)

  suspend_colorscheme(group)
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

  group.overview_scroll_autocmd = vim.api.nvim_create_autocmd(
    { "WinScrolled", "CursorMoved" },
    {
      group = sync_group,
      callback = function()
        if overview_window_is_open(group)
          and vim.api.nvim_get_current_win() == group.overview_win
        then
          M._overview_ui.clamp_scroll(group)
        end
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
        suspend_colorscheme(group)
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
      resume_colorscheme(group)
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

  require("oculus.window").apply_overview_highlights(
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

  vim.keymap.set("n", "d", function()
    M._overview_ui.open_model_picker(group, "explanation")
  end, {
    buffer = buf,
    nowait = true,
    silent = true,
    desc = "Choose Oculus description model",
  })

  if require("oculus.agent").needs_patch_locations(group) then
    vim.keymap.set("n", "w", function()
      M._overview_ui.open_worktree_workflow(group)
    end, {
      buffer = buf,
      nowait = true,
      silent = true,
      desc = "Create Oculus worktree for patch/fix",
    })

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

  vim.keymap.set("n", "r", function()
    M._review.toggle_inline(group)
  end, {
    buffer = buf,
    nowait = true,
    silent = true,
    desc = "Show Oculus review threads in the inspected files",
  })

  vim.keymap.set("n", "v", function()
    group.chunk_view_mode = "virtual"
    close_inspection_sidebar(group)
    M._refresh_virtual_counters(group)
    show_sidebar_files(group)
  end, {
    buffer = buf,
    nowait = true,
    silent = true,
    desc = "Switch to Oculus Inspect virtual chunk counter mode",
  })

  vim.keymap.set("n", "s", function()
    group.chunk_view_mode = "sidebar"
    M._clear_virtual_counters(group)
    open_inspection_sidebar(group)
    show_sidebar_files(group)
  end, {
    buffer = buf,
    nowait = true,
    silent = true,
    desc = "Switch to Oculus Inspect sidebar mode",
  })

  vim.keymap.set("n", "e", function()
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
    desc = "Exit Oculus Inspect workflow",
  })

  vim.keymap.set("n", "c", function()
    show_sidebar_files(group)
  end, {
    buffer = buf,
    nowait = true,
    silent = true,
    desc = "Close Oculus Inspect overview",
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

  local nav = require("oculus.navigation").resolve({
    navigation = group.navigation,
  })

  map_scroll(nav.down, 1, "Scroll Oculus Inspect overview down")
  map_scroll("<Down>", 1, "Scroll Oculus Inspect overview down")
  map_scroll(nav.up, -1, "Scroll Oculus Inspect overview up")
  map_scroll("<Up>", -1, "Scroll Oculus Inspect overview up")
  map_scroll("<C-" .. nav.down .. ">", 10, "Scroll Oculus Inspect overview down 10 lines")

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
  local lifecycle = group.inspection_lifecycle

  if lifecycle and type(lifecycle.on_overview_opened) == "function" then
    lifecycle.on_overview_opened(group)
  end
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

  if (group.chunk_view_mode or "sidebar") ~= "sidebar" then
    close_inspection_sidebar(group)
    M._refresh_virtual_counters(group)
  end

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

    for lhs, direction in pairs({
      ["<ScrollWheelDown>"] = 1,
      ["<ScrollWheelUp>"] = -1,
    }) do
      vim.keymap.set("n", lhs, function()
        scroll_window_under_mouse(direction)
      end, {
        buffer = buf,
        nowait = true,
        silent = true,
        desc = direction > 0
            and "Scroll the window under the mouse down"
          or "Scroll the window under the mouse up",
      })
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

  vim.keymap.set("n", "<CR>", function()
    focus_sidebar_selection(group)
  end, {
    buffer = group.sidebar_buf,
    nowait = true,
    silent = true,
    desc = "Open Oculus Inspect sidebar item",
  })

  if group.kind == "issue" and group.queue_info and (group.queue_info.total or 0) > 1 then
    vim.keymap.set("n", "<C-Tab>", function()
      local lifecycle = group.inspection_lifecycle

      if lifecycle and type(lifecycle.on_next_queue_item) == "function" then
        lifecycle.on_next_queue_item(group)
      end
    end, {
      buffer = group.sidebar_buf,
      nowait = true,
      silent = true,
      desc = "Next Oculus inspect queue item",
    })

    for _, prev_lhs in ipairs({ "<S-Tab>", "<C-S-Tab>" }) do
      vim.keymap.set("n", prev_lhs, function()
        local lifecycle = group.inspection_lifecycle

        if lifecycle and type(lifecycle.on_previous_queue_item) == "function" then
          lifecycle.on_previous_queue_item(group)
        end
      end, {
        buffer = group.sidebar_buf,
        nowait = true,
        silent = true,
        desc = "Previous Oculus inspect queue item",
      })
    end
  else
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

  group.chunk_view_mode = group.chunk_view_mode or "sidebar"
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
  group.chunk_view_mode = group.chunk_view_mode or "sidebar"
  map_inspection_sidebar_toggle(group)
  sidebar_groups[#sidebar_groups + 1] = group

  if group.chunk_view_mode == "sidebar" and open_immediately ~= false then
    open_inspection_sidebar(group)
  else
    M._refresh_virtual_counters(group)
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
  group.colorscheme_suspended = nil
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
    local patch_repo = patch.repository or repository
    local patch_dir = patch.directory or patch_repo

    group[index] = {
      file = patch.path,
      repository = patch_repo,
      directory = patch_dir,
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

    if patch.buf and vim.api.nvim_buf_is_valid(patch.buf) then
      vim.bo[patch.buf].buftype = ""
      vim.bo[patch.buf].modifiable = true
      vim.bo[patch.buf].readonly = false
      vim.b[patch.buf].oculus_inspect_repository = patch_repo
      vim.b[patch.buf].oculus_inspect_directory = patch_dir
    end
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
  local line_count = vim.api.nvim_buf_line_count(buf)

  return (" %s%%= %d(%d),%d "):format(
    path:gsub("%%", "%%%%"),
    cursor[1],
    line_count,
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
      if group.chunk_view_mode ~= "virtual" or entry.chunk_index ~= nil then
        break
      end
    end
  end

  if not entry or (group.chunk_view_mode == "virtual" and not entry.chunk_index) then
    return
  end

  local session = group[entry.pair_index]

  local role = sidebar_target_role(
    active_index,
    active_role,
    entry,
    group,
    preferred_role,
    direction
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
      local hunk = (group.kind ~= "issue" and session.hunks)
          and session.hunks[entry.chunk_index]
        or nil

      local start, max_line

      if group.kind == "issue" then
        local section = session.sections[entry.chunk_index]
        start = section and section.line
        max_line = start
      else
        start = render_chunk_for_role(
          session,
          role,
          entry.chunk_index
        )

        max_line = chunk_max_line_for_role(hunk, role, start)
      end

      if start then
        move_cursor_to_line_start(endpoint.win, start, max_line)
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

    if entry.chunk_index then
      session.active_chunk = entry.chunk_index
    end

    M._refresh_virtual_counters(group, session)
    trigger_inspection_treesitter_context(endpoint.buf)
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
    local max_line = chunk_max_line_for_role(hunk, role, start)
    move_cursor_to_line_start(endpoint.win, start, max_line)
  elseif section then
    move_cursor_to_line_start(endpoint.win, section.line, section.line)
  else
    if group.kind ~= "issue" then
      render_full_file(session)
    end

    show_file_top(endpoint.win)
  end

  if chunk_index then
    session.active_chunk = chunk_index
  end

  show_inspection_path(endpoint.buf)
  refresh_sidebar(group, endpoint.tab)
  M._refresh_virtual_counters(group, session)
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

  local source_endpoint = session and session[role] or nil
  local source_code_win = source_endpoint and source_endpoint.win

  local source_code_view = (source_code_win and vim.api.nvim_win_is_valid(source_code_win))
      and vim.api.nvim_win_call(source_code_win, function()
        return vim.fn.winsaveview()
      end)
    or nil

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
  local chunk_index = entry and entry.chunk_index or session.active_chunk or 1
  local start, max_line

  if group.kind == "issue" then
    local section = session.sections and session.sections[chunk_index]
    start = section and section.line
    max_line = start
  else
    local hunk = session.hunks and session.hunks[chunk_index] or nil

    start = render_chunk_for_role(session, target_role, chunk_index)
      or (target_role == "parent"
        and session.parent_lines and session.parent_lines[1]
        or session.change_lines and session.change_lines[1])

    max_line = chunk_max_line_for_role(hunk, target_role, start)
  end

  local target_topline = source_code_view
      and map_inspection_line(session, role, target_role, source_code_view.topline)
    or nil

  if start and valid_endpoint(endpoint) then
    move_cursor_to_line_start(
      endpoint.win,
      start,
      max_line,
      false,
      target_topline,
      source_code_view
    )
  end

  refresh_sidebar(group, endpoint.tab)
  M._refresh_virtual_counters(group, session)
  sidebar_navigating = false
  trigger_inspection_treesitter_context(endpoint.buf)

  vim.schedule(function()
    if valid_endpoint(endpoint) then
      refresh_buffer_highlighting(endpoint.buf, false)
      trigger_inspection_treesitter_context(endpoint.buf)
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
        local current_win = vim.api.nvim_get_current_win()

        local current_view = (current_win and vim.api.nvim_win_is_valid(current_win))
            and vim.api.nvim_win_call(current_win, function()
              return vim.fn.winsaveview()
            end)
          or nil

        M._tab_navigation_source = {
          group = group,
          index = index,
          role = role,
          view = current_view,
        }

        local session = group[index]

        if session and current_view then
          session.horizontal_scroll = {
            leftcol = current_view.leftcol,
            skipcol = current_view.skipcol,
            col = current_view.col,
            coladd = current_view.coladd,
            curswant = current_view.curswant,
            topline = current_view.topline,
            lnum = current_view.lnum,
          }
        end

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

        local index, role = sidebar_active_item(group, tab)

        if
          source
          and source.group == group
          and source.index == index
          and source.role ~= role
          and source.view
          and vim.api.nvim_win_is_valid(endpoint.win)
        then
          vim.api.nvim_win_call(endpoint.win, function()
            local buf = endpoint.buf
            local current_line = vim.api.nvim_win_get_cursor(endpoint.win)[1]

            local text = vim.api.nvim_buf_get_lines(
              buf,
              current_line - 1,
              current_line,
              false
            )[1] or ""

            local default_col = (text:find("%S") or 1) - 1
            local view = vim.fn.winsaveview()
            apply_view_horizontal(view, source.view, #text, default_col)
            vim.fn.winrestview(view)
            ensure_context_window_leftcol(endpoint.win)
          end)
        end

        trigger_inspection_treesitter_context(endpoint.buf)
        ensure_context_window_leftcol(endpoint.win)
      end

      refresh_sidebar(group, tab)

      if (group.chunk_view_mode or "sidebar") ~= "sidebar" then
        M._refresh_virtual_counters(group)
      end
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

  if session.excerpt then
    comment.line = patch.excerpt_line(session.excerpt[role], comment.line)
  end

  local chunk_index =
    patch.revision_hunk_index_at_line(session, role, comment.line)

  if chunk_index then
    local hunks = patch.session_hunks(session)
    local hunk = hunks[chunk_index]
    local revision_start = patch.hunk_start(hunk, role)
    local offset = math.max(0, comment.line - revision_start)

    local focused_start =
      render_focused_chunk(session, chunk_index)
        or patch.focused_hunk_start(hunk)

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

  local working_directory = (path and path ~= "")
      and git.inspection_directory(path, file)
    or vim.fn.getcwd()

  if working_directory and working_directory ~= "" then
    pcall(vim.cmd, "tcd " .. vim.fn.fnameescape(working_directory))
  end

  -- Until the filetype is known, a per-filetype colorscheme plugin resolves
  -- the buffer to its empty scheme; apply_inspection_filetype picks the right
  -- one below.
  local buf = without_colorscheme(function()
    vim.cmd("enew")
    local new_buf = vim.api.nvim_get_current_buf()
    vim.bo[new_buf].buftype = "nofile"
    return new_buf
  end)

  local initial_undolevels = vim.bo[buf].undolevels
  vim.bo[buf].undolevels = -1

  local lines = role == "change"
      and inspection.change_lines
    or inspection.parent_lines

  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines or { "" })
  vim.bo[buf].bufhidden = "hide"
  vim.bo[buf].swapfile = false
  vim.bo[buf].modifiable = true
  vim.bo[buf].readonly = false
  local filetype = inspection.filetype

  if not filetype and file then
    local ok, match = pcall(vim.filetype.match, {
      buf = buf,
      filename = file,
      contents = lines,
    })

    if ok and type(match) == "string" and match ~= "" then
      filetype = match
    end
  end

  if not filetype and inspection.parent_lines then
    local ok, match = pcall(vim.filetype.match, {
      filename = file or inspection.parent_file,
      contents = inspection.parent_lines,
    })

    if ok and type(match) == "string" and match ~= "" then
      filetype = match
    end
  end

  if not filetype and inspection.change_lines then
    local ok, match = pcall(vim.filetype.match, {
      filename = file or inspection.change_file,
      contents = inspection.change_lines,
    })

    if ok and type(match) == "string" and match ~= "" then
      filetype = match
    end
  end

  if filetype then
    inspection.filetype = filetype
    vim.bo[buf].filetype = filetype
  end

  vim.b[buf].oculus_inspect_repository = path
  vim.b[buf].oculus_inspect_directory = working_directory

  vim.b[buf].oculus_inspect_source_path =
    (file and path and path ~= "") and vim.fs.joinpath(path, file) or nil

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
    source_path = (file and path and path ~= "") and vim.fs.joinpath(path, file) or nil,
    filetype = filetype,
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
  apply_inspection_filetype(buf, false)
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
  -- The empty tab buffer would otherwise switch a per-filetype colorscheme
  -- plugin to its empty scheme.
  without_colorscheme(function()
    vim.cmd("tabnew")
  end)

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

  set_change_highlights()

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
  vim.wo[win].signcolumn = "yes"
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
  ensure_treesitter_safeguards()

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
      queue_info = loading and loading.lifecycle
        and loading.lifecycle.queue_info,
      sidebar_toggle = opts.inspect_sidebar_toggle,
      sidebar_width_proportion = opts.inspect_sidebar_width,
      overview_toggle = opts.inspect_overview_toggle,
      navigation = opts.navigation,
      old_version = opts.inspect_old_version,
      new_version = opts.inspect_new_version,
      next_chunk = opts.inspect_next_chunk,
      previous_chunk = opts.inspect_previous_chunk,
      next_thread = opts.inspect_next_thread,
      previous_thread = opts.inspect_previous_thread,
      thread_open = opts.inspect_thread,
      chunk_threads = opts.inspect_chunk_threads,
      chunk_view_mode = opts.chunk_view_mode
        or opts.inspect_chunk_view_mode
        or "sidebar",
      overview = inspection_overview(info),
      browser_config = { browser_command = opts.browser_command },
      persist_inspect_overviews = opts.persist_inspect_overviews ~= false,
      inspect_overviews = opts.inspect_overviews or {},
      state_file = opts.state_file,
      persistence_config = opts,
      overview_window_config = vim.tbl_extend(
        "force",
        opts.window_config or require("oculus.window").window_config(opts),
        opts.exact_dimensions and { exact_dimensions = true } or {}
      ),
    }

    if info and info.kind == "pull_request" then
      inspection_sessions.overview.review = { loading = true }
    end

    for index, paths in ipairs(inspections) do
      local hunks = paths.hunks
        or patch.session_hunks(paths)

      inspection_sessions[index] = {
        file = paths.change_file or paths.parent_file,
        filetype = paths.filetype,
        parent_file = paths.parent_file,
        change_file = paths.change_file,
        parent_commit = paths.parent,
        change_commit = paths.commit,
        commit_index = paths.commit_index,
        parent_repository = paths.repository,
        change_repository = paths.repository,
        changes = paths.changes,
        hunks = hunks,
        parent_content = vim.deepcopy(paths.parent_lines),
        change_content = vim.deepcopy(paths.change_lines),
        patch = paths.patch,
        status = paths.status,
        remote = paths.remote,
        excerpt = paths.excerpt,
        parent_lines = patch.change_lines(hunks, "parent"),
        change_lines = patch.change_lines(hunks),
        active_chunk = hunks[1] and 1 or nil,
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

      local repo = paths.repository
        or (info and info.repository)
        or (inspection_sessions[1] and inspection_sessions[1].parent_repository)
        or nil

      local parent = load_tab(
        parent_tab,
        repo,
        paths.parent_file,
        paths.parent_role or "parent",
        paths,
        index
      )

      apply_inspection_window_options(parent.win, number_options)
      local change_tab = make_inspection_tab()

      local change = load_tab(
        change_tab,
        repo,
        paths.change_file,
        "change",
        paths,
        index
      )

      apply_inspection_window_options(change.win, number_options)
      next_session = next_session + 1
      session.parent = parent
      session.change = change

      session.filetype = session.filetype
        or (parent and parent.buf and vim.bo[parent.buf].filetype ~= "" and vim.bo[parent.buf].filetype)
        or (change and change.buf and vim.bo[change.buf].filetype ~= "" and vim.bo[change.buf].filetype)
        or nil

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
        local parent_start = chunk_start_for_role(
          first_hunk,
          "parent",
          focused_start
        )

        local parent_max = chunk_max_line_for_role(
          first_hunk,
          "parent",
          parent_start
        )

        move_cursor_to_line_start(
          parent.win,
          parent_start,
          parent_max
        )

        local change_start = chunk_start_for_role(
          first_hunk,
          "change",
          focused_start
        )

        local change_max = chunk_max_line_for_role(
          first_hunk,
          "change",
          change_start
        )

        move_cursor_to_line_start(
          change.win,
          change_start,
          change_max
        )
      elseif session.parent_lines[1] then
        local parent_hunk = session.hunks and session.hunks[1]

        local parent_max = chunk_max_line_for_role(
          parent_hunk,
          "parent",
          session.parent_lines[1]
        )

        move_cursor_to_line_start(
          parent.win,
          session.parent_lines[1],
          parent_max
        )
      else
        sync_window(parent.win)
      end
    end

    restore_staging_window()
    activate_inspection_sidebar(inspection_sessions)

    for _, session in ipairs(inspection_sessions) do
      local first_hunk = session.active_chunk
          and session.hunks[session.active_chunk]
        or nil

      if session.focused_start and first_hunk then
        local change_start = chunk_start_for_role(
          first_hunk,
          "change",
          session.focused_start
        )

        local change_max = chunk_max_line_for_role(
          first_hunk,
          "change",
          change_start
        )

        move_cursor_to_line_start(
          session.change.win,
          change_start,
          change_max
        )

        local parent_start = chunk_start_for_role(
          first_hunk,
          "parent",
          session.focused_start
        )

        local parent_max = chunk_max_line_for_role(
          first_hunk,
          "parent",
          parent_start
        )

        move_cursor_to_line_start(
          session.parent.win,
          parent_start,
          parent_max
        )
      elseif session.parent_lines and session.parent_lines[1] then
        if session.change_lines and session.change_lines[1] then
          local change_hunk = session.hunks and session.hunks[1]

          local change_max = chunk_max_line_for_role(
            change_hunk,
            "change",
            session.change_lines[1]
          )

          move_cursor_to_line_start(
            session.change.win,
            session.change_lines[1],
            change_max
          )
        else
          move_cursor_to_line_start(session.change.win)
        end

        local parent_hunk = session.hunks and session.hunks[1]

        local parent_max = chunk_max_line_for_role(
          parent_hunk,
          "parent",
          session.parent_lines[1]
        )

        move_cursor_to_line_start(
          session.parent.win,
          session.parent_lines[1],
          parent_max
        )
      else
        move_cursor_to_line_start(session.change.win)
        move_cursor_to_line_start(session.parent.win)
      end
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

    local first_session = inspection_sessions[1]

    local first_hunk = first_session
        and first_session.active_chunk
        and first_session.hunks
        and first_session.hunks[first_session.active_chunk]
      or nil

    local first_start = first_hunk
        and chunk_start_for_role(
          first_hunk,
          "parent",
          first_session.focused_start
        )
      or (first_session and first_session.parent_lines and first_session.parent_lines[1])

    local first_max = chunk_max_line_for_role(
      first_hunk,
      "parent",
      first_start
    )

    stop_loading(loading)
    require("oculus.window").close()
    vim.api.nvim_set_current_tabpage(first.tab)
    vim.api.nvim_set_current_win(first.win)
    set_change_highlights()

    for _, s in ipairs(inspection_sessions) do
      if s.parent and s.parent.buf and vim.api.nvim_buf_is_valid(s.parent.buf) then
        refresh_buffer_highlighting(s.parent.buf, true)
      end

      if s.change and s.change.buf and vim.api.nvim_buf_is_valid(s.change.buf) then
        refresh_buffer_highlighting(s.change.buf, true)
      end
    end

    if first_session and first_session.active_chunk and first_hunk then
      apply_change_signs(first_session.parent.buf, first_session.change.buf, {
        {
          old_start = first_hunk.old_start,
          old_count = first_hunk.old_count,
          new_start = first_session.focused_start or first_start,
          new_count = first_hunk.new_count,
        },
      }, first_session.status)
    elseif first_session then
      apply_change_signs(
        first_session.parent.buf,
        first_session.change.buf,
        first_session.hunks or {},
        first_session.status
      )
    end

    move_cursor_to_line_start(first.win, first_start, first_max)
    show_inspection_path(first.buf)
    M._refresh_virtual_counters(inspection_sessions, first_session)
    trigger_inspection_treesitter_context(first.buf)
    M._enable_inspection_treesitter_context(opts)
    vim.cmd("redraw")

    if loading
      and loading.lifecycle
      and loading.lifecycle.overview_on_open
    then
      show_inspection_overview(inspection_sessions)
    end

    M._review.load(inspection_sessions, info, opts)
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

local prepare_module = require("oculus.inspect.prepare").setup(M)
local blob_lines = prepare_module.blob_lines
local prepare = prepare_module.prepare
local apply_pull_request = prepare_module.apply_pull_request

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

      local resolved = apply_pull_request(info, details)

      if type(provider.pull_request_commits) ~= "function" then
        callback(resolved)
        return
      end

      provider.pull_request_commits(
        info.owner .. "/" .. info.repo,
        info.number,
        opts,
        function(commits)
          resolved.commits = commits or {}
          callback(resolved)
        end
      )
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
      queue_info = loading and loading.lifecycle
        and loading.lifecycle.queue_info,
      sidebar_toggle = opts.inspect_sidebar_toggle,
      sidebar_width_proportion = opts.inspect_sidebar_width,
      overview_toggle = opts.inspect_overview_toggle,
      navigation = opts.navigation,
      old_version = opts.inspect_old_version,
      new_version = opts.inspect_new_version,
      next_chunk = opts.inspect_next_chunk,
      previous_chunk = opts.inspect_previous_chunk,
      chunk_view_mode = opts.chunk_view_mode
        or opts.inspect_chunk_view_mode
        or "sidebar",
      overview = inspection_overview(resolved),
      browser_config = { browser_command = opts.browser_command },
      persist_inspect_overviews = opts.persist_inspect_overviews ~= false,
      inspect_overviews = opts.inspect_overviews or {},
      state_file = opts.state_file,
      persistence_config = opts,
      overview_window_config = vim.tbl_extend(
        "force",
        opts.window_config or require("oculus.window").window_config(opts),
        opts.exact_dimensions and { exact_dimensions = true } or {}
      ),
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

    if group.queue_info and (group.queue_info.total or 0) > 1 then
      vim.keymap.set("n", "<C-Tab>", function()
        local lifecycle = group.inspection_lifecycle

        if lifecycle and type(lifecycle.on_next_queue_item) == "function" then
          lifecycle.on_next_queue_item(group)
        end
      end, {
        buffer = buf,
        nowait = true,
        silent = true,
        desc = "Next Oculus inspect queue item",
      })

      for _, prev_lhs in ipairs({ "<S-Tab>", "<C-S-Tab>" }) do
        vim.keymap.set("n", prev_lhs, function()
          local lifecycle = group.inspection_lifecycle

          if lifecycle and type(lifecycle.on_previous_queue_item) == "function" then
            lifecycle.on_previous_queue_item(group)
          end
        end, {
          buffer = buf,
          nowait = true,
          silent = true,
          desc = "Previous Oculus inspect queue item",
        })
      end
    end

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

    git.ensure_repository(info, opts, function(
      repository,
      repository_err,
      _,
      remote
    )
      if not repository then
        done(nil, repository_err or "could not find the issue repository")
        return
      end

      info.remote = remote or nil

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

  local info = patch.parse_target_url(url)

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

      git.ensure_repository(info, opts or {}, function(
        repository,
        repo_err,
        _,
        remote
      )
        if not repository then
          failed(repo_err)
          return
        end

        info.remote = remote or nil

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
  local info = type(url) == "table" and url or patch.parse_target_url(url)

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

  if type(context) == "table" and type(context.local_commit) == "table" then
    info.local_commit = vim.deepcopy(context.local_commit)
    context = nil
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
      prepared_info.local_commit = info.local_commit

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

local function sidebar_group_for_session(session)
  for _, group in ipairs(sidebar_groups) do
    for _, candidate in ipairs(group) do
      if candidate == session then
        return group
      end
    end
  end
end

local oil = require("oculus.inspect.oil").setup(M, {
  oil_group = oil_group,
  sidebar_group_for_session = sidebar_group_for_session,
  oil_ns = oil_ns,
  oil_contexts = oil_contexts,
  oil_window_contexts = oil_window_contexts,
  rendered_treesitter_contexts = rendered_treesitter_contexts,
  sidebar_groups = sidebar_groups,
  comparable_path = comparable_path,
  change_path_for_role = change_path_for_role,
  session_for_directory = session_for_directory,
  session_directory = session_directory,
  close_inspection_sidebar = close_inspection_sidebar,
  open_inspection_sidebar = open_inspection_sidebar,
  restore_inspection_sidebar_for_buffer = restore_inspection_sidebar_for_buffer,
  valid_endpoint = valid_endpoint,
  select_endpoint = select_endpoint,
})

require("oculus.inspect.review_ui").setup(M, {
  valid_endpoint = valid_endpoint,
  refresh_sidebar = refresh_sidebar,
  overview_window_is_open = overview_window_is_open,
  sidebar_group_for_session = sidebar_group_for_session,
  render_full_file = render_full_file,
  render_focused_chunk = render_focused_chunk,
  move_cursor_to_line_start = move_cursor_to_line_start,
  chunk_max_line_for_role = chunk_max_line_for_role,
  focus_inspection_chunk = focus_inspection_chunk,
  select_endpoint = select_endpoint,
  set_change_cursor = set_change_cursor,
  map_inspection_line = map_inspection_line,
  sidebar_row = sidebar_row,
  sidebar_file = sidebar_file,
})

M.inspect_by_id = target.inspect_by_id
M._parse_target = target.parse
M._resolve_repository = target.resolve_repository
M._resolve_target_url = target.resolve_target_url
M._parse_commit_url = patch.parse_commit_url
M._parse_pull_request_url = patch.parse_pull_request_url
M._parse_issue_url = patch.parse_issue_url
M._parse_target_url = patch.parse_target_url
M._parse_commit_overview = patch.parse_commit_overview
M.activity_comment = patch.activity_comment
M.activity_context = patch.activity_context
M._apply_pull_request = apply_pull_request
M._inspection_overview = inspection_overview
M._sidebar_overview_lines = sidebar_overview_lines
M._overview_window_config = overview_window_config
M._first_changed_paths = patch.first_changed_paths
M._parse_changed_files = patch.parse_changed_files
M._inspection_directory = git.inspection_directory
M._github_repository = git.github_repository
M._forge_repository = git.forge_repository
M._find_local_repository = git.find_local_repository
M._ensure_repository = git.ensure_repository
M._remote_repository_path = git.remote_repository_path
M._excerpt = patch.excerpt
M._excerpt_line = patch.excerpt_line
M._prepare = prepare
M._parse_hunks = patch.parse_hunks
M._parse_revision_pairs = patch.parse_revision_pairs
M._blob_lines = blob_lines
M._oil_entry_status = oil.entry_status
M._entered_oil_subdirectory = oil.entered_subdirectory
M._first_changed_oil_file_line = oil.first_changed_file_line
M._change_lines = patch.change_lines
M._focused_change_lines = patch.focused_change_lines
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

M._map_concurrently = git.map_concurrently
M._sort_inspections = sort_inspections
M._sidebar_row = sidebar_row
M._inspect_sidebar_width = inspect_sidebar_width
M._sidebar_chunk_row = sidebar_chunk_row
M._sidebar_file = sidebar_file
M._sidebar_target_role = sidebar_target_role
M._progressed_chunk_role = progressed_chunk_role
M._chunk_navigation_role = chunk_navigation_role
M._chunk_start_for_role = chunk_start_for_role
M._chunk_max_line_for_role = chunk_max_line_for_role
M._map_inspection_line = map_inspection_line
M._first_nonblank_line = first_nonblank_line
M._position_change_cursor = position_change_cursor
M._move_cursor_to_line_start = move_cursor_to_line_start
M._select_endpoint = select_endpoint
M._render_chunk_for_role = render_chunk_for_role
M._is_foreign_sidebar_window = is_foreign_sidebar_window
M._inspection_endpoints = inspection_endpoints
M._comment_float = comment_float
M._trigger_inspection_treesitter_context = trigger_inspection_treesitter_context
M._set_change_highlights = set_change_highlights
M._change_ns = change_ns
M._rendered_treesitter_contexts = rendered_treesitter_contexts
M._sidebar_chunk = sidebar_chunk
M._sidebar_window_group = sidebar_window_group
M._scroll_sidebar_window = scroll_sidebar_window
M._scroll_window = scroll_window
M._clamp_sidebar_scroll = clamp_sidebar_scroll
M._scroll_window_under_mouse = scroll_window_under_mouse
M._ensure_treesitter_safeguards = ensure_treesitter_safeguards
M._apply_view_horizontal = apply_view_horizontal
M._ensure_context_window_leftcol = ensure_context_window_leftcol
M._open_tabs = open_tabs
M._show_inspection_overview = show_inspection_overview
M._close_overview_window = close_overview_window

function M.restore_group(group)
  if group then
    show_inspection_overview(group)
  end
end

return M
