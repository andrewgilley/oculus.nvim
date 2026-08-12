local M = {}

local actions = require("oculus.actions")
local browser = require("oculus.browser")
local github = require("oculus.github")
local inspect = require("oculus.inspect")

-- AGENT_CHANGE_BEGIN codeberg-andrew-kelley-20260727 7 Add contributor activity-provider helpers
local codeberg = require("oculus.codeberg")

local function activity_provider(contributor)
  if contributor and contributor.provider == "codeberg" then
    return codeberg
  end
  return github
end

local function provider_name(contributor)
  return contributor and contributor.provider == "codeberg"
      and "Codeberg"
    or "GitHub"
end

local function contributor_profile_url(contributor)
  local host = contributor and contributor.provider == "codeberg"
      and "https://codeberg.org/"
    or "https://github.com/"
  return host .. vim.uri_encode(contributor.username)
end
-- AGENT_CHANGE_END codeberg-andrew-kelley-20260727 7

local ns = vim.api.nvim_create_namespace("oculus")
local preview_ns = vim.api.nvim_create_namespace("oculus_preview")
local contributor_selection_ns = vim.api.nvim_create_namespace(
  "oculus_contributor_selection"
)
local inspect_loading_ns = vim.api.nvim_create_namespace(
  "oculus_inspect_activity_loading"
)
local activity_page_loading_ns = vim.api.nvim_create_namespace(
  "oculus_activity_page_loading"
)
local activity_inspect_queue_ns = vim.api.nvim_create_namespace(
  "oculus_activity_inspect_queue"
)
local window_highlight_ns = vim.api.nvim_create_namespace(
  "oculus_window_highlights"
)
local window_highlight_groups = {
  "Normal",
  "NormalFloat",
  "FloatBorder",
  "FloatTitle",
  "FloatFooter",
  "CursorLine",
  "Title",
  "Comment",
  "Identifier",
  "Function",
  "Special",
  "DiagnosticError",
  "DiagnosticWarn",
  "DiagnosticInfo",
  "WinSeparator",
  "OculusInspectOverviewSection",
  "OculusInspectAgentModelSelected",
}
local commit_activity_url
local load_project_activity
local load_project_issues
local show_activity_search_page
local ensure_activity_search_results
local start_activity_search
local target_on_cursor
local default_project_activity_types = {
  "push",
  "merged_pull_request",
  "assigned_issue",
}
local project_activity_categories = {
  { key = "push", label = "Pushed commits" },
  { key = "merged_pull_request", label = "Merged pull requests" },
  { key = "assigned_issue", label = "Assigned issues" },
}

local function project_activity_types_for(project)
  if project.activity_types ~= nil then
    return project.activity_types
  end
  return M.state.opts.project_activity_types
    or default_project_activity_types
end
local autocmd_group = vim.api.nvim_create_augroup(
  "OculusWindow",
  { clear = true }
)

M.state = {
  buf = nil,
  win = nil,
  footer_buf = nil,
  footer_win = nil,
  view = "contributors",
  contributor = nil,
  activity_scope = nil,
  activity_project = nil,
  events = nil,
  line_targets = {},
  inspect_targets = {},
  activity_title_lines = {},
  activity_expansion_targets = {},
  request_id = 0,
  preview_key = nil,
  preview_items = nil,
  preview_contributor = nil,
  preview_project = nil,
  contributors = {},
  community_view = "projects",
  selected_username = nil,
  selected_project = nil,
  contributor_offset = 1,
  filter_scope = nil,
  activity_cached = nil,
  activity_notice = nil,
  activity_error = nil,
  activity_loaded = false,
  activity_page = 1,
  activity_loaded_pages = 1,
  activity_page_size = 8,
  activity_source_events = nil,
  activity_has_past = nil,
  project_activity_feed = nil,
  activity_cursor_min_line = 1,
  activity_scroll_limit_line = nil,
  activity_commit_page = false,
  activity_issue_page = false,
  activity_return = nil,
  project_issue_return = nil,
  project_issue_feed = nil,
  activity_inspect_queue = {},
  activity_inspect_queue_lookup = {},
  activity_inspect_queue_scope = nil,
  activity_inspect_queue_running = false,
  activity_search_query = nil,
  activity_search_results = nil,
  activity_search_return = nil,
  activity_search_feed = nil,
  activity_loading_timer = nil,
  activity_loading_frame = 1,
  restore_cursor = nil,
  restore_view = nil,
  shortcut_return = nil,
  search_buf = nil,
  search_win = nil,
  search_query = nil,
  search_kind = nil,
  search_backspace_pending = false,
  search_results = nil,
  search_index = 1,
  search_return = nil,
  opening_search = false,
  closing_search = false,
  opening_account_prompt = false,
  origin_tab = nil,
  origin_win = nil,
  origin_view = nil,
  origin_window_options = nil,
  highlight_source_win = nil,
  highlight_generation = 0,
  opts = {},
}

local function is_valid_win(win)
  return win and vim.api.nvim_win_is_valid(win)
end

local function is_valid_buf(buf)
  return buf and vim.api.nvim_buf_is_valid(buf)
end

local function window_highlight_name(win, group)
  if not is_valid_win(win) then
    return group
  end
  for mapping in vim.wo[win].winhighlight:gmatch("[^,]+") do
    local source, target = mapping:match("^%s*([^:]+):([^:]+)%s*$")
    if source == group and target and target ~= "" then
      return target
    end
  end
  return group
end

local function source_highlight(win, group)
  local name = window_highlight_name(win, group)
  if is_valid_win(win) then
    local namespace = vim.api.nvim_get_hl_ns({ winid = win })
    if namespace and namespace > 0 then
      local ok, definition = pcall(
        vim.api.nvim_get_hl,
        namespace,
        { name = name, link = false }
      )
      if ok and next(definition) then
        return definition
      end
    end
  end
  local ok, definition = pcall(
    vim.api.nvim_get_hl,
    0,
    { name = name, link = false }
  )
  if ok and next(definition) then
    return definition
  end
  return vim.api.nvim_get_hl(0, { name = group, link = false })
end

local function sync_window_highlights(source_win)
  local current_normal = {}
  local current_border = {}
  for _, group in ipairs(window_highlight_groups) do
    local definition = source_highlight(source_win, group)
    vim.api.nvim_set_hl(window_highlight_ns, group, definition)
    if group == "Normal" then
      current_normal = vim.deepcopy(definition)
    elseif group == "FloatBorder" then
      current_border = vim.deepcopy(definition)
    end
  end

  vim.api.nvim_set_hl(
    window_highlight_ns,
    "OculusNormal",
    current_normal
  )
  vim.api.nvim_set_hl(
    window_highlight_ns,
    "NormalFloat",
    current_normal
  )
  vim.api.nvim_set_hl(0, "OculusNormal", current_normal)
  if not current_border.fg then
    current_border.fg = current_normal.fg or 0xffffff
  end
  current_border.bg = current_normal.bg
  current_border.ctermbg = current_normal.ctermbg
  vim.api.nvim_set_hl(
    window_highlight_ns,
    "OculusBorder",
    current_border
  )
  vim.api.nvim_set_hl(
    window_highlight_ns,
    "FloatBorder",
    current_border
  )
  vim.api.nvim_set_hl(0, "OculusBorder", current_border)
  vim.api.nvim_set_hl(window_highlight_ns, "OculusActivityIcon", {
    fg = "#fbd38d",
    bg = "NONE",
  })
  vim.api.nvim_set_hl(window_highlight_ns, "OculusActivityPreview", {
    fg = "#9ae6b4",
    bg = "NONE",
  })
  vim.api.nvim_set_hl(
    window_highlight_ns,
    "OculusContributorSelected",
    { fg = "#ffffff" }
  )
  vim.api.nvim_set_hl(window_highlight_ns, "OculusActivityQueued", {
    fg = "#fbd38d",
    bold = true,
  })
end

local function use_window_highlights(win)
  if is_valid_win(win) then
    vim.api.nvim_win_set_hl_ns(win, window_highlight_ns)
  end
end

function M.apply_window_highlights(win, source_win)
  if is_valid_win(source_win) then
    M.state.highlight_source_win = source_win
  end
  M.state.highlight_generation =
    (M.state.highlight_generation or 0) + 1
  sync_window_highlights(source_win or M.state.highlight_source_win)
  use_window_highlights(win)
end

function M.refresh_window_highlights(source_win)
  if is_valid_win(source_win) then
    M.state.highlight_source_win = source_win
  end
  source_win = source_win or M.state.highlight_source_win
  M.state.highlight_generation =
    (M.state.highlight_generation or 0) + 1
  local generation = M.state.highlight_generation
  sync_window_highlights(source_win)
  vim.schedule(function()
    if generation == M.state.highlight_generation then
      sync_window_highlights(source_win)
    end
  end)
end

local highlight_autocmd_group = vim.api.nvim_create_augroup(
  "OculusWindowHighlights",
  { clear = true }
)
vim.api.nvim_create_autocmd("ColorScheme", {
  group = highlight_autocmd_group,
  callback = function()
    M.refresh_window_highlights()
  end,
})

local activity_loading_frames = {
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

local function stop_activity_page_loading()
  local timer = M.state.activity_loading_timer
  M.state.activity_loading_timer = nil
  M.state.activity_loading_frame = 1
  if timer then
    pcall(timer.stop, timer)
    if not timer:is_closing() then
      timer:close()
    end
  end
  if is_valid_buf(M.state.buf) then
    vim.api.nvim_buf_clear_namespace(
      M.state.buf,
      activity_page_loading_ns,
      0,
      -1
    )
  end
end

local function draw_activity_page_loading()
  if M.state.view ~= "activity" or not is_valid_buf(M.state.buf) then
    return
  end
  local title_line = 3
  if vim.api.nvim_buf_line_count(M.state.buf) < title_line then
    return
  end
  vim.api.nvim_buf_clear_namespace(
    M.state.buf,
    activity_page_loading_ns,
    0,
    -1
  )
  vim.api.nvim_buf_set_extmark(
    M.state.buf,
    activity_page_loading_ns,
    title_line - 1,
    0,
    {
      virt_text = {
        {
          " " .. activity_loading_frames[M.state.activity_loading_frame],
          "DiagnosticInfo",
        },
      },
      virt_text_pos = "eol",
      hl_mode = "combine",
    }
  )
end

local function start_activity_page_loading()
  stop_activity_page_loading()
  draw_activity_page_loading()
  if is_valid_win(M.state.win) then
    vim.cmd("redraw")
  end
  local timer = vim.uv.new_timer()
  if not timer then
    return
  end
  M.state.activity_loading_timer = timer
  timer:start(80, 80, vim.schedule_wrap(function()
    if M.state.activity_loading_timer ~= timer then
      return
    end
    M.state.activity_loading_frame =
      (M.state.activity_loading_frame % #activity_loading_frames) + 1
    draw_activity_page_loading()
  end))
end

local function dimension(value, total, fallback, minimum)
  local result
  if type(value) == "number" and value > 0 and value <= 1 then
    result = math.floor(total * value)
  else
    result = tonumber(value) or math.floor(total * fallback)
  end
  return math.min(math.max(minimum, math.floor(result)), math.max(1, total - 4))
end

local function make_win_config(opts)
  local width = dimension(opts.width, vim.o.columns, 0.89, 54)
  local height = dimension(opts.height, vim.o.lines, 0.80, 16)
  local row = math.max(0, math.min(opts.row or 1, vim.o.lines - height - 2))

  return {
    relative = "editor",
    width = width,
    height = height,
    row = row,
    col = math.floor((vim.o.columns - width) / 2),
    style = "minimal",
    border = opts.border or "rounded",
  }
end

function M.window_config(opts)
  return make_win_config(opts or {})
end

local function make_buf()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = "oculus"
  return buf
end

local function close_activity_footer()
  if is_valid_win(M.state.footer_win) then
    vim.api.nvim_win_close(M.state.footer_win, true)
  end
  if is_valid_buf(M.state.footer_buf) then
    vim.api.nvim_buf_delete(M.state.footer_buf, { force = true })
  end
  M.state.footer_buf = nil
  M.state.footer_win = nil
end

local function make_footer_buf()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = "oculus"
  return buf
end

local function footer_win_config()
  if not is_valid_win(M.state.win) then
    return nil
  end
  local config = vim.api.nvim_win_get_config(M.state.win)
  local row = tonumber(config.row) or 0
  local col = tonumber(config.col) or 0
  local width = vim.api.nvim_win_get_width(M.state.win)
  local height = vim.api.nvim_win_get_height(M.state.win)
  return {
    relative = "editor",
    width = width,
    height = 2,
    row = row + height - 1,
    col = col + 1,
    style = "minimal",
    focusable = false,
    zindex = 60,
  }
end

local function render_activity_footer()
  local config = footer_win_config()
  if not config then
    return
  end

  local buf = M.state.footer_buf
  if not is_valid_buf(buf) then
    buf = make_footer_buf()
    M.state.footer_buf = buf
  end

  local width = config.width
  local activity_commands = "  h inspect   b browser   / search"
  if not M.state.activity_commit_page then
    if M.state.activity_issue_page then
      activity_commands = activity_commands
        .. "   f filters"
    else
      if M.state.activity_project then
        activity_commands = activity_commands .. "   u issues"
      end
    end
  end
  local lines = {
    "  " .. string.rep("─", math.max(1, width - 4)),
    activity_commands,
  }
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  vim.api.nvim_buf_add_highlight(buf, ns, "WinSeparator", 0, 2, -1)
  vim.api.nvim_buf_add_highlight(buf, ns, "Comment", 1, 2, -1)

  if is_valid_win(M.state.footer_win) then
    vim.api.nvim_win_set_config(M.state.footer_win, config)
  else
    M.state.footer_win = vim.api.nvim_open_win(buf, false, config)
  end
  vim.wo[M.state.footer_win].wrap = false
  vim.wo[M.state.footer_win].cursorline = false
  vim.wo[M.state.footer_win].winhighlight = table.concat({
    "Normal:OculusNormal",
    "NormalFloat:OculusNormal",
  }, ",")
  use_window_highlights(M.state.footer_win)
  vim.wo[M.state.footer_win].number = false
  vim.wo[M.state.footer_win].relativenumber = false
  vim.wo[M.state.footer_win].signcolumn = "no"
end

local function list_buffer_line_count()
  if not is_valid_win(M.state.win) or not is_valid_buf(M.state.buf) then
    return nil
  end
  if vim.api.nvim_win_get_buf(M.state.win) ~= M.state.buf then
    return nil
  end
  return vim.api.nvim_buf_line_count(M.state.buf)
end

local function update_activity_cursorline()
  if M.state.view ~= "activity" or not is_valid_win(M.state.win) then
    return
  end
  if vim.api.nvim_get_current_win() ~= M.state.win then
    return
  end
  local line_count = list_buffer_line_count()
  if not line_count then
    return
  end
  local footer_height = is_valid_win(M.state.footer_win) and 2 or 0
  local visible_rows = math.max(
    1,
    vim.api.nvim_win_get_height(M.state.win) - footer_height
  )
  local cursor = vim.api.nvim_win_get_cursor(M.state.win)
  local min_line = math.max(
    1,
    math.min(M.state.activity_cursor_min_line or 1, line_count)
  )
  if cursor[1] < min_line then
    cursor = { min_line, 0 }
    vim.api.nvim_win_set_cursor(M.state.win, cursor)
  end
  local limit_line = M.state.activity_scroll_limit_line
  if limit_line then
    limit_line = math.max(min_line, math.min(limit_line, line_count))
    if cursor[1] > limit_line then
      cursor = { limit_line, 0 }
      vim.api.nvim_win_set_cursor(M.state.win, cursor)
    end
    local max_topline = math.max(1, limit_line - visible_rows + 1)
    local view = vim.fn.winsaveview()
    if view.topline > max_topline then
      view.topline = max_topline
      vim.fn.winrestview(view)
    end
  end
  local cursor_row = vim.fn.winline()
  if cursor_row > visible_rows then
    local view = vim.fn.winsaveview()
    view.topline = view.topline + cursor_row - visible_rows
    vim.fn.winrestview(view)
    cursor_row = vim.fn.winline()
  end
  vim.wo[M.state.win].cursorline = cursor_row <= visible_rows
end

local function clamp_list_cursor()
  local line_count = list_buffer_line_count()
  if not line_count then
    return
  end

  if M.state.view == "contributors" then
    local selectable = {}
    local selected_line
    for line, target in pairs(M.state.line_targets) do
      if
        type(target) == "table"
        and type(line) == "number"
        and line >= 1
        and line <= line_count
      then
        selectable[#selectable + 1] = line
        if target.kind == "project" then
          if target.project.repository
            == (M.state.selected_project or {}).repository
          then
            selected_line = line
          end
        elseif target.username == M.state.selected_username then
          selected_line = line
        end
      end
    end
    table.sort(selectable)
    if #selectable == 0 then
      return
    end

    local cursor = vim.api.nvim_win_get_cursor(M.state.win)
    if type(M.state.line_targets[cursor[1]]) == "table" then
      return
    end

    local line
    if selected_line and cursor[1] > selected_line then
      line = selectable[#selectable]
      for _, candidate in ipairs(selectable) do
        if candidate >= cursor[1] then
          line = candidate
          break
        end
      end
    elseif selected_line and cursor[1] < selected_line then
      line = selectable[1]
      for index = #selectable, 1, -1 do
        if selectable[index] <= cursor[1] then
          line = selectable[index]
          break
        end
      end
    else
      line = selectable[1]
      for _, candidate in ipairs(selectable) do
        if math.abs(candidate - cursor[1]) < math.abs(line - cursor[1]) then
          line = candidate
        end
      end
    end
    vim.api.nvim_win_set_cursor(M.state.win, { line, 0 })
    return
  end

  local min_line
  local max_line
  if M.state.view == "activity" then
    min_line = M.state.activity_cursor_min_line
    max_line = M.state.activity_scroll_limit_line
  elseif M.state.view == "filters"
    or M.state.view == "issue_filters"
  then
    for line, target in pairs(M.state.line_targets) do
      if
        type(target) == "table"
        and type(line) == "number"
        and line >= 1
        and line <= line_count
      then
        min_line = math.min(min_line or line, line)
        max_line = math.max(max_line or line, line)
      end
    end
  end

  if not min_line or not max_line then
    return
  end
  min_line = math.max(1, math.min(min_line, line_count))
  max_line = math.max(min_line, math.min(max_line, line_count))
  local cursor = vim.api.nvim_win_get_cursor(M.state.win)
  local line = math.min(math.max(cursor[1], min_line), max_line)
  if line ~= cursor[1] then
    vim.api.nvim_win_set_cursor(M.state.win, { line, 0 })
  end
end

local function set_lines(lines)
  if not is_valid_buf(M.state.buf) then
    return
  end
  vim.bo[M.state.buf].modifiable = true
  vim.api.nvim_buf_set_lines(M.state.buf, 0, -1, false, lines)
  vim.bo[M.state.buf].modifiable = false
  vim.api.nvim_buf_clear_namespace(M.state.buf, ns, 0, -1)
  vim.api.nvim_buf_clear_namespace(M.state.buf, preview_ns, 0, -1)
  vim.api.nvim_buf_clear_namespace(
    M.state.buf,
    contributor_selection_ns,
    0,
    -1
  )
  vim.api.nvim_buf_clear_namespace(
    M.state.buf,
    activity_inspect_queue_ns,
    0,
    -1
  )
  M.state.preview_items = nil
end

local function highlight(line, start_col, end_col, group)
  vim.api.nvim_buf_add_highlight(
    M.state.buf,
    ns,
    group,
    line - 1,
    start_col,
    end_col
  )
end

local function trim_to_width(text, width)
  if vim.fn.strdisplaywidth(text) <= width then
    return text
  end
  if text:sub(-1) == '"' and width >= 2 then
    return vim.fn.strcharpart(text, 0, math.max(0, width - 2)) .. '…"'
  end
  return vim.fn.strcharpart(text, 0, math.max(1, width - 1)) .. "…"
end

local function pad_cell(text, width)
  local value = trim_to_width(text, width)
  local padding = math.max(0, width - vim.fn.strdisplaywidth(value))
  return value .. string.rep(" ", padding)
end

local function left_pad_cell(text, width)
  local value = trim_to_width(text, width)
  local padding = math.max(0, width - vim.fn.strdisplaywidth(value))
  return string.rep(" ", padding) .. value
end

local function display_contributors(contributors)
  local result = {}
  for _, contributor in ipairs(contributors or {}) do
    local copy = vim.deepcopy(contributor)
    copy.description = nil
    result[#result + 1] = copy
  end
  return result
end

local function display_projects(projects)
  local result = {}
  for _, project in ipairs(projects or {}) do
    if type(project) == "table"
      and type(project.repository) == "string"
      and project.repository ~= ""
    then
      result[#result + 1] = vim.deepcopy(project)
    end
  end
  return result
end

local function project_key(project)
  if type(project) ~= "table" or not project.repository then
    return nil
  end
  return (project.provider == "codeberg" and "codeberg" or "github")
    .. ":"
    .. project.repository:lower()
end

local function project_title(project)
  return project.repository
end

local function has_project(projects, candidate)
  local key = project_key(candidate)
  if not key then
    return false
  end
  for _, project in ipairs(projects or {}) do
    if project_key(project) == key then
      return true
    end
  end
  return false
end

local function contributor_key(contributor)
  if type(contributor) ~= "table" or not contributor.username then
    return nil
  end
  return ("%s:%s"):format(
    contributor.provider == "codeberg" and "codeberg" or "github",
    contributor.username:lower()
  )
end

local function has_contributor(contributors, candidate)
  local key = contributor_key(candidate)
  if not key then
    return false
  end
  for _, contributor in ipairs(contributors or {}) do
    if contributor_key(contributor) == key then
      return true
    end
  end
  return false
end

local function fuzzy_score(value, query)
  value = vim.fn.tolower(value)
  query = vim.fn.tolower(query)
  if query == "" then
    return 0
  end

  local function characters(text)
    local result = {}
    for index = 0, vim.fn.strchars(text) - 1 do
      result[#result + 1] = vim.fn.strcharpart(text, index, 1)
    end
    return result
  end

  local value_characters = characters(value)
  local query_characters = characters(query)
  local score = -#value_characters
  local previous = 0
  local consecutive = 0
  for _, character in ipairs(query_characters) do
    local position
    for index = previous + 1, #value_characters do
      if value_characters[index] == character then
        position = index
        break
      end
    end
    if not position then
      return nil
    end

    local gap = position - previous - 1
    score = score - gap * 2
    if position == previous + 1 then
      consecutive = consecutive + 1
      score = score + 10 + consecutive * 2
    else
      consecutive = 0
    end
    if
      position == 1
      or value_characters[position - 1]:match("[%s%-%._@]")
    then
      score = score + 18
    end
    previous = position
  end

  local substring = value:find(query, 1, true)
  if substring then
    score = score + 120 - substring
  end
  if value == query then
    score = score + 200
  elseif value:sub(1, #query) == query then
    score = score + 60
  end
  return score
end

local function fuzzy_contributors(contributors, query)
  query = tostring(query or "")
    :gsub("^%s+", "")
    :gsub("%s+$", "")
    :gsub("^@", "")
  if query == "" then
    return display_contributors(contributors)
  end

  local matches = {}
  for index, contributor in ipairs(contributors or {}) do
    local name_score = fuzzy_score(
      contributor.name or contributor.username or "",
      query
    )
    local username_score = fuzzy_score(contributor.username or "", query)
    local score = math.max(name_score or -math.huge, username_score or -math.huge)
    if score > -math.huge then
      matches[#matches + 1] = {
        contributor = contributor,
        score = score,
        index = index,
      }
    end
  end

  table.sort(matches, function(left, right)
    if left.score == right.score then
      return left.index < right.index
    end
    return left.score > right.score
  end)

  local result = {}
  for _, match in ipairs(matches) do
    result[#result + 1] = match.contributor
  end
  return result
end

M._fuzzy_contributors = fuzzy_contributors

local function fuzzy_projects(projects, query)
  query = tostring(query or "")
    :gsub("^%s+", "")
    :gsub("%s+$", "")
  if query == "" then
    return display_projects(projects)
  end

  local matches = {}
  for index, project in ipairs(display_projects(projects)) do
    local name_score = fuzzy_score(project.name or "", query)
    local repository_score = fuzzy_score(project.repository, query)
    local score = math.max(
      name_score or -math.huge,
      repository_score or -math.huge
    )
    if score > -math.huge then
      matches[#matches + 1] = {
        project = project,
        score = score,
        index = index,
      }
    end
  end
  table.sort(matches, function(left, right)
    if left.score == right.score then
      return left.index < right.index
    end
    return left.score > right.score
  end)
  local result = {}
  for _, match in ipairs(matches) do
    result[#result + 1] = match.project
  end
  return result
end

M._fuzzy_projects = fuzzy_projects

local function visible_contributors()
  if M.state.search_query ~= nil then
    return M.state.search_results or {}
  end
  return M.state.contributors
end

local function visible_projects()
  if M.state.search_query ~= nil
    and M.state.search_kind == "projects"
  then
    return M.state.search_results or {}
  end
  return display_projects(M.state.opts.projects)
end

local function utc_time(year, month, day, hour, minute, second)
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

-- AGENT_CHANGE_BEGIN codeberg-andrew-kelley-20260727 8 Parse activity timestamps with UTC offsets
local function activity_time(timestamp)
  if not timestamp then
    return "unknown time"
  end
  local year, month, day, hour, minute, second, offset_sign, offset_hour, offset_minute =
    timestamp:match(
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

  local local_time = utc_time(
    tonumber(year),
    tonumber(month),
    tonumber(day),
    tonumber(hour),
    tonumber(minute),
    tonumber(second)
  )
  if offset_sign then
    local offset = tonumber(offset_hour) * 3600 + tonumber(offset_minute) * 60
    local_time = local_time + (offset_sign == "+" and -offset or offset)
  end

  local event_date = os.date("*t", local_time)
  local time = os.date("%I:%M %p", local_time):gsub("^0", " ")

  local date = ("%02d/%02d/%02d"):format(
    event_date.month,
    event_date.day,
    event_date.year % 100
  )
  return date .. " — " .. time
end
-- AGENT_CHANGE_END codeberg-andrew-kelley-20260727 8

local function footer(lines, text)
  lines[#lines + 1] = "  " .. text
end

local function preview_left_width(window_width)
  local preferred = math.max(40, math.floor(window_width * 0.52))
  return math.max(30, math.min(preferred, window_width - 22))
end

local function is_formatted_preview(text)
  return text:match('^".*"$')
    or text:match('^PR #%d+ · ".*"$')
    or text:match("^• ")
end

local function event_detail(item)
  if item.detail then
    if type(item.detail) == "table" then
      return item.detail
    end
    local detail = item.detail
    if not is_formatted_preview(detail) then
      detail = '"' .. detail .. '"'
    end
    return detail
  end
end

local function quoted_detail_line(text)
  if text == "..." then
    return text
  end
  if is_formatted_preview(text) then
    return text
  end
  return '"' .. text .. '"'
end

local function event_summary(item)
  if item.summary then
    local summary = item.summary
    if not is_formatted_preview(summary) then
      summary = '"' .. summary .. '"'
    end
    return summary
  end
end

local function event_text(item, width)
  local detail = event_summary(item) or event_detail(item)
  if type(detail) == "table" then
    detail = nil
  end
  if detail then
    local separator = " · "
    if width then
      local separator_width = vim.fn.strdisplaywidth(separator)
      local text_width = vim.fn.strdisplaywidth(item.text)
      local detail_width = width - text_width - separator_width
      if detail_width < 1 then
        return item.text
      end
      return item.text .. separator .. trim_to_width(detail, detail_width)
    end
    return item.text .. separator .. detail
  end
  return item.text
end

local function activity_item_line(item, timestamp, width)
  local timestamp_width = 19
  local gap = "  "
  local content_width = math.max(
    1,
    width - timestamp_width - vim.fn.strdisplaywidth(gap)
  )
  local prefix = ("  %s  "):format(item.icon)
  local text_width = math.max(1, content_width - vim.fn.strdisplaywidth(prefix))
  local content = prefix .. event_text(item, text_width)
  return pad_cell(content, content_width)
    .. gap
    .. left_pad_cell(timestamp, timestamp_width)
end

local function activity_loading_line(line, frame)
  local timestamp_width = 19
  local gap_width = 2
  local tail_width = timestamp_width + gap_width
  if vim.fn.strdisplaywidth(line) <= tail_width then
    return line .. " " .. frame, #line + 1
  end
  local tail_start = vim.fn.strchars(line)
  local tail = ""
  while tail_start > 0
    and vim.fn.strdisplaywidth(tail) < tail_width
  do
    tail_start = tail_start - 1
    tail = vim.fn.strcharpart(line, tail_start)
  end
  local content = vim.fn.strcharpart(line, 0, tail_start)
  local content_width =
    vim.fn.strdisplaywidth(line) - vim.fn.strdisplaywidth(tail)
  local body = content:gsub("%s+$", "")
  local body_width = math.max(1, content_width - 2)
  body = trim_to_width(body, body_width)
  while vim.fn.strdisplaywidth(body) > body_width do
    body = vim.fn.strcharpart(
      body,
      0,
      math.max(0, vim.fn.strchars(body) - 1)
    )
  end
  local spinner_column = #body + 1
  return pad_cell(body .. " " .. frame, content_width) .. tail,
    spinner_column
end

local function preview_lines(item, width)
  local summary = event_summary(item)
  local detail = event_detail(item)
  if not summary and not detail then
    return nil
  end
  local indent = "     "
  local content_width = math.max(1, width - vim.fn.strdisplaywidth(indent) - 1)
  local lines = {}
  local details = {}
  if summary then
    details[#details + 1] = { text = summary }
  end
  if type(detail) == "table" then
    for index, detail_item in ipairs(detail) do
      details[#details + 1] = {
        text = detail_item,
        detail_index = vim.trim(tostring(detail_item)) ~= "..."
            and index
          or nil,
      }
    end
  elseif detail and detail ~= summary then
    details[#details + 1] = { text = detail }
  end
  local detail_indices = {}
  for _, detail_item in ipairs(details) do
    local remaining = quoted_detail_line(detail_item.text)
    for _ = 1, 3 do
      if remaining == "" then
        break
      end
      local text = trim_to_width(remaining, content_width)
      lines[#lines + 1] = indent .. pad_cell(text, content_width) .. " "
      detail_indices[#lines] = detail_item.detail_index
      if vim.fn.strdisplaywidth(remaining) <= content_width then
        break
      end
      local suffix_width = text:sub(-4) == '…"' and 2 or 1
      local consumed = math.max(1, vim.fn.strchars(text) - suffix_width)
      remaining = vim.fn.strcharpart(remaining, consumed)
    end
  end
  return lines, detail_indices
end

local function without_preview(item)
  local result = vim.tbl_extend("force", {}, item)
  result.detail = nil
  result.summary = nil
  return result
end

local function project_push_author(event)
  local actor = type(event.actor) == "table" and event.actor or {}
  local handle = actor.login or actor.username or actor.handle
  if type(handle) == "string" and handle ~= "" then
    return "@" .. handle
  end
  if type(actor.name) == "string" and actor.name ~= "" then
    return actor.name
  end

  local commits = event.payload and event.payload.commits or {}
  local commit = commits[#commits]
  local author = type(commit) == "table" and commit.author or nil
  if type(author) == "table" then
    local author_handle = author.login or author.username
    if type(author_handle) == "string" and author_handle ~= "" then
      return "@" .. author_handle
    end
    author = author.name
  end
  return type(author) == "string" and author ~= "" and author or nil
end

local function activity_identity(value)
  if type(value) == "string" then
    return value ~= "" and value or nil
  end
  if type(value) ~= "table" then
    return nil
  end
  local handle = value.login or value.username or value.handle
  if type(handle) == "string" and handle ~= "" then
    return "@" .. handle:gsub("^@", "")
  end
  return type(value.name) == "string" and value.name ~= ""
      and value.name
    or nil
end

local function project_pull_request_title(event, text)
  local payload = event.payload or {}
  local pull_request = payload.pull_request or {}
  local merged = payload.action == "merged"
    or (payload.action == "closed" and (
      pull_request.merged == true
      or pull_request.merged_at ~= nil
      or pull_request.merged_by ~= nil
    ))
  if not merged then
    return text
  end
  local author = activity_identity(
    pull_request.user or pull_request.author
  )
  local merger = activity_identity(pull_request.merged_by)
    or activity_identity(event.actor)
  local number = pull_request.number or payload.number
  local repository = event.repo
    and (event.repo.name or event.repo.full_name)
  if merger and number and repository then
    if author and merger:lower() == author:lower() then
      return ("%s merged pr #%s in %s"):format(
        merger,
        number,
        repository
      )
    end
    if author then
      return ("%s merged pr #%s from %s in %s"):format(
        merger,
        number,
        author,
        repository
      )
    end
    return ("%s merged pr #%s in %s"):format(
      merger,
      number,
      repository
    )
  end
  return text
end

M._project_pull_request_title = project_pull_request_title

local function render_preview_panel(items)
  if
    M.state.view ~= "contributors"
    or not is_valid_buf(M.state.buf)
    or not is_valid_win(M.state.win)
  then
    return
  end

  vim.api.nvim_buf_clear_namespace(M.state.buf, preview_ns, 0, -1)
  M.state.preview_items = items
  local window_width = vim.api.nvim_win_get_width(M.state.win)
  local left_width = preview_left_width(window_width)
  local right_width = math.max(16, window_width - left_width - 3)
  local line_count = vim.api.nvim_buf_line_count(M.state.buf)

  for line = 1, line_count do
    local item = items[line]
    local text = item and trim_to_width(item[1], right_width - 1) or ""
    local group = item and item[2] or "NormalFloat"
    vim.api.nvim_buf_set_extmark(M.state.buf, preview_ns, line - 1, 0, {
      virt_text = {
        { "│", "WinSeparator" },
        { " " .. text, group },
      },
      virt_text_win_col = left_width,
      hl_mode = "combine",
    })
  end
end

-- AGENT_CHANGE_BEGIN codeberg-andrew-kelley-20260727 9 Show each contributor's forge in previews
local function preview_items(contributor)
  return {
    [2] = { "USER", "Title" },
    [4] = { "@" .. contributor.username, "Identifier" },
    [5] = { provider_name(contributor), "Comment" },
  }
end

local function wrapped_preview_text(text, width, limit)
  if type(text) ~= "string" or vim.trim(text) == "" then
    return {}
  end
  width = math.max(8, width or 32)
  limit = math.max(1, limit or 3)
  local words = vim.split(vim.trim(text):gsub("%s+", " "), " ")
  local lines = {}
  local index = 1
  while index <= #words and #lines < limit do
    local line = words[index]
    index = index + 1
    while index <= #words
      and vim.fn.strdisplaywidth(line .. " " .. words[index]) <= width
    do
      line = line .. " " .. words[index]
      index = index + 1
    end
    if #lines == limit - 1 and index <= #words then
      line = line .. " " .. table.concat(words, " ", index)
      index = #words + 1
    end
    lines[#lines + 1] = trim_to_width(line, width)
  end
  return lines
end

local function project_preview_items(project, width)
  local provider = project.provider == "codeberg" and "Codeberg" or "GitHub"
  local items = {
    [2] = { "PROJECT", "Title" },
    [4] = { project_title(project), "Identifier" },
    [5] = { provider, "Comment" },
  }
  for index, line in ipairs(wrapped_preview_text(
    project.description,
    width,
    3
  )) do
    items[6 + index] = { line, "Comment" }
  end
  return items
end
-- AGENT_CHANGE_END codeberg-andrew-kelley-20260727 9

local function activity_types_for(contributor)
  local overrides = M.state.opts.user_activity_types or {}
  local username = contributor.username
  local user_types = overrides[username] or overrides[username:lower()]
  if user_types ~= nil then
    return user_types
  end
  if contributor.activity_types ~= nil then
    return contributor.activity_types
  end
  return M.state.opts.activity_types
end

local function queue_preview(contributor)
  if
    not contributor
    or M.state.view ~= "contributors"
  then
    return
  end

  local key = contributor_key(contributor)
  if M.state.preview_key == key then
    return
  end
  M.state.preview_key = key
  M.state.preview_contributor = contributor
  render_preview_panel(preview_items(contributor))
end

local function queue_project_preview(project)
  if not project or M.state.view ~= "contributors" then
    return
  end
  local key = project_key(project)
  if M.state.preview_key == key then
    return
  end
  M.state.preview_key = key
  M.state.preview_project = project
  local window_width = vim.api.nvim_win_get_width(M.state.win)
  local left_width = preview_left_width(window_width)
  local preview_width = math.max(15, window_width - left_width - 5)
  render_preview_panel(project_preview_items(project, preview_width))
end

local function update_contributor_selection()
  if not is_valid_buf(M.state.buf) then
    return
  end
  vim.api.nvim_buf_clear_namespace(
    M.state.buf,
    contributor_selection_ns,
    0,
    -1
  )
  if
    M.state.view ~= "contributors"
    or not is_valid_win(M.state.win)
  then
    return
  end

  local line = vim.api.nvim_win_get_cursor(M.state.win)[1]
  if type(M.state.line_targets[line]) ~= "table" then
    return
  end
  local text = vim.api.nvim_buf_get_lines(
    M.state.buf,
    line - 1,
    line,
    false
  )[1] or ""
  local visible_text = text:gsub("%s+$", "")
  if #visible_text > 2 then
    vim.api.nvim_buf_set_extmark(
      M.state.buf,
      contributor_selection_ns,
      line - 1,
      2,
      {
        end_row = line - 1,
        end_col = #visible_text,
        hl_group = "OculusContributorSelected",
        hl_mode = "combine",
        priority = 10000,
      }
    )
  end
end

local function render_contributors()
  stop_activity_page_loading()
  close_activity_footer()
  M.state.view = "contributors"
  M.state.contributor = nil
  M.state.activity_scope = nil
  M.state.activity_project = nil
  M.state.events = nil
  M.state.line_targets = {}
  M.state.preview_key = nil
  M.state.preview_project = nil

  -- AGENT_CHANGE_BEGIN codeberg-andrew-kelley-20260727 10 Generalize the contributor list for multiple forges
  local searching = type(M.state.search_query) == "string"
  local community_view = searching
      and (M.state.search_kind or M.state.community_view)
    or (M.state.community_view or "projects")
  local showing_users = community_view == "users"
  local lines = searching
      and {
        "",
        "",
        "",
        "",
      }
    or {
      "",
      "  ACTIVITY",
      "",
      "",
    }

  local contributors = showing_users and visible_contributors() or {}
  local projects = not showing_users
      and visible_projects()
    or {}
  local left_width = preview_left_width(vim.api.nvim_win_get_width(M.state.win))
  local username_width = 5
  for _, contributor in ipairs(contributors) do
    username_width = math.max(username_width, #(contributor.username) + 1)
  end
  username_width = math.min(username_width, math.max(5, left_width - 2))

  local project_lines = {}
  local project_heading_line
  if not showing_users then
    project_heading_line = #lines + 1
    lines[#lines + 1] = "  PROJECTS"
    for _, project in ipairs(projects) do
      local line = #lines + 1
      lines[line] = pad_cell(
        "  " .. project_title(project),
        left_width
      )
      M.state.line_targets[line] = {
        kind = "project",
        project = project,
      }
      project_lines[#project_lines + 1] = line
    end
    if #projects == 0 then
      lines[#lines + 1] = "  No projects configured."
    end
  end

  local user_heading_line
  if showing_users then
    user_heading_line = #lines + 1
    lines[#lines + 1] = "  " .. pad_cell("USERS", username_width)
  end

  local selected_index = 1
  for index, contributor in ipairs(contributors) do
    if contributor.username == M.state.selected_username then
      selected_index = index
      break
    end
  end
  local list_limit = math.max(
    1,
    math.floor(tonumber(M.state.opts.contributor_list_limit) or 20)
  )
  local window_height = vim.api.nvim_win_get_height(M.state.win)
  list_limit = math.min(
    list_limit,
    math.max(1, window_height - 7 - #project_lines - 4)
  )
  local max_offset = math.max(1, #contributors - list_limit + 1)
  local offset = math.min(
    math.max(1, M.state.contributor_offset or 1),
    max_offset
  )
  if selected_index < offset then
    offset = selected_index
  elseif selected_index >= offset + list_limit then
    offset = selected_index - list_limit + 1
  end
  M.state.contributor_offset = offset

  if showing_users then
    for index = offset, math.min(#contributors, offset + list_limit - 1) do
      local contributor = contributors[index]
      local line = #lines + 1
      local handle = "@" .. contributor.username
      local prefix = "  " .. pad_cell(handle, username_width)
      lines[line] = pad_cell(prefix, left_width)
      M.state.line_targets[line] = contributor
    end
  end
  -- AGENT_CHANGE_END codeberg-andrew-kelley-20260727 10

  if showing_users and #contributors == 0 then
    if searching then
      lines[#lines + 1] = "  No matching users."
    else
      lines[#lines + 1] = "  No users added."
      lines[#lines + 1] = "  a add account"
    end
  end
  while #lines < window_height - 2 do
    lines[#lines + 1] = ""
  end
  lines[#lines + 1] = "  " .. string.rep("─", math.max(1, left_width - 2))
  local separator_line = #lines
  footer(lines, searching
      and "esc cancel"
    or showing_users
        and "t projects  a add  r remove  / search  ?: help"
      or "t users  a add  r remove  / search  ?: help")
  local commands_line = #lines
  set_lines(lines)
  vim.wo[M.state.win].cursorline = false

  highlight(2, 2, -1, "Title")
  highlight(3, 2, -1, "Comment")
  if project_heading_line then
    highlight(project_heading_line, 2, -1, "Title")
  end
  if user_heading_line then
    highlight(user_heading_line, 2, -1, "Title")
  end
  for line, _ in pairs(M.state.line_targets) do
    local target = M.state.line_targets[line]
    highlight(
      line,
      2,
      target.kind == "project" and -1 or 2 + username_width,
      "Identifier"
    )
  end
  highlight(separator_line, 2, -1, "WinSeparator")
  highlight(commands_line, 2, -1, "Comment")

  local selected_line
  for line, target in pairs(M.state.line_targets) do
    if target.kind == "project"
      and target.project.repository
        == (M.state.selected_project or {}).repository
    then
      selected_line = line
      break
    elseif target.kind ~= "project"
      and target.username == M.state.selected_username
    then
      selected_line = line
      break
    end
  end
  if not selected_line then
    for line, target in pairs(M.state.line_targets) do
      if type(target) == "table"
        and (not selected_line or line < selected_line)
      then
        selected_line = line
      end
    end
  end
  if selected_line and is_valid_win(M.state.win) then
    local target = M.state.line_targets[selected_line]
    if target.kind == "project" then
      M.state.selected_project = target.project
      M.state.selected_username = nil
    else
      M.state.selected_project = nil
      M.state.selected_username = target.username
    end
    vim.api.nvim_win_set_cursor(M.state.win, { selected_line, 0 })
    if target.kind == "project" then
      queue_project_preview(target.project)
    else
      queue_preview(target)
    end
    update_contributor_selection()
  else
    local preview_contributor = M.state.preview_contributor
    local preview_project = M.state.preview_project
    local previous_username = M.state.search_return
        and M.state.search_return.selected_username
      or nil
    local previous_project = M.state.search_return
        and M.state.search_return.selected_project
      or nil
    if not preview_contributor and previous_username then
      for _, contributor in ipairs(M.state.contributors) do
        if contributor.username == previous_username then
          preview_contributor = contributor
          break
        end
      end
    end
    if preview_project then
      queue_project_preview(preview_project)
    elseif previous_project then
      queue_project_preview(previous_project)
    elseif preview_contributor then
      queue_preview(preview_contributor)
    else
      render_preview_panel({
        [2] = {
          showing_users and "USER" or "PROJECT",
          "Title",
        },
      })
    end
  end
end

local function filter_type_set(scope)
  local types
  local categories
  if scope.project then
    types = project_activity_types_for(scope.project)
    categories = project_activity_categories
  elseif scope.global then
    types = M.state.opts.activity_types
    categories = actions.event_types
  else
    types = activity_types_for(scope)
    categories = actions.event_types
  end

  local enabled = {}
  if types == nil then
    for _, category in ipairs(categories) do
      enabled[category.key or category] = true
    end
  else
    for _, category in ipairs(types) do
      enabled[category] = true
    end
  end
  return enabled
end

local function persist_filter_config()
  if M.state.opts.persist_filters then
    local ok, err = require("oculus.storage").save(
      M.state.opts.state_file,
      M.state.opts
    )
    if not ok then
      vim.notify(
        "Oculus could not save activity filters: " .. tostring(err),
        vim.log.levels.ERROR
      )
    end
  end
end

local function persist_contributors()
  M.state.opts.contributors = vim.deepcopy(M.state.contributors)
  if not M.state.opts.persist_contributors then
    return
  end
  local ok, err = require("oculus.storage").save(
    M.state.opts.state_file,
    M.state.opts
  )
  if not ok then
    vim.notify(
      "Oculus could not save users: " .. tostring(err),
      vim.log.levels.ERROR
    )
  end
end

local function persist_projects()
  if not M.state.opts.persist_projects then
    return
  end
  local ok, err = require("oculus.storage").save(
    M.state.opts.state_file,
    M.state.opts
  )
  if not ok then
    vim.notify(
      "Oculus could not save projects: " .. tostring(err),
      vim.log.levels.ERROR
    )
  end
end

local function save_filter_type_set(scope, enabled)
  local types = {}
  local categories = scope.project
      and project_activity_categories
    or actions.event_types
  for _, category in ipairs(categories) do
    local key = category.key or category
    if enabled[key] then
      types[#types + 1] = key
    end
  end

  if scope.project then
    if scope.project.activity_types ~= nil then
      for _, project in ipairs(M.state.opts.projects or {}) do
        if project.repository == scope.project.repository then
          project.activity_types = types
          break
        end
      end
    else
      M.state.opts.project_activity_types = types
    end
  elseif scope.global then
    M.state.opts.activity_types = types
  else
    M.state.opts.user_activity_types = M.state.opts.user_activity_types or {}
    M.state.opts.user_activity_types[scope.username] = types
  end

  persist_filter_config()
end

local function render_filters(scope, selected_type)
  stop_activity_page_loading()
  close_activity_footer()
  M.state.view = "filters"
  M.state.filter_scope = scope
  M.state.line_targets = {}

  local scope_name = scope.project
      and project_title(scope.project)
    or scope.global
      and "All contributors"
    or ("@" .. scope.username)
  local categories = scope.project
      and project_activity_categories
    or actions.event_types
  local enabled = filter_type_set(scope)
  local lines = {
    "",
    "  ACTIVITY TYPES",
    "  " .. scope_name,
    "  Checked event kinds are shown in previews and activity feeds.",
    "",
  }

  local selected_line
  for _, category in ipairs(categories) do
    local event_type = category.key or category
    local label = category.label or actions.type_label(event_type)
    local line = #lines + 1
    local checkbox = enabled[event_type] and "[x]" or "[ ]"
    lines[line] = ("  %s  %-28s %s"):format(
      checkbox,
      label,
      event_type
    )
    M.state.line_targets[line] = { event_type = event_type }
    if event_type == selected_type then
      selected_line = line
    end
  end
  local width = vim.api.nvim_win_get_width(M.state.win)
  lines[#lines + 1] = "  " .. string.rep("─", math.max(1, width - 4))
  footer(lines, "? shortcuts   j/← back   q close")
  set_lines(lines)
  vim.wo[M.state.win].cursorline = true

  highlight(2, 2, -1, "Title")
  highlight(3, 2, -1, "Identifier")
  highlight(4, 2, -1, "Comment")
  for line, target in pairs(M.state.line_targets) do
    highlight(
      line,
      2,
      5,
      enabled[target.event_type] and "DiagnosticOk" or "Comment"
    )
    highlight(line, 7, 35, "Function")
    highlight(line, 36, -1, "Comment")
  end
  highlight(#lines - 1, 2, -1, "WinSeparator")
  highlight(#lines, 2, -1, "Comment")

  vim.api.nvim_win_set_cursor(M.state.win, { selected_line or 6, 0 })
end

local function toggle_filter_type()
  if M.state.view ~= "filters" then
    return
  end
  local line = vim.api.nvim_win_get_cursor(M.state.win)[1]
  local target = M.state.line_targets[line]
  if not target or not target.event_type then
    return
  end
  local enabled = filter_type_set(M.state.filter_scope)
  enabled[target.event_type] = not enabled[target.event_type]
  save_filter_type_set(M.state.filter_scope, enabled)
  render_filters(M.state.filter_scope, target.event_type)
end

local function set_all_filter_types(value)
  if M.state.view ~= "filters" then
    return
  end
  local line = vim.api.nvim_win_get_cursor(M.state.win)[1]
  local target = M.state.line_targets[line]
  local enabled = {}
  local categories = M.state.filter_scope.project
      and project_activity_categories
    or actions.event_types
  for _, category in ipairs(categories) do
    enabled[category.key or category] = value
  end
  save_filter_type_set(M.state.filter_scope, enabled)
  render_filters(M.state.filter_scope, target and target.event_type or nil)
end

local function reset_filter_types_to_default()
  if M.state.view == "filters"
    and M.state.filter_scope
    and M.state.filter_scope.project
  then
    M.state.opts.project_activity_types = nil
    persist_filter_config()
    render_filters(M.state.filter_scope)
    return
  end
  if M.state.view ~= "contributors" then
    return
  end
  M.state.opts.activity_types = nil
  M.state.opts.user_activity_types = {}
  persist_filter_config()
  render_contributors()
end

local issue_filter_options = {
  {
    heading = "STATUS",
    dimension = "state",
    choices = {
      { value = "all", label = "All issues" },
      { value = "open", label = "Open issues" },
      { value = "closed", label = "Closed issues" },
    },
  },
  {
    heading = "ASSIGNMENT",
    dimension = "assignment",
    choices = {
      { value = "all", label = "Any assignment" },
      { value = "assigned", label = "Assigned issues" },
      { value = "unassigned", label = "Unassigned issues" },
    },
  },
}

local function project_issue_filter_key(project)
  return table.concat({
    project.provider == "codeberg" and "codeberg" or "github",
    project.repository:lower(),
  }, ":")
end

local function project_issue_filters_for(project)
  M.state.opts.project_issue_filters =
    M.state.opts.project_issue_filters or {}
  local key = project_issue_filter_key(project)
  local filters = M.state.opts.project_issue_filters[key]
  if type(filters) ~= "table" then
    filters = { state = "open", assignment = "all" }
    M.state.opts.project_issue_filters[key] = filters
  end
  return filters
end

local function save_project_issue_filter(project, dimension, value)
  local filters = project_issue_filters_for(project)
  filters[dimension] = value
  M.state.project_issue_feed = nil
  persist_filter_config()
end

local function render_issue_filters(project, selected_dimension)
  stop_activity_page_loading()
  close_activity_footer()
  M.state.view = "issue_filters"
  M.state.line_targets = {}
  local filters = project_issue_filters_for(project)
  local lines = {
    "",
    "  ISSUE FILTERS",
    "  " .. project_title(project),
    "",
  }
  local headings = { 2 }
  local selected_line
  for _, group in ipairs(issue_filter_options) do
    lines[#lines + 1] = "  " .. group.heading
    headings[#headings + 1] = #lines
    for _, choice in ipairs(group.choices) do
      local line = #lines + 1
      local active = filters[group.dimension] == choice.value
      lines[line] = ("  %s  %s"):format(
        active and "[x]" or "[ ]",
        choice.label
      )
      M.state.line_targets[line] = {
        issue_filter = true,
        project = project,
        dimension = group.dimension,
        value = choice.value,
      }
      if group.dimension == selected_dimension and active then
        selected_line = line
      end
    end
    lines[#lines + 1] = ""
  end
  footer(lines, "<Space> select   q close")
  set_lines(lines)
  vim.wo[M.state.win].cursorline = true
  for _, line in ipairs(headings) do
    highlight(line, 2, -1, line == 2 and "Title" or "Special")
  end
  highlight(3, 2, -1, "Comment")
  for line, target in pairs(M.state.line_targets) do
    local active = filters[target.dimension] == target.value
    highlight(
      line,
      2,
      5,
      active and "DiagnosticOk" or "Comment"
    )
    highlight(line, 7, -1, "Function")
  end
  highlight(#lines, 0, -1, "Comment")
  vim.api.nvim_win_set_cursor(M.state.win, { selected_line or 6, 0 })
end

local function select_project_issue_filter()
  if M.state.view ~= "issue_filters" then
    return
  end
  local target = target_on_cursor()
  if type(target) ~= "table" or not target.issue_filter then
    return
  end
  save_project_issue_filter(
    target.project,
    target.dimension,
    target.value
  )
  render_issue_filters(target.project, target.dimension)
end

-- AGENT_CHANGE_BEGIN codeberg-andrew-kelley-20260727 11 Show the selected forge while activity loads
local function render_loading(target)
  stop_activity_page_loading()
  close_activity_footer()
  M.state.view = "activity"
  M.state.activity_commit_page = false
  M.state.activity_issue_page = target.issues == true
  M.state.activity_return = nil
  M.state.activity_expansion_targets = {}
  M.state.activity_loaded = false
  M.state.activity_error = nil
  local project = target.kind == "project" and target.project or nil
  M.state.activity_scope = project and "project" or "user"
  M.state.activity_project = project
  M.state.contributor = project and nil or target
  local lines = project
      and {
        "",
        target.issues and "  ISSUES" or "  PROJECT",
        "  " .. project_title(project),
      }
    or {
      "",
      "  USER",
      "  @" .. target.username,
    }
  set_lines(lines)
  vim.wo[M.state.win].cursorline = true
  highlight(2, 2, -1, "Function")
  highlight(3, 2, -1, "Comment")
  start_activity_page_loading()
end
-- AGENT_CHANGE_END codeberg-andrew-kelley-20260727 11

local function render_error(message)
  stop_activity_page_loading()
  close_activity_footer()
  M.state.view = "activity"
  M.state.activity_commit_page = false
  M.state.activity_return = nil
  M.state.activity_expansion_targets = {}
  M.state.activity_loaded = false
  M.state.activity_error = message
  local project = M.state.activity_project
  local lines = project
      and {
        "",
        M.state.activity_issue_page and "  ISSUES" or "  PROJECT",
        "  " .. project_title(project),
        "",
        "  Could not load activity",
        "  " .. message,
      }
    or {
      "",
      "  USER",
      "  @" .. M.state.contributor.username,
      "",
      "  Could not load activity",
      "  " .. message,
    }
  footer(lines, "? shortcuts   j/← back   q close")
  set_lines(lines)
  vim.wo[M.state.win].cursorline = true
  highlight(2, 2, -1, "Title")
  highlight(3, 2, -1, "Comment")
  highlight(5, 2, -1, "DiagnosticError")
  highlight(6, 2, -1, "Comment")
end

local function set_activity_inspect_queue_scope()
  local scope
  if M.state.activity_project then
    local project = M.state.activity_project
    scope = table.concat({
      "project",
      project.provider == "codeberg" and "codeberg" or "github",
      project.repository:lower(),
      M.state.activity_issue_page and "issues" or "activity",
    }, ":")
  elseif M.state.contributor then
    local contributor = M.state.contributor
    scope = table.concat({
      "user",
      contributor.provider == "codeberg" and "codeberg" or "github",
      contributor.username:lower(),
    }, ":")
  end
  if scope
    and M.state.activity_inspect_queue_scope ~= scope
    and not M.state.activity_inspect_queue_running
  then
    M.state.activity_inspect_queue = {}
    M.state.activity_inspect_queue_lookup = {}
    M.state.activity_inspect_queue_scope = scope
  end
end

local function render_activity(events, cached, notice, opts)
  stop_activity_page_loading()
  opts = opts or {}
  M.state.view = "activity"
  M.state.activity_commit_page = opts.commit_page == true
  if opts.issue_page ~= nil then
    M.state.activity_issue_page = opts.issue_page == true
  end
  set_activity_inspect_queue_scope()
  if not M.state.activity_commit_page then
    M.state.activity_return = nil
  end
  local contributor = M.state.contributor
  local project = M.state.activity_project
  M.state.events = events
  M.state.activity_cached = cached
  M.state.activity_notice = notice
  M.state.activity_loaded = true
  M.state.activity_error = nil
  M.state.line_targets = {}
  M.state.inspect_targets = {}
  M.state.activity_title_lines = {}
  M.state.activity_expansion_targets = {}
  M.state.activity_scroll_limit_line = nil
  local width = vim.api.nvim_win_get_width(M.state.win)
  local activity_page_number = M.state.activity_page or 1
  local activity_page_count = math.max(
    activity_page_number,
    M.state.activity_loaded_pages or 1
  )
  -- AGENT_CHANGE_BEGIN codeberg-andrew-kelley-20260727 12 Label activity feeds with their forge
  local context_suffix = not M.state.activity_commit_page
      and activity_page_count > 1
      and (" (%d/%d)"):format(
        activity_page_number,
        activity_page_count
      )
    or ""
  local lines = project
      and {
        "",
        M.state.activity_issue_page and "  ISSUES" or "  PROJECT",
        ("  %s · %s%s"):format(
          project_title(project),
          provider_name(project),
          context_suffix
        ),
      }
    or {
      "",
      "  USER",
      ("  %s · %s%s"):format(
        "@" .. contributor.username,
        provider_name(contributor),
        context_suffix
      ),
    }
  -- AGENT_CHANGE_END codeberg-andrew-kelley-20260727 12
  if notice then
    lines[#lines + 1] = "  " .. notice
  end
  lines[#lines + 1] = ""

  local first_event_line
  local scroll_limit_line
  local activity_line_kinds = {}
  for event_index, event in ipairs(events) do
    local item = actions.describe(event, {
      omit_single_commit_count = true,
    })
    if project
      and M.state.activity_issue_page
      and event.type == "IssuesEvent"
    then
      local issue = event.payload and event.payload.issue or {}
      local actor = event.actor or issue.user or {}
      local author = actor.login or actor.username or actor.name
      local state = issue.state == "closed" and "closed" or "open"
      item.text = ("%s%s issue #%s"):format(
        author and ("@" .. author .. " · ") or "",
        state,
        tostring(issue.number or "?")
      )
      item.detail = tostring(issue.title or "Untitled issue")
      item.summary = nil
    elseif project and event.type == "PushEvent" then
      local author = project_push_author(event)
      if author then
        item.text = author .. " " .. item.text
      end
    elseif event.type == "PullRequestEvent" then
      item.text = project_pull_request_title(event, item.text)
    end
    local inspect_context = inspect.activity_context(event)
    local expands_commits = not M.state.activity_commit_page
      and (
        event.type == "PullRequestEvent"
        or (
          event.type == "PushEvent"
          and #(event.payload and event.payload.commits or {}) > 1
        )
      )
    local event_line = #lines + 1
    M.state.activity_title_lines[event_line] = event_line
    if expands_commits then
      M.state.activity_expansion_targets[event_line] = event
    end
    first_event_line = first_event_line or event_line
    activity_line_kinds[event_line] = "main"
    local item_width = width - 2
    if item.detail or item.summary then
      lines[event_line] = activity_item_line(
        without_preview(item),
        activity_time(event.created_at),
        item_width
      )
      local detail_lines, detail_indices = preview_lines(item, item_width)
      if detail_lines then
        for detail_line_index, detail_line in ipairs(detail_lines) do
          lines[#lines + 1] = detail_line
          local detail_target = item.url
          if expands_commits then
            local commit_index = detail_indices[detail_line_index]
            local commit = commit_index
                and event.payload
                and event.payload.commits
                and event.payload.commits[commit_index]
              or nil
            detail_target = commit
                and type(commit.sha) == "string"
                and commit.sha ~= ""
                and commit_activity_url(event, commit.sha)
              or (item.group_url or item.url)
          end
          M.state.line_targets[#lines] = detail_target
          if expands_commits then
            M.state.activity_expansion_targets[#lines] = event
          end
          M.state.inspect_targets[#lines] = inspect_context
          M.state.activity_title_lines[#lines] = event_line
          activity_line_kinds[#lines] = "preview"
        end
      end
      scroll_limit_line = #lines
    else
      lines[event_line] = activity_item_line(
        item,
        activity_time(event.created_at),
        item_width
      )
      scroll_limit_line = event_line
    end
    M.state.line_targets[event_line] = item.url
    M.state.inspect_targets[event_line] = inspect_context
    if event_index < #events then
      lines[#lines + 1] = pad_cell("", item_width)
    end
  end

  if #events == 0 then
    lines[#lines + 1] = M.state.activity_search_return
      and "  No remote activity matches this search."
      or M.state.activity_page > 1
        and "  No past public activity was returned."
      or "  No recent public activity was returned."
    scroll_limit_line = #lines
  end
  M.state.activity_scroll_limit_line = scroll_limit_line
  set_lines(lines)
  render_activity_footer()
  vim.wo[M.state.win].scrolloff = 3

  highlight(2, 2, -1, "Function")
  highlight(3, 2, -1, "Comment")
  if notice then
    highlight(4, 2, -1, "DiagnosticWarn")
  end
  for line, kind in pairs(activity_line_kinds) do
    local text = lines[line]
    if text then
      if kind == "preview" then
        highlight(line, 0, -1, "OculusActivityPreview")
      elseif kind == "main" then
        highlight(line, 0, 5, "OculusActivityIcon")
      end
    end
  end
  for line, title_line in pairs(M.state.activity_title_lines) do
    local target = M.state.line_targets[line]
      or M.state.line_targets[title_line]
    if M.state.activity_inspect_queue_lookup[target] then
      vim.api.nvim_buf_add_highlight(
        M.state.buf,
        activity_inspect_queue_ns,
        "OculusActivityQueued",
        line - 1,
        0,
        -1
      )
    end
  end
  if first_event_line then
    M.state.activity_cursor_min_line = first_event_line
    vim.api.nvim_win_set_cursor(M.state.win, { first_event_line, 0 })
  else
    M.state.activity_cursor_min_line = 2
  end
  update_activity_cursorline()
end

commit_activity_url = function(event, sha)
  local url = type(event.url) == "string" and event.url or ""
  local prefix = url:match("^(.-/commit)/[^/?#]+")
  if prefix then
    return prefix .. "/" .. sha
  end
  local repo = event.repo and event.repo.name
  if repo then
    local activity_source = M.state.activity_project
      or M.state.contributor
    local host = provider_name(activity_source) == "Codeberg"
        and "https://codeberg.org/"
      or "https://github.com/"
    return host .. repo .. "/commit/" .. sha
  end
  return url
end

local function commit_activity_events(event)
  local result = {}
  local payload = event.payload or {}
  for index, commit in ipairs(payload.commits or {}) do
    local sha = commit.sha
    if type(sha) == "string" and sha ~= "" then
      local commit_event = vim.deepcopy(event)
      commit_event.id = ("%s:commit:%d:%s"):format(
        tostring(event.id or "push"),
        index,
        sha
      )
      commit_event.type = "PushEvent"
      commit_event.payload = {
        ref = payload.ref,
        before = payload.before,
        head = sha,
        size = 1,
        commits = { vim.deepcopy(commit) },
      }
      commit_event.url = commit_activity_url(event, sha)
      commit_event.group_url = nil
      commit_event.oculus_text = nil
      commit_event.oculus_detail = nil
      result[#result + 1] = commit_event
    end
  end
  return result
end

local function pull_request_commit_events(event, commits)
  local result = {}
  for index, commit in ipairs(commits or {}) do
    local sha = commit.sha
    if type(sha) == "string" and sha ~= "" then
      local details = type(commit.commit) == "table" and commit.commit or {}
      local author = type(details.author) == "table" and details.author or {}
      local account = type(commit.author) == "table" and commit.author or nil
      local commit_event = vim.deepcopy(event)
      commit_event.id = ("%s:commit:%d:%s"):format(
        tostring(event.id or "pull-request"),
        index,
        sha
      )
      commit_event.type = "PushEvent"
      commit_event.actor = account or { name = author.name }
      commit_event.created_at = author.date or event.created_at
      commit_event.payload = {
        head = sha,
        size = 1,
        commits = {
          {
            sha = sha,
            message = details.message or commit.message,
            author = account or { name = author.name },
          },
        },
      }
      commit_event.url = commit.html_url
        or commit_activity_url(event, sha)
      commit_event.group_url = nil
      commit_event.oculus_text = nil
      commit_event.oculus_detail = nil
      result[#result + 1] = commit_event
    end
  end
  return result
end

local function show_commit_activity(commits)
  if #commits == 0 then
    return false
  end
  M.state.activity_return = {
    events = M.state.events,
    cached = M.state.activity_cached,
    notice = M.state.activity_notice,
    cursor = is_valid_win(M.state.win)
        and vim.api.nvim_win_get_cursor(M.state.win)
      or nil,
    page = M.state.activity_page,
    source_events = M.state.activity_source_events,
  }
  render_activity(commits, false, nil, { commit_page = true })
  return true
end

local function open_commit_activity(event)
  return show_commit_activity(commit_activity_events(event))
end

local function open_pull_request_activity(event)
  local payload = event.payload or {}
  local pull_request = payload.pull_request or {}
  local repo = event.repo and event.repo.name
  local number = pull_request.number or payload.number
  local source = M.state.activity_project or M.state.contributor
  local provider = activity_provider(source)
  if not repo
    or not number
    or type(provider.pull_request_commits) ~= "function"
  then
    return false
  end

  M.state.request_id = M.state.request_id + 1
  local request_id = M.state.request_id
  start_activity_page_loading()
  provider.pull_request_commits(repo, number, M.state.opts, function(
    commits,
    err
  )
    if request_id ~= M.state.request_id
      or M.state.view ~= "activity"
      or M.state.activity_commit_page
      or not is_valid_win(M.state.win)
    then
      return
    end
    if not commits then
      stop_activity_page_loading()
      vim.notify(
        "Oculus: " .. tostring(err or "could not load pull request commits"),
        vim.log.levels.ERROR
      )
      return
    end
    if not show_commit_activity(
      pull_request_commit_events(event, commits)
    ) then
      stop_activity_page_loading()
      vim.notify(
        "Oculus: this pull request has no commits",
        vim.log.levels.INFO
      )
    end
  end)
  return true
end

local function render_shortcuts()
  stop_activity_page_loading()
  close_activity_footer()
  M.state.view = "shortcuts"
  M.state.line_targets = {}

  local lines = {
    "",
    "  KEYBOARD SHORTCUTS",
    "  Commands available throughout Oculus",
  }
  local headings = { 2 }

  local function section(title, entries)
    lines[#lines + 1] = ""
    lines[#lines + 1] = "  " .. title
    headings[#headings + 1] = #lines
    for _, entry in ipairs(entries) do
      lines[#lines + 1] = ("  %-22s %s"):format(entry[1], entry[2])
    end
  end

  section("NAVIGATION", {
    { "<Up>", "Select the previous item" },
    { "k / <Down>", "Select the next item" },
    { "l / <Right> / <CR>", "Select the current item" },
    { "j / <Left>", "Return to the previous page" },
  })
  -- AGENT_CHANGE_BEGIN codeberg-andrew-kelley-20260727 13 Use forge-neutral shortcut descriptions
  section("STARTUP LISTS", {
    { "t", "Switch between project and user lists" },
    { "s /", "Search projects or user handles" },
    { "a", "Add a GitHub or Codeberg project or account" },
    { "r", "Remove the selected project or account" },
    { "f", "Edit filters for the selected user or project" },
    { "F", "Edit global activity filters" },
    { "d", "Reset activity filters to defaults" },
    { "o", "Open the selected contributor profile" },
  })
  section("ACTIVITY", {
    { "h", "Inspect the selected change or issue" },
    { "Tab", "Queue activity for sequential inspection" },
    { "s /", "Search remote activity by keyword" },
    { "b", "Open the selected activity in a browser" },
    { "u", "Open a project's issue activity" },
    { "r", "Refresh the current activity page" },
    { "p", "Load the next eight older activity items" },
    { "l / <Right>", "Open the next older activity page" },
    { "f", "Move forward, or filter a project issue page" },
  })
  -- AGENT_CHANGE_END codeberg-andrew-kelley-20260727 13
  section("FILTER CHECKLIST", {
    { "<Space> / l / <CR>", "Toggle the selected activity type" },
    { "a", "Enable every activity type" },
    { "n", "Disable every activity type" },
  })
  section("GENERAL", {
    { "?", "Open or close this shortcut page" },
    { "q / <Esc> / <C-c>", "Close Oculus" },
  })

  lines[#lines + 1] = ""
  lines[#lines + 1] = "  ? or j/← back   q close"
  set_lines(lines)
  vim.wo[M.state.win].cursorline = false

  for _, line in ipairs(headings) do
    highlight(line, 2, -1, line == 2 and "Title" or "Special")
  end
  highlight(3, 2, -1, "Comment")
  highlight(#lines, 2, -1, "Comment")
  vim.api.nvim_win_set_cursor(M.state.win, { 2, 0 })
end

local function restore_cursor()
  local cursor = M.state.restore_cursor
  local view = M.state.restore_view
  if (not cursor and not view) or not is_valid_win(M.state.win) then
    return
  end

  local line_count = vim.api.nvim_buf_line_count(M.state.buf)
  local line = math.min(math.max(
    cursor and cursor[1] or view and view.lnum or 1,
    1
  ), line_count)
  local column = math.max(
    cursor and cursor[2] or view and view.col or 0,
    0
  )
  if view then
    view.lnum = line
    view.col = column
    view.topline = math.min(
      math.max(view.topline or 1, 1),
      line_count
    )
    vim.api.nvim_win_call(M.state.win, function()
      vim.fn.winrestview(view)
    end)
  else
    vim.api.nvim_win_set_cursor(M.state.win, { line, column })
  end
  M.state.restore_cursor = nil
  M.state.restore_view = nil
end

local function contributor_by_username(username)
  if not username then
    return nil
  end
  for _, contributor in ipairs(M.state.contributors) do
    if contributor.username == username then
      return contributor
    end
  end
  return nil
end

local function activity_page(events, page, page_size)
  local result = {}
  local first = (page - 1) * page_size + 1
  local last = math.min(#events, first + page_size - 1)
  for index = first, last do
    result[#result + 1] = events[index]
  end
  return result
end

M._activity_page = activity_page

local function project_event_allowed(event, project)
  local enabled = {}
  for _, category in ipairs(project_activity_types_for(project) or {}) do
    enabled[category] = true
  end
  local payload = event.payload or {}
  local event_type = event.type or event.event_type
  if event_type == "PushEvent" then
    return enabled.push == true
  end
  if event_type == "PullRequestEvent" then
    local pull_request = payload.pull_request or {}
    local merged = pull_request.merged == true
      or pull_request.merged_at ~= nil
      or pull_request.merged_by ~= nil
    return enabled.merged_pull_request == true
      and (payload.action == "merged"
        or (payload.action == "closed" and merged))
  end
  if event_type == "IssuesEvent" then
    return enabled.assigned_issue == true
      and payload.action == "assigned"
  end
  return false
end

local function filter_project_events(events, project)
  local result = {}
  for _, event in ipairs(events or {}) do
    local event_repository = event.repo
        and (event.repo.name or event.repo.full_name)
      or event.repository
        and (event.repository.full_name or event.repository.name)
      or nil
    local repository_matches = type(event_repository) ~= "string"
      or event_repository == ""
      or event_repository:lower() == project.repository:lower()
    if repository_matches
      and project_event_allowed(event, project)
    then
      result[#result + 1] = event
    end
  end
  return result
end

M._filter_project_events = filter_project_events

local function add_project_feed_event(feed, event)
  local payload = event.payload or {}
  if event.type == "PushEvent" then
    local shas = {}
    for _, commit in ipairs(payload.commits or {}) do
      if type(commit.sha) == "string" and commit.sha ~= "" then
        shas[#shas + 1] = commit.sha
      end
    end
    if #shas == 0 and type(payload.head) == "string" then
      shas[1] = payload.head
    end
    if #shas > 0 then
      for _, sha in ipairs(shas) do
        if feed.seen_commits[sha] then
          return false
        end
      end
      for _, sha in ipairs(shas) do
        feed.seen_commits[sha] = true
      end
    end
  elseif event.type == "PullRequestEvent" then
    local pull_request = payload.pull_request or {}
    local number = pull_request.number or payload.number
    local merged = payload.action == "merged"
      or (payload.action == "closed" and (
        pull_request.merged == true
        or pull_request.merged_at ~= nil
        or pull_request.merged_by ~= nil
      ))
    if number and merged then
      local key = tostring(number)
      if feed.seen_pull_requests[key] then
        return false
      end
      feed.seen_pull_requests[key] = true
    end
  end
  local event_key = event.id and tostring(event.id) or nil
  if event_key and feed.seen[event_key] then
    return false
  end
  feed.events[#feed.events + 1] = event
  if event_key then
    feed.seen[event_key] = true
  end
  return true
end

load_project_activity = function(project, force, page)
  local previous_page = M.state.activity_page or 1
  local preserve_activity_page = page ~= nil
    and M.state.view == "activity"
    and M.state.activity_loaded
    and is_valid_buf(M.state.buf)
  M.state.view = "activity"
  M.state.activity_scope = "project"
  M.state.activity_project = project
  M.state.activity_issue_page = false
  M.state.contributor = nil
  if page == nil then
    M.state.activity_loaded_pages = 1
  end
  local requested_page = math.max(1, page or 1)
  M.state.activity_page = requested_page
  M.state.activity_page_size = math.max(
    1,
    math.floor(tonumber(M.state.opts.results_limit) or 8)
  )
  M.state.request_id = M.state.request_id + 1
  local request_id = M.state.request_id
  if preserve_activity_page then
    M.state.activity_error = nil
    start_activity_page_loading()
  else
    render_loading({ kind = "project", project = project })
  end

  local provider = project.provider == "codeberg" and codeberg or github
  local request_opts = vim.tbl_extend(
    "force",
    M.state.opts,
    { force = force or false }
  )
  request_opts.per_page = project.provider == "codeberg"
      and math.min(50, math.max(16, M.state.activity_page_size * 2))
    or 100
  local activity_types = vim.deepcopy(project_activity_types_for(project) or {})
  table.sort(activity_types)
  local feed_key = table.concat({
    project.provider == "codeberg" and "codeberg" or "github",
    project.repository:lower(),
    table.concat(activity_types, ","),
  }, ":")
  local feed = M.state.project_activity_feed
  if force or not feed or feed.key ~= feed_key then
    feed = {
      key = feed_key,
      events = {},
      seen = {},
      seen_commits = {},
      seen_pull_requests = {},
      next_page = 1,
      -- Codeberg's repository activity feed is both large and dominated by
      -- review/comment events. Its direct commit and merged-PR endpoints avoid
      -- scanning several slow feed pages merely to fill one visible page.
      using_updates = project.provider == "codeberg"
        and type(provider.repository_updates) == "function",
      complete = #activity_types == 0,
      cached = true,
      notice = nil,
    }
    M.state.project_activity_feed = feed
  end
  local required_events = requested_page * M.state.activity_page_size
  local max_source_pages = 10
  request_opts.activity_types = activity_types

  local function use_repository_updates()
    if feed.using_updates
      or type(provider.repository_updates) ~= "function"
    then
      return false
    end
    local useful = false
    for _, category in ipairs(activity_types) do
      if category == "push" or category == "merged_pull_request" then
        useful = true
        break
      end
    end
    if not useful then
      return false
    end
    feed.using_updates = true
    feed.next_page = 1
    feed.complete = false
    return true
  end

  local function render_project_results()
    local filtered = filter_project_events(feed.events, project)
    local first_event =
      (requested_page - 1) * M.state.activity_page_size + 1
    if requested_page > 1 and #filtered < first_event then
      M.state.activity_page = math.max(1, previous_page)
    else
      M.state.activity_page = requested_page
    end
    M.state.activity_source_events = filtered
    M.state.activity_loaded_pages = math.max(
      M.state.activity_loaded_pages or 1,
      M.state.activity_page
    )
    local page_end = M.state.activity_page * M.state.activity_page_size
    M.state.activity_has_past = #filtered > page_end or not feed.complete
    local results = activity_page(
      filtered,
      M.state.activity_page,
      M.state.activity_page_size
    )
    render_activity(results, feed.cached, feed.notice)
    provider.enrich_pull_requests(results, request_opts, function(with_prs)
      if request_id ~= M.state.request_id
        or M.state.view ~= "activity"
        or M.state.activity_project ~= project
      then
        return
      end
      render_activity(with_prs, feed.cached, feed.notice)
      provider.enrich_pushes(with_prs, request_opts, function(enriched)
        if request_id ~= M.state.request_id
          or M.state.view ~= "activity"
          or M.state.activity_project ~= project
        then
          return
        end
        render_activity(enriched, feed.cached, feed.notice)
      end)
    end)
  end

  local function ensure_project_page()
    local filtered = filter_project_events(feed.events, project)
    if #filtered >= required_events or feed.complete then
      render_project_results()
      return
    end
    if feed.next_page > max_source_pages then
      if use_repository_updates() then
        ensure_project_page()
      else
        feed.complete = true
        render_project_results()
      end
      return
    end

    local source_page = feed.next_page
    request_opts.page = source_page
    local request = feed.using_updates
        and provider.repository_updates
      or provider.repository_events
    request(project.repository, request_opts, function(
      events,
      err,
      cached,
      notice
    )
      if request_id ~= M.state.request_id
        or M.state.view ~= "activity"
        or M.state.activity_project ~= project
        or not is_valid_win(M.state.win)
      then
        return
      end
      if err then
        render_error(err)
        return
      end
      local source = events or {}
      local allowed_before = #filter_project_events(feed.events, project)
      local added = 0
      for _, event in ipairs(source) do
        if add_project_feed_event(feed, event) then
          added = added + 1
        end
      end
      local allowed_added = #filter_project_events(feed.events, project)
        - allowed_before
      table.sort(feed.events, function(left, right)
        return tostring(left.created_at or "")
          > tostring(right.created_at or "")
      end)
      feed.next_page = source_page + 1
      feed.cached = feed.cached and cached == true
      feed.notice = feed.notice or notice
      -- GitHub can return fewer rows than requested while still exposing older
      -- repository-event pages (for example, Neovim currently returns 99 for
      -- per_page=100). An empty, duplicate-only, or unusable page switches to
      -- the direct commits/merged-PR feed; otherwise keep filling the page.
      if #source == 0 or added == 0 or allowed_added == 0 then
        if not use_repository_updates() then
          feed.complete = true
        end
      end
      ensure_project_page()
    end)
  end
  if type(provider.repository_events) ~= "function" then
    render_error("this provider does not support project activity")
    return
  end
  ensure_project_page()
end

local function project_issue_allowed(event, project)
  local filters = project_issue_filters_for(project)
  local issue = event.payload and event.payload.issue or {}
  local state = issue.state
    or (event.payload and event.payload.action == "closed" and "closed")
    or "open"
  if filters.state ~= "all" and filters.state ~= state then
    return false
  end
  local assigned = issue.assignee ~= nil
    or (type(issue.assignees) == "table" and #issue.assignees > 0)
  if filters.assignment == "assigned" and not assigned then
    return false
  end
  if filters.assignment == "unassigned" and assigned then
    return false
  end
  return true
end

local function filter_project_issues(events, project)
  local filtered = {}
  for _, event in ipairs(events or {}) do
    if event.type == "IssuesEvent"
      and project_issue_allowed(event, project)
    then
      filtered[#filtered + 1] = event
    end
  end
  return filtered
end

M._filter_project_issues = filter_project_issues

local function add_project_issue(feed, event)
  local issue = event.payload and event.payload.issue or {}
  local key = issue.number and tostring(issue.number)
    or event.id and tostring(event.id)
  if key and feed.seen[key] then
    return false
  end
  feed.events[#feed.events + 1] = event
  if key then
    feed.seen[key] = true
  end
  return true
end

load_project_issues = function(project, force, page)
  local previous_page = M.state.activity_page or 1
  local preserve_activity_page = page ~= nil
    and M.state.view == "activity"
    and M.state.activity_issue_page
    and M.state.activity_loaded
    and is_valid_buf(M.state.buf)
  M.state.view = "activity"
  M.state.activity_scope = "project"
  M.state.activity_project = project
  M.state.activity_issue_page = true
  M.state.activity_commit_page = false
  M.state.contributor = nil
  if page == nil then
    M.state.activity_loaded_pages = 1
  end
  local requested_page = math.max(1, page or 1)
  M.state.activity_page = requested_page
  M.state.activity_page_size = math.max(
    1,
    math.floor(tonumber(M.state.opts.results_limit) or 8)
  )
  M.state.request_id = M.state.request_id + 1
  local request_id = M.state.request_id
  if preserve_activity_page then
    M.state.activity_error = nil
    start_activity_page_loading()
  else
    render_loading({
      kind = "project",
      project = project,
      issues = true,
    })
  end

  local provider = project.provider == "codeberg" and codeberg or github
  if type(provider.repository_issues) ~= "function" then
    render_error("this provider does not support project issues")
    return
  end
  local filters = project_issue_filters_for(project)
  local request_opts = vim.tbl_extend(
    "force",
    M.state.opts,
    { force = force or false }
  )
  request_opts.per_page = project.provider == "codeberg" and 50 or 100
  request_opts.issue_state = filters.state
  local feed_key = table.concat({
    project_issue_filter_key(project),
    filters.state,
    filters.assignment,
  }, ":")
  local feed = M.state.project_issue_feed
  if force or not feed or feed.key ~= feed_key then
    feed = {
      key = feed_key,
      events = {},
      seen = {},
      next_page = 1,
      complete = false,
      cached = true,
    }
    M.state.project_issue_feed = feed
  end
  local required_events = requested_page * M.state.activity_page_size
  local max_source_pages = 10

  local function render_issue_results()
    local filtered = filter_project_issues(feed.events, project)
    local first_event =
      (requested_page - 1) * M.state.activity_page_size + 1
    if requested_page > 1 and #filtered < first_event then
      M.state.activity_page = math.max(1, previous_page)
    else
      M.state.activity_page = requested_page
    end
    M.state.activity_source_events = filtered
    M.state.activity_loaded_pages = math.max(
      M.state.activity_loaded_pages or 1,
      M.state.activity_page
    )
    local page_end = M.state.activity_page * M.state.activity_page_size
    M.state.activity_has_past = #filtered > page_end or not feed.complete
    render_activity(
      activity_page(
        filtered,
        M.state.activity_page,
        M.state.activity_page_size
      ),
      feed.cached,
      nil,
      { issue_page = true }
    )
  end

  local function ensure_issue_page()
    local filtered = filter_project_issues(feed.events, project)
    if #filtered >= required_events or feed.complete then
      render_issue_results()
      return
    end
    if feed.next_page > max_source_pages then
      feed.complete = true
      render_issue_results()
      return
    end
    local source_page = feed.next_page
    request_opts.page = source_page
    provider.repository_issues(project.repository, request_opts, function(
      events,
      err,
      cached,
      complete
    )
      if request_id ~= M.state.request_id
        or M.state.view ~= "activity"
        or not M.state.activity_issue_page
        or M.state.activity_project ~= project
        or not is_valid_win(M.state.win)
      then
        return
      end
      if err then
        render_error(err)
        return
      end
      local source = events or {}
      for _, event in ipairs(source) do
        add_project_issue(feed, event)
      end
      table.sort(feed.events, function(left, right)
        return tostring(left.created_at or "")
          > tostring(right.created_at or "")
      end)
      feed.next_page = source_page + 1
      feed.cached = feed.cached and cached == true
      if complete == true or (complete == nil and #source == 0) then
        feed.complete = true
      end
      ensure_issue_page()
    end)
  end

  ensure_issue_page()
end

local function load_activity(contributor, force, page)
  local preserve_activity_page = page ~= nil
    and M.state.view == "activity"
    and M.state.activity_loaded
    and is_valid_buf(M.state.buf)
  M.state.view = "activity"
  M.state.activity_scope = "user"
  M.state.activity_project = nil
  M.state.activity_has_past = nil
  M.state.contributor = contributor
  if page == nil then
    M.state.activity_loaded_pages = 1
  end
  M.state.activity_page = math.max(1, page or 1)
  M.state.activity_page_size = math.max(
    1,
    math.floor(tonumber(M.state.opts.results_limit) or 8)
  )
  M.state.request_id = M.state.request_id + 1
  local request_id = M.state.request_id
  if preserve_activity_page then
    M.state.activity_error = nil
    start_activity_page_loading()
  else
    render_loading(contributor)
  end

  -- AGENT_CHANGE_BEGIN codeberg-andrew-kelley-20260727 14 Load and enrich activity through the contributor's provider
  local provider = activity_provider(contributor)
  local request_opts = vim.tbl_extend(
    "force",
    M.state.opts,
    { force = force or false }
  )
  local base_per_page =
    math.max(1, math.floor(tonumber(M.state.opts.per_page) or 30))
  request_opts.per_page = base_per_page
    + (M.state.activity_page - 1) * M.state.activity_page_size
  local callback = function(events, err, cached, notice)
    if request_id ~= M.state.request_id
      or M.state.view ~= "activity"
      or not is_valid_win(M.state.win)
    then
      return
    end
    if err then
      render_error(err)
    else
      local filtered = actions.filter(events, activity_types_for(contributor))
      M.state.activity_source_events = filtered
      M.state.activity_loaded_pages = math.max(
        M.state.activity_loaded_pages or 1,
        M.state.activity_page
      )
      local results = activity_page(
        filtered,
        M.state.activity_page,
        M.state.activity_page_size
      )
      render_activity(results, cached, notice)
      provider.enrich_pull_requests(results, request_opts, function(with_prs)
        if request_id ~= M.state.request_id or M.state.view ~= "activity" then
          return
        end
        render_activity(with_prs, cached, notice)
        provider.enrich_pushes(with_prs, request_opts, function(enriched)
          if request_id ~= M.state.request_id or M.state.view ~= "activity" then
            return
          end
          render_activity(enriched, cached, notice)
        end)
      end)
    end
  end

  provider.events(contributor.username, request_opts, callback)
  -- AGENT_CHANGE_END codeberg-andrew-kelley-20260727 14
end

local function next_activity_page()
  if
    M.state.view ~= "activity"
    or M.state.activity_commit_page
    or (not M.state.contributor and not M.state.activity_project)
  then
    return
  end
  if M.state.activity_search_return then
    local next_page = (M.state.activity_page or 1) + 1
    if #(M.state.activity_search_results or {})
        >= (next_page - 1) * M.state.activity_page_size + 1
    then
      show_activity_search_page(next_page)
    elseif M.state.activity_search_feed
      and not M.state.activity_search_feed.complete
    then
      start_activity_page_loading()
      ensure_activity_search_results(
        next_page * M.state.activity_page_size,
        next_page
      )
    end
    return
  end
  local page = (M.state.activity_page or 1) + 1
  if M.state.activity_project then
    if M.state.activity_has_past == false then
      return
    end
    if M.state.activity_issue_page then
      load_project_issues(M.state.activity_project, false, page)
    else
      load_project_activity(M.state.activity_project, false, page)
    end
  else
    load_activity(M.state.contributor, false, page)
  end
end

local function previous_activity_page()
  if
    M.state.view ~= "activity"
    or M.state.activity_commit_page
    or (not M.state.contributor and not M.state.activity_project)
    or (M.state.activity_page or 1) == 1
  then
    return
  end
  if M.state.activity_search_return then
    show_activity_search_page(M.state.activity_page - 1)
    return
  end
  local page = (M.state.activity_page or 1) - 1
  if M.state.activity_project then
    if M.state.activity_issue_page then
      load_project_issues(M.state.activity_project, false, page)
    else
      load_project_activity(M.state.activity_project, false, page)
    end
  else
    load_activity(M.state.contributor, false, page)
  end
end

local function refresh_activity()
  if M.state.view ~= "activity" or M.state.activity_commit_page then
    return
  end
  if M.state.activity_search_return then
    start_activity_search(
      M.state.activity_search_query or "",
      M.state.activity_page or 1
    )
    return
  end
  local page = M.state.activity_page or 1
  if M.state.activity_project then
    if M.state.activity_issue_page then
      load_project_issues(M.state.activity_project, true, page)
    else
      load_project_activity(M.state.activity_project, true, page)
    end
  elseif M.state.contributor then
    load_activity(M.state.contributor, true, page)
  end
end

local function search_win_config()
  if not is_valid_win(M.state.win) then
    return nil
  end
  local position = vim.api.nvim_win_get_position(M.state.win)
  local parent_width = vim.api.nvim_win_get_width(M.state.win)
  local activity_search = M.state.search_kind == "activity"
  local left_width = preview_left_width(parent_width)
  local search_col = activity_search
      and position[2] + 4
    or position[2] + 2
  local search_width = activity_search
      and math.max(1, parent_width - 8)
    or math.max(1, left_width - 6)
  return {
    relative = "editor",
    width = search_width,
    height = 1,
    row = position[1] + 1,
    col = search_col,
    style = "minimal",
    border = M.state.opts.border or "rounded",
    zindex = 70,
  }
end

local function clear_search_window()
  M.state.closing_search = true
  local search_win = M.state.search_win
  local search_buf = M.state.search_buf
  M.state.search_win = nil
  M.state.search_buf = nil
  if is_valid_win(search_win) and vim.api.nvim_get_current_win() == search_win then
    vim.cmd("stopinsert")
  end
  if is_valid_win(search_win) then
    vim.api.nvim_win_close(search_win, true)
  end
  if is_valid_buf(search_buf) then
    vim.api.nvim_buf_delete(search_buf, { force = true })
  end
  M.state.closing_search = false
end

local function clear_search_state()
  M.state.search_query = nil
  M.state.search_kind = nil
  M.state.search_backspace_pending = false
  M.state.search_results = nil
  M.state.search_index = 1
  M.state.search_return = nil
end

local function restore_activity_search()
  local return_state = M.state.activity_search_return
  M.state.request_id = M.state.request_id + 1
  stop_activity_page_loading()
  M.state.activity_search_query = nil
  M.state.activity_search_results = nil
  M.state.activity_search_return = nil
  M.state.activity_search_feed = nil
  if not return_state or not is_valid_win(M.state.win) then
    return
  end
  M.state.activity_page = return_state.page
  M.state.activity_loaded_pages = return_state.loaded_pages
  M.state.activity_source_events = return_state.source_events
  M.state.activity_has_past = return_state.has_past
  render_activity(
    return_state.events,
    return_state.cached,
    return_state.notice,
    {
      commit_page = return_state.commit_page,
      issue_page = return_state.issue_page,
    }
  )
  if return_state.cursor then
    local line_count = vim.api.nvim_buf_line_count(M.state.buf)
    vim.api.nvim_win_set_cursor(M.state.win, {
      math.min(return_state.cursor[1], line_count),
      return_state.cursor[2],
    })
    update_activity_cursorline()
  end
end

local function cancel_search()
  if M.state.search_query == nil then
    return
  end
  local return_state = M.state.search_return
  local activity_search = M.state.search_kind == "activity"
  clear_search_window()
  clear_search_state()
  if activity_search then
    if is_valid_win(M.state.win) then
      vim.api.nvim_set_current_win(M.state.win)
    end
    restore_activity_search()
    return
  end
  if return_state then
    M.state.community_view = return_state.community_view
    M.state.selected_username = return_state.selected_username
    M.state.selected_project = return_state.selected_project
    M.state.contributor_offset = return_state.contributor_offset
  end
  if is_valid_win(M.state.win) then
    vim.api.nvim_set_current_win(M.state.win)
    render_contributors()
  end
end

local function prompt_query(buf)
  local line = vim.api.nvim_buf_get_lines(
    buf,
    0,
    1,
    false
  )[1] or ""
  local prompt = vim.fn.prompt_getprompt(buf)
  if prompt ~= "" and line:sub(1, #prompt) == prompt then
    return line:sub(#prompt + 1)
  end
  return line
end

M._prompt_query = prompt_query

local function append_activity_search_values(parts, value, depth)
  if depth > 6 then
    return
  end
  local value_type = type(value)
  if value_type == "string" or value_type == "number" then
    parts[#parts + 1] = tostring(value)
    return
  end
  if value_type ~= "table" then
    return
  end
  for _, child in pairs(value) do
    append_activity_search_values(parts, child, depth + 1)
  end
end

local function activity_matches_query(event, query)
  local words = {}
  for word in tostring(query or ""):lower():gmatch("%S+") do
    words[#words + 1] = word
  end
  if #words == 0 then
    return true
  end
  local parts = {}
  append_activity_search_values(parts, event, 0)
  local item = actions.describe(event, { omit_single_commit_count = true })
  append_activity_search_values(parts, item, 0)
  local haystack = table.concat(parts, " "):lower()
  for _, word in ipairs(words) do
    if not haystack:find(word, 1, true) then
      return false
    end
  end
  return true
end

M._activity_matches_query = activity_matches_query

local function activity_search_event_key(event)
  if event.id ~= nil then
    return "id:" .. tostring(event.id)
  end
  return table.concat({
    tostring(event.type or ""),
    tostring(event.url or event.group_url or ""),
    tostring(event.created_at or ""),
  }, ":")
end

local function activity_search_source(events)
  if M.state.activity_project then
    if M.state.activity_issue_page then
      return filter_project_issues(events, M.state.activity_project)
    end
    return filter_project_events(events, M.state.activity_project)
  end
  return actions.filter(
    events,
    activity_types_for(M.state.contributor)
  )
end

show_activity_search_page = function(page)
  local return_state = M.state.activity_search_return
  if not return_state then
    return
  end
  local requested_page = math.max(1, page or 1)
  local page_count = math.max(1, math.ceil(
    #M.state.activity_search_results / M.state.activity_page_size
  ))
  M.state.activity_page = math.min(requested_page, page_count)
  M.state.activity_loaded_pages = page_count
  local feed = M.state.activity_search_feed
  M.state.activity_has_past = M.state.activity_page < page_count
    or (feed and not feed.complete) or false
  local results = activity_page(
    M.state.activity_search_results,
    M.state.activity_page,
    M.state.activity_page_size
  )
  render_activity(results, false, nil, {
    commit_page = false,
    issue_page = return_state.issue_page,
  })

  local provider = M.state.activity_project
      and activity_provider(M.state.activity_project)
    or activity_provider(M.state.contributor)
  local request_opts = vim.tbl_extend("force", M.state.opts, {
    force = false,
    activity_search = true,
  })
  provider.enrich_pull_requests(results, request_opts, function(with_prs)
    if not M.state.activity_search_return
      or M.state.activity_page ~= requested_page
    then
      return
    end
    render_activity(with_prs, false, nil, {
      commit_page = false,
      issue_page = return_state.issue_page,
    })
    provider.enrich_pushes(with_prs, request_opts, function(enriched)
      if not M.state.activity_search_return
        or M.state.activity_page ~= requested_page
      then
        return
      end
      render_activity(enriched, false, nil, {
        commit_page = false,
        issue_page = return_state.issue_page,
      })
    end)
  end)
end

ensure_activity_search_results = function(required_results, requested_page)
  local feed = M.state.activity_search_feed
  local return_state = M.state.activity_search_return
  if not feed or not return_state then
    stop_activity_page_loading()
    return
  end
  if #M.state.activity_search_results >= required_results
    or feed.complete
  then
    show_activity_search_page(requested_page)
    return
  end
  if feed.next_page > feed.max_pages then
    feed.complete = true
    show_activity_search_page(requested_page)
    return
  end

  local project = M.state.activity_project
  local contributor = M.state.contributor
  local provider = project and activity_provider(project)
    or activity_provider(contributor)
  local request_opts = vim.tbl_extend("force", M.state.opts, {
    force = true,
    activity_search = true,
    search_query = M.state.activity_search_query,
    page = feed.next_page,
    per_page = project and project.provider == "codeberg" and 50 or 100,
  })
  local request
  local subject
  local callback_kind = "events"
  if project and M.state.activity_issue_page then
    request = provider.repository_issues
    subject = project.repository
    local filters = project_issue_filters_for(project)
    request_opts.issue_state = filters.state
    callback_kind = "issues"
  elseif project then
    request = project.provider == "codeberg"
        and provider.repository_updates
      or provider.repository_events
    subject = project.repository
    request_opts.activity_types = project_activity_types_for(project)
    callback_kind = project.provider == "codeberg" and "updates"
      or "events"
  else
    request = provider.events
    subject = contributor.username
  end
  if type(request) ~= "function" then
    feed.complete = true
    show_activity_search_page(requested_page)
    return
  end

  local request_id = M.state.request_id
  local source_page = feed.next_page
  request(subject, request_opts, function(events, err, _, fourth)
    if request_id ~= M.state.request_id
      or feed ~= M.state.activity_search_feed
      or not M.state.activity_search_return
      or not is_valid_win(M.state.win)
    then
      return
    end
    if err then
      restore_activity_search()
      vim.notify(
        "Oculus activity search failed: " .. tostring(err),
        vim.log.levels.ERROR
      )
      return
    end
    local source = activity_search_source(events or {})
    local added = 0
    for _, event in ipairs(source) do
      local key = activity_search_event_key(event)
      if not feed.seen[key] then
        feed.seen[key] = true
        added = added + 1
        if activity_matches_query(event, M.state.activity_search_query) then
          M.state.activity_search_results[#M.state.activity_search_results + 1]
            = event
        end
      end
    end
    table.sort(M.state.activity_search_results, function(left, right)
      return tostring(left.created_at or "")
        > tostring(right.created_at or "")
    end)
    feed.next_page = source_page + 1
    -- GitHub's Events API occasionally returns a short non-final page. Keep
    -- following its documented three-page window until an empty/duplicate
    -- page; issue lists and Codeberg feeds have reliable completion signals.
    local is_codeberg = (project and project.provider)
        == "codeberg"
      or (contributor and contributor.provider) == "codeberg"
    local provider_complete = fourth == true
      and (
        callback_kind == "issues"
        or (is_codeberg and callback_kind ~= "updates")
      )
    if #events == 0 or added == 0 or provider_complete then
      feed.complete = true
    end
    ensure_activity_search_results(required_results, requested_page)
  end)
end

start_activity_search = function(query, requested_page)
  local return_state = M.state.activity_search_return
  if not return_state then
    return
  end
  M.state.request_id = M.state.request_id + 1
  M.state.activity_search_query = query
  M.state.activity_search_results = {}
  local configured_max = math.max(
    1,
    math.floor(tonumber(M.state.opts.activity_search_max_pages) or 5)
  )
  if (M.state.activity_project and M.state.activity_project.provider)
      ~= "codeberg"
    and (M.state.contributor and M.state.contributor.provider)
      ~= "codeberg"
  then
    configured_max = math.min(configured_max, 3)
  end
  M.state.activity_search_feed = {
    next_page = 1,
    max_pages = configured_max,
    complete = false,
    seen = {},
  }
  local page = math.max(1, requested_page or 1)
  M.state.activity_page = page
  start_activity_page_loading()
  ensure_activity_search_results(
    page * M.state.activity_page_size,
    page
  )
end

local function matching_search_items(query)
  if M.state.search_kind == "activity" then
    return {}
  end
  if M.state.search_kind == "projects" then
    return fuzzy_projects(M.state.opts.projects, query)
  end
  return fuzzy_contributors(M.state.contributors, query)
end

local function select_search_item(item)
  if M.state.search_kind == "projects" then
    M.state.selected_project = item
    M.state.selected_username = nil
  else
    M.state.selected_username = item and item.username or nil
    M.state.selected_project = nil
  end
end

local function update_search_results()
  if
    M.state.search_query == nil
    or not is_valid_buf(M.state.search_buf)
    or not is_valid_win(M.state.win)
  then
    return
  end
  local line = prompt_query(M.state.search_buf)
  local close_after_backspace = M.state.search_backspace_pending
    and line == ""
  M.state.search_backspace_pending = false
  if close_after_backspace then
    vim.schedule(cancel_search)
    return
  end
  M.state.search_query = line
  if M.state.search_kind == "activity" then
    return
  end
  M.state.search_results = matching_search_items(line)
  M.state.search_index = 1
  M.state.contributor_offset = 1
  local first = M.state.search_results[1]
  select_search_item(first)
  render_contributors()
end

local function move_search_selection(direction)
  local results = M.state.search_results or {}
  if #results == 0 then
    return
  end
  M.state.search_index = (
    (M.state.search_index - 1 + direction) % #results
  ) + 1
  select_search_item(results[M.state.search_index])
  render_contributors()
end

local function accept_search()
  if M.state.search_kind == "activity" then
    local query = vim.trim(prompt_query(M.state.search_buf))
    clear_search_window()
    clear_search_state()
    if is_valid_win(M.state.win) then
      vim.api.nvim_set_current_win(M.state.win)
    end
    if query == "" then
      restore_activity_search()
    else
      start_activity_search(query, 1)
    end
    return
  end
  local results = M.state.search_results or {}
  local item = results[M.state.search_index]
  if not item then
    return
  end
  local search_kind = M.state.search_kind
  clear_search_window()
  clear_search_state()
  if is_valid_win(M.state.win) then
    vim.api.nvim_set_current_win(M.state.win)
    if search_kind == "projects" then
      M.state.selected_project = item
      M.state.selected_username = nil
      load_project_activity(item, false)
    else
      M.state.selected_username = item.username
      M.state.selected_project = nil
      load_activity(item, false)
    end
  end
end

local function open_search()
  if (M.state.view ~= "contributors" and M.state.view ~= "activity")
    or not is_valid_win(M.state.win)
  then
    return
  end
  if is_valid_win(M.state.search_win) then
    vim.api.nvim_set_current_win(M.state.search_win)
    vim.cmd("startinsert")
    return
  end

  local activity_search = M.state.view == "activity"
  if activity_search then
    if not M.state.activity_search_return then
      M.state.activity_search_return = {
        events = M.state.events,
        cached = M.state.activity_cached,
        notice = M.state.activity_notice,
        cursor = vim.api.nvim_win_get_cursor(M.state.win),
        page = M.state.activity_page,
        loaded_pages = M.state.activity_loaded_pages,
        source_events = M.state.activity_source_events,
        has_past = M.state.activity_has_past,
        commit_page = M.state.activity_commit_page,
        issue_page = M.state.activity_issue_page,
      }
    end
    M.state.request_id = M.state.request_id + 1
    M.state.search_kind = "activity"
  else
    M.state.search_return = {
      community_view = M.state.community_view,
      selected_username = M.state.selected_username,
      selected_project = M.state.selected_project,
      contributor_offset = M.state.contributor_offset,
    }
    M.state.search_kind = M.state.community_view or "projects"
  end
  M.state.search_query = ""
  M.state.search_backspace_pending = false
  M.state.search_results = activity_search and {}
    or matching_search_items("")
  M.state.search_index = 1
  if not activity_search then
    for index, item in ipairs(M.state.search_results) do
      local selected = M.state.search_kind == "projects"
          and project_key(item) == project_key(M.state.selected_project)
        or M.state.search_kind == "users"
          and item.username == M.state.selected_username
      if selected then
        M.state.search_index = index
        break
      end
    end
    render_contributors()
  end

  local buf = vim.api.nvim_create_buf(false, true)
  M.state.search_buf = buf
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].buftype = "prompt"
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = "oculus-search"
  vim.fn.prompt_setprompt(buf, "")

  local config = search_win_config()
  if not config then
    cancel_search()
    return
  end
  M.state.opening_search = true
  local win = vim.api.nvim_open_win(buf, true, config)
  M.state.opening_search = false
  M.state.search_win = win
  vim.wo[win].wrap = false
  vim.wo[win].number = false
  vim.wo[win].relativenumber = false
  vim.wo[win].signcolumn = "no"
  vim.wo[win].winhighlight = table.concat({
    "Normal:OculusNormal",
    "NormalFloat:OculusNormal",
    "FloatBorder:OculusBorder",
    "FloatTitle:OculusBorder",
  }, ",")
  M.apply_window_highlights(win)

  local search_map = function(lhs, rhs, desc)
    vim.keymap.set({ "i", "n" }, lhs, rhs, {
      buffer = buf,
      nowait = true,
      silent = true,
      desc = desc,
    })
  end
  local item_kind = M.state.search_kind == "projects"
      and "project"
    or M.state.search_kind == "activity" and "activity"
    or "user"
  search_map("<Esc>", cancel_search, "Cancel Oculus " .. item_kind .. " search")
  search_map("<C-c>", cancel_search, "Cancel Oculus " .. item_kind .. " search")
  vim.keymap.set("i", "<BS>", function()
    if prompt_query(buf) == "" then
      cancel_search()
      return ""
    end
    M.state.search_backspace_pending = true
    return "<BS>"
  end, {
    buffer = buf,
    expr = true,
    nowait = true,
    silent = true,
    desc = "Close empty Oculus " .. item_kind .. " search",
  })
  search_map("<CR>", accept_search, "Open searched Oculus " .. item_kind)
  if not activity_search then
    search_map("<Down>", function()
      move_search_selection(1)
    end, "Preview next Oculus " .. item_kind .. " search result")
    search_map("<Up>", function()
      move_search_selection(-1)
    end, "Preview previous Oculus " .. item_kind .. " search result")
    search_map("<C-n>", function()
      move_search_selection(1)
    end, "Preview next Oculus " .. item_kind .. " search result")
    search_map("<C-p>", function()
      move_search_selection(-1)
    end, "Preview previous Oculus " .. item_kind .. " search result")
    search_map("<C-k>", function()
      move_search_selection(1)
    end, "Move down in Oculus " .. item_kind .. " search results")
  end

  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
    group = autocmd_group,
    buffer = buf,
    callback = update_search_results,
  })
  vim.api.nvim_create_autocmd("WinClosed", {
    group = autocmd_group,
    pattern = tostring(win),
    callback = function()
      if M.state.closing_search or M.state.search_query == nil then
        return
      end
      vim.schedule(cancel_search)
    end,
  })
  vim.cmd("startinsert")
end

local function add_contributor(contributor)
  local username = vim.trim(tostring(contributor.username or ""))
    :gsub("^@", "")
  if
    username == ""
    or not username:match("^[%w][%w%._%-]*$")
  then
    vim.notify(
      "Oculus: enter a valid account handle",
      vim.log.levels.WARN
    )
    return false
  end

  local added = vim.deepcopy(contributor)
  added.username = username
  added.provider = added.provider == "codeberg" and "codeberg" or "github"
  added.name = added.name or username
  added.description = nil
  if has_contributor(M.state.contributors, added) then
    vim.notify(
      ("Oculus: @%s is already in your %s list"):format(
        username,
        provider_name(added)
      ),
      vim.log.levels.INFO
    )
    return false
  end

  M.state.contributors[#M.state.contributors + 1] = added
  M.state.opts.removed_contributors = vim.tbl_filter(function(key)
    return type(key) ~= "string"
      or key:lower() ~= contributor_key(added):lower()
  end, M.state.opts.removed_contributors or {})
  M.state.selected_username = added.username
  persist_contributors()
  return true
end

local function add_project(project)
  local repository = vim.trim(tostring(project.repository or ""))
    :gsub("^/+", "")
    :gsub("/+$", "")
    :gsub("%.git$", "")
  if not repository:match("^[%w%._%-]+/[%w%._%-]+$") then
    vim.notify(
      "Oculus: enter a repository as owner/repo",
      vim.log.levels.WARN
    )
    return false
  end

  local added = vim.deepcopy(project)
  added.repository = repository
  added.provider = added.provider == "codeberg" and "codeberg" or "github"
  added.name = added.name or repository:match("([^/]+)$")
  if has_project(M.state.opts.projects, added) then
    vim.notify(
      ("Oculus: %s is already in your %s project list"):format(
        repository,
        provider_name(added)
      ),
      vim.log.levels.INFO
    )
    return false
  end

  M.state.opts.projects = M.state.opts.projects or {}
  M.state.opts.projects[#M.state.opts.projects + 1] = added
  M.state.opts.removed_projects = vim.tbl_filter(function(key)
    return type(key) ~= "string"
      or key:lower() ~= project_key(added):lower()
  end, M.state.opts.removed_projects or {})
  M.state.selected_project = added
  persist_projects()
  return true
end

local function prompt_add_account()
  if M.state.view ~= "contributors" then
    return
  end
  local adding_project = M.state.community_view == "projects"
  M.state.opening_account_prompt = true
  vim.ui.select(
    {
      { provider = "github", label = "GitHub" },
      { provider = "codeberg", label = "Codeberg" },
    },
    {
      prompt = adding_project
          and "Add project from:"
        or "Add account from:",
      format_item = function(item)
        return item.label
      end,
    },
    function(choice)
      if not choice then
        M.state.opening_account_prompt = false
        return
      end
      vim.ui.input(
        {
          prompt = choice.label
              .. (adding_project and " repository: " or " handle: @"),
        },
        function(value)
          M.state.opening_account_prompt = false
          local added = value and (
            adding_project
                and add_project({
                  repository = value,
                  provider = choice.provider,
                })
              or add_contributor({
                username = value,
                provider = choice.provider,
              })
          )
          if added and is_valid_win(M.state.win) then
            vim.api.nvim_set_current_win(M.state.win)
            render_contributors()
          end
        end
      )
    end
  )
end

local function remember_removed(option, key)
  local removed = M.state.opts[option] or {}
  for _, existing in ipairs(removed) do
    if type(existing) == "string"
      and existing:lower() == key:lower()
    then
      return
    end
  end
  removed[#removed + 1] = key
  M.state.opts[option] = removed
end

local function remove_current_item()
  if M.state.view ~= "contributors" then
    return
  end
  local target = target_on_cursor()
  if type(target) ~= "table" then
    return
  end
  if target.kind == "project" then
    local key = project_key(target.project)
    if not key then
      return
    end
    for index, project in ipairs(M.state.opts.projects or {}) do
      if project_key(project) == key then
        table.remove(M.state.opts.projects, index)
        break
      end
    end
    remember_removed("removed_projects", key)
    M.state.selected_project = nil
    persist_projects()
    render_contributors()
    return
  end
  local key = contributor_key(target)
  if not key then
    return
  end
  for index, added in ipairs(M.state.contributors) do
    if contributor_key(added) == key then
      table.remove(M.state.contributors, index)
      break
    end
  end
  remember_removed("removed_contributors", key)
  M.state.selected_username = nil
  persist_contributors()
  render_contributors()
end

target_on_cursor = function()
  if not is_valid_win(M.state.win) then
    return nil
  end
  local line = vim.api.nvim_win_get_cursor(M.state.win)[1]
  if M.state.line_targets[line] then
    return M.state.line_targets[line]
  end
end

local function open_url(url)
  local ok, err = browser.open(url, M.state.opts)
  if not ok and err then
    vim.notify("Oculus: " .. tostring(err), vim.log.levels.ERROR)
  end
end

local function open_activity_expansion()
  if M.state.view ~= "activity" or not is_valid_win(M.state.win) then
    return false
  end
  local line = vim.api.nvim_win_get_cursor(M.state.win)[1]
  local event = M.state.activity_expansion_targets[line]
  if not event then
    return false
  end
  if event.type == "PullRequestEvent" then
    return open_pull_request_activity(event)
  end
  return open_commit_activity(event)
end

local function select_current()
  local target = target_on_cursor()
  if M.state.view == "contributors" and type(target) == "table" then
    if target.kind == "project" then
      M.state.selected_project = target.project
      M.state.selected_username = nil
      M.state.project_issue_return = nil
      load_project_activity(target.project, false)
    else
      M.state.selected_project = nil
      M.state.selected_username = target.username
      load_activity(target, false)
    end
  elseif M.state.view == "activity" then
    open_activity_expansion()
  elseif M.state.view == "filters" then
    toggle_filter_type()
  elseif M.state.view == "issue_filters" then
    select_project_issue_filter()
  end
end

local function open_project_issue_activity()
  if M.state.view ~= "activity"
    or M.state.activity_commit_page
    or M.state.activity_issue_page
    or not M.state.activity_project
  then
    return
  end
  M.state.project_issue_return = {
    events = M.state.events,
    cached = M.state.activity_cached,
    notice = M.state.activity_notice,
    page = M.state.activity_page,
    loaded_pages = M.state.activity_loaded_pages,
    source_events = M.state.activity_source_events,
    has_past = M.state.activity_has_past,
    cursor = is_valid_win(M.state.win)
        and vim.api.nvim_win_get_cursor(M.state.win)
      or nil,
  }
  load_project_issues(M.state.activity_project, false)
end

local function open_filters(global)
  if global then
    render_filters({ global = true })
    return
  end

  local scope
  if M.state.view == "contributors" then
    local target = target_on_cursor()
    if type(target) == "table" and target.kind == "project" then
      scope = { project = target.project }
    else
      scope = target
    end
  elseif M.state.view == "activity" then
    scope = M.state.activity_project or M.state.contributor
    if M.state.activity_project then
      scope = { project = M.state.activity_project }
    end
  end
  if type(scope) == "table"
    and (scope.project or scope.username)
  then
    render_filters(scope)
  end
end

local function open_current()
  local target = target_on_cursor()
  -- AGENT_CHANGE_BEGIN codeberg-andrew-kelley-20260727 16 Open profiles on the contributor's forge
  if M.state.view == "contributors"
    and type(target) == "table"
    and target.kind ~= "project"
  then
    open_url(contributor_profile_url(target))
  end
  -- AGENT_CHANGE_END codeberg-andrew-kelley-20260727 16
end

local function open_activity_in_browser()
  if M.state.view ~= "activity" then
    return
  end
  local target = target_on_cursor()
  if type(target) == "string" then
    open_url(target)
  end
end

local function rebuild_activity_inspect_queue_lookup()
  local lookup = {}
  for _, entry in ipairs(M.state.activity_inspect_queue or {}) do
    lookup[entry.url] = true
  end
  M.state.activity_inspect_queue_lookup = lookup
end

local function apply_activity_inspect_queue_highlights()
  if not is_valid_buf(M.state.buf) then
    return
  end
  vim.api.nvim_buf_clear_namespace(
    M.state.buf,
    activity_inspect_queue_ns,
    0,
    -1
  )
  if M.state.view ~= "activity" then
    return
  end
  for line, title_line in pairs(M.state.activity_title_lines) do
    local target = M.state.line_targets[line]
      or M.state.line_targets[title_line]
    if M.state.activity_inspect_queue_lookup[target] then
      vim.api.nvim_buf_add_highlight(
        M.state.buf,
        activity_inspect_queue_ns,
        "OculusActivityQueued",
        line - 1,
        0,
        -1
      )
    end
  end
end

local function toggle_activity_inspect_queue()
  if M.state.view ~= "activity"
    or M.state.activity_inspect_queue_running
  then
    return
  end
  local source_line = vim.api.nvim_win_get_cursor(M.state.win)[1]
  local title_line = M.state.activity_title_lines[source_line] or source_line
  local url = M.state.line_targets[source_line]
    or M.state.line_targets[title_line]
  local context = M.state.inspect_targets[source_line]
    or M.state.inspect_targets[title_line]
  if type(url) ~= "string"
    or not inspect._parse_target_url(url)
  then
    vim.notify(
      "Oculus: this activity does not have an inspectable target",
      vim.log.levels.WARN
    )
    return
  end

  local removed = false
  for index, entry in ipairs(M.state.activity_inspect_queue) do
    if entry.url == url then
      table.remove(M.state.activity_inspect_queue, index)
      removed = true
      break
    end
  end
  if not removed then
    M.state.activity_inspect_queue[#M.state.activity_inspect_queue + 1] = {
      url = url,
      context = type(context) == "table" and vim.deepcopy(context) or nil,
    }
  end
  rebuild_activity_inspect_queue_lookup()
  apply_activity_inspect_queue_highlights()
end

local open_next_queued_activity

open_next_queued_activity = function(ui_lifecycle)
  local entry = table.remove(M.state.activity_inspect_queue, 1)
  rebuild_activity_inspect_queue_lookup()
  apply_activity_inspect_queue_highlights()
  if not entry then
    M.state.activity_inspect_queue_running = false
    return true
  end

  local function continue_queue()
    vim.schedule(function()
      open_next_queued_activity(nil)
    end)
  end
  local lifecycle = {
    on_progress = ui_lifecycle and ui_lifecycle.on_progress or nil,
    on_complete = function(message)
      if ui_lifecycle and ui_lifecycle.on_complete then
        ui_lifecycle.on_complete(message)
      elseif message then
        vim.notify("Oculus: " .. tostring(message), vim.log.levels.WARN)
      end
      if message then
        continue_queue()
      end
    end,
    on_closed = continue_queue,
  }
  local ok, err = inspect.open(
    entry.url,
    M.state.opts,
    entry.context,
    lifecycle
  )
  if not ok then
    if ui_lifecycle and ui_lifecycle.on_complete then
      ui_lifecycle.on_complete(err)
    elseif err then
      vim.notify("Oculus: " .. tostring(err), vim.log.levels.WARN)
    end
    continue_queue()
  end
  return ok, err
end

local function inspect_current()
  if M.state.view ~= "activity" then
    vim.notify(
      "Oculus: select a change or issue to inspect",
      vim.log.levels.WARN
    )
    return
  end

  local queued_entry = not M.state.activity_inspect_queue_running
      and M.state.activity_inspect_queue[1]
    or nil
  local target = queued_entry and queued_entry.url or target_on_cursor()
  if type(target) ~= "string" then
    vim.notify(
      "Oculus: this activity does not have an inspectable target",
      vim.log.levels.WARN
    )
    return
  end

  local source_line = vim.api.nvim_win_get_cursor(M.state.win)[1]
  if queued_entry then
    source_line = nil
    for candidate, title_line in pairs(M.state.activity_title_lines) do
      if candidate == title_line
        and M.state.line_targets[candidate] == target
      then
        source_line = candidate
        break
      end
    end
  end
  local line = source_line
    and (M.state.activity_title_lines[source_line] or source_line)
    or nil
  local activity_buf = M.state.buf
  local activity_line = line and vim.api.nvim_buf_get_lines(
      activity_buf,
      line - 1,
      line,
      false
    )[1]
    or ""
  local function set_loading_line(text)
    if not line or not is_valid_buf(activity_buf) then
      return
    end
    local modifiable = vim.bo[activity_buf].modifiable
    vim.bo[activity_buf].modifiable = true
    vim.api.nvim_buf_set_lines(
      activity_buf,
      line - 1,
      line,
      false,
      { text }
    )
    vim.bo[activity_buf].modifiable = modifiable
  end
  local function clear_spinner()
    if source_line
      and is_valid_buf(activity_buf)
      and M.state.buf == activity_buf
      and M.state.view == "activity"
      and M.state.line_targets[source_line] == target
    then
      set_loading_line(activity_line)
      vim.api.nvim_buf_clear_namespace(
        activity_buf,
        inspect_loading_ns,
        0,
        -1
      )
    end
  end
  local lifecycle = {
      on_progress = function(frame)
        if not source_line
          or not is_valid_buf(activity_buf)
          or M.state.buf ~= activity_buf
          or M.state.view ~= "activity"
          or M.state.line_targets[source_line] ~= target
        then
          return
        end
        clear_spinner()
        local loading_line, spinner_column =
          activity_loading_line(activity_line, frame)
        set_loading_line(loading_line)
        vim.api.nvim_buf_add_highlight(
          activity_buf,
          inspect_loading_ns,
          "DiagnosticInfo",
          line - 1,
          spinner_column,
          spinner_column + #frame
        )
        vim.cmd("redraw")
      end,
      on_complete = function(message)
        clear_spinner()
        if message then
          vim.notify(
            "Oculus: " .. tostring(message),
            vim.log.levels.WARN
          )
        end
      end,
    }
  local ok, err
  if queued_entry then
    M.state.activity_inspect_queue_running = true
    open_next_queued_activity(lifecycle)
    ok = true
  else
    ok, err = inspect.open(
      target,
      M.state.opts,
      M.state.inspect_targets[source_line]
        or M.state.inspect_targets[line],
      lifecycle
    )
  end
  if not ok and err then
    clear_spinner()
    vim.notify("Oculus: " .. err, vim.log.levels.WARN)
  end
end

local function move_cursor(direction)
  if
    M.state.view ~= "contributors"
    and M.state.view ~= "filters"
    and M.state.view ~= "issue_filters"
    and M.state.view ~= "activity"
  then
    vim.cmd.normal({ direction > 0 and "j" or "k", bang = true })
    return
  end

  if M.state.view == "contributors" then
    local selectable = {}
    for line, candidate in pairs(M.state.line_targets) do
      if type(candidate) == "table" then
        selectable[#selectable + 1] = line
      end
    end
    table.sort(selectable)
    if #selectable > 0 then
      local current_line = vim.api.nvim_win_get_cursor(M.state.win)[1]
      local selected = selectable[direction > 0 and 1 or #selectable]
      for index, line in ipairs(selectable) do
        if line == current_line then
          selected = selectable[((index - 1 + direction)
            % #selectable) + 1]
          break
        elseif direction > 0 and line > current_line then
          selected = line
          break
        elseif direction < 0 and line < current_line then
          selected = line
        end
      end
      local candidate = M.state.line_targets[selected]
      if candidate.kind == "project" then
        M.state.selected_project = candidate.project
        M.state.selected_username = nil
      else
        M.state.selected_project = nil
        M.state.selected_username = candidate.username
      end
      render_contributors()
      return
    end
  end

  if M.state.view == "activity" then
    vim.cmd.normal({ direction > 0 and "j" or "k", bang = true })
    local line = vim.api.nvim_win_get_cursor(M.state.win)[1]
    local min_line = M.state.activity_cursor_min_line or 2
    if line < min_line then
      vim.api.nvim_win_set_cursor(M.state.win, { min_line, 0 })
    end
    update_activity_cursorline()
    return
  end

  local selectable = {}
  for line, target in pairs(M.state.line_targets) do
    local contributor_target = M.state.view ~= "activity"
      and type(target) == "table"
    local activity_target = M.state.view == "activity"
      and type(target) == "string"
    if contributor_target or activity_target then
      selectable[#selectable + 1] = line
    end
  end
  table.sort(selectable)
  if #selectable == 0 then
    return
  end

  local current = vim.api.nvim_win_get_cursor(M.state.win)[1]
  local selected = direction > 0 and selectable[1] or selectable[#selectable]
  for index, line in ipairs(selectable) do
    if line == current then
      local next_index = ((index - 1 + direction) % #selectable) + 1
      selected = selectable[next_index]
      break
    elseif direction > 0 and line > current then
      selected = line
      break
    elseif direction < 0 and line < current then
      selected = line
    end
  end
  vim.api.nvim_win_set_cursor(M.state.win, { selected, 0 })
  local target = M.state.line_targets[selected]
  if M.state.view == "contributors" and type(target) == "table" then
    if target.kind == "project" then
      M.state.selected_project = target.project
      M.state.selected_username = nil
    else
      M.state.selected_project = nil
      M.state.selected_username = target.username
    end
  end
  if M.state.view == "contributors" and type(target) == "table" then
    if target.kind == "project" then
      queue_project_preview(target.project)
    else
      queue_preview(target)
    end
  end
end

local function go_back()
  if M.state.view == "issue_filters" and M.state.activity_project then
    M.state.request_id = M.state.request_id + 1
    load_project_issues(M.state.activity_project, false, 1)
    return
  end
  if M.state.view == "activity" and M.state.activity_search_return then
    restore_activity_search()
    return
  end
  if M.state.view == "activity" and M.state.activity_issue_page then
    local return_state = M.state.project_issue_return
    M.state.project_issue_return = nil
    if not return_state then
      M.state.request_id = M.state.request_id + 1
      render_contributors()
      return
    end
    M.state.activity_page = return_state.page
    M.state.activity_loaded_pages = return_state.loaded_pages
    M.state.activity_source_events = return_state.source_events
    M.state.activity_has_past = return_state.has_past
    M.state.activity_issue_page = false
    render_activity(
      return_state.events,
      return_state.cached,
      return_state.notice,
      { issue_page = false }
    )
    if return_state.cursor and is_valid_win(M.state.win) then
      vim.api.nvim_win_set_cursor(M.state.win, return_state.cursor)
      update_activity_cursorline()
    end
    return
  end
  if M.state.view == "activity"
    and M.state.activity_commit_page
    and M.state.activity_return
  then
    local return_state = M.state.activity_return
    M.state.activity_return = nil
    M.state.activity_page = return_state.page
    M.state.activity_source_events = return_state.source_events
    render_activity(
      return_state.events,
      return_state.cached,
      return_state.notice
    )
    if return_state.cursor and is_valid_win(M.state.win) then
      vim.api.nvim_win_set_cursor(M.state.win, return_state.cursor)
      update_activity_cursorline()
    end
    return
  end
  if M.state.view == "shortcuts" and M.state.shortcut_return then
    local return_state = M.state.shortcut_return
    M.state.shortcut_return = nil
    if return_state.view == "activity"
      and (M.state.contributor or M.state.activity_project)
    then
      if M.state.activity_error then
        render_error(M.state.activity_error)
      elseif M.state.activity_loaded and M.state.events then
        render_activity(
          M.state.events,
          M.state.activity_cached,
          M.state.activity_notice,
          {
            commit_page = M.state.activity_commit_page,
            issue_page = M.state.activity_issue_page,
          }
        )
      elseif M.state.activity_project then
        load_project_activity(M.state.activity_project, false)
      else
        load_activity(M.state.contributor, false)
      end
    elseif return_state.view == "filters" and M.state.filter_scope then
      render_filters(M.state.filter_scope, return_state.selected_type)
    elseif return_state.view == "issue_filters"
      and M.state.activity_project
    then
      render_issue_filters(
        M.state.activity_project,
        return_state.selected_type
      )
    else
      render_contributors()
    end
    if return_state.cursor and is_valid_win(M.state.win) then
      local line_count = vim.api.nvim_buf_line_count(M.state.buf)
      vim.api.nvim_win_set_cursor(M.state.win, {
        math.min(return_state.cursor[1], line_count),
        return_state.cursor[2],
      })
    end
  elseif
    M.state.view == "activity"
    or M.state.view == "filters"
    or M.state.view == "issue_filters"
  then
    M.state.request_id = M.state.request_id + 1
    render_contributors()
  end
end

local function move_left()
  if M.state.view == "activity"
    and not M.state.activity_commit_page
    and (M.state.activity_page or 1) > 1
  then
    previous_activity_page()
    return
  end
  go_back()
end

local function move_right()
  if open_activity_expansion() then
    return
  end
  if M.state.view == "activity"
    and not M.state.activity_commit_page
  then
    if M.state.activity_search_return then
      next_activity_page()
      return
    end
    if M.state.activity_project then
      local page = M.state.activity_page or 1
      if page < (M.state.activity_loaded_pages or 1) then
        if M.state.activity_issue_page then
          load_project_issues(M.state.activity_project, false, page + 1)
        else
          load_project_activity(M.state.activity_project, false, page + 1)
        end
      end
      return
    end
    next_activity_page()
    return
  end
  select_current()
end

local function toggle_shortcuts()
  if M.state.view == "shortcuts" then
    go_back()
    return
  end

  local selected_type
  if M.state.view == "filters" then
    local target = target_on_cursor()
    selected_type = target and target.event_type or nil
  elseif M.state.view == "issue_filters" then
    local target = target_on_cursor()
    selected_type = target and target.dimension or nil
  end
  M.state.shortcut_return = {
    view = M.state.view,
    cursor = is_valid_win(M.state.win)
        and vim.api.nvim_win_get_cursor(M.state.win)
      or nil,
    selected_type = selected_type,
  }
  if M.state.view == "activity" then
    M.state.request_id = M.state.request_id + 1
  end
  render_shortcuts()
end

local function toggle_community_view()
  if M.state.view ~= "contributors"
    or M.state.search_query ~= nil
  then
    return
  end
  if M.state.community_view == "users" then
    M.state.community_view = "projects"
    M.state.selected_username = nil
  else
    M.state.community_view = "users"
    M.state.selected_project = nil
    M.state.contributor_offset = 1
  end
  render_contributors()
end

local function map_keys(buf)
  local map = function(lhs, rhs, desc)
    vim.keymap.set("n", lhs, rhs, {
      buffer = buf,
      nowait = true,
      silent = true,
      desc = desc,
    })
  end
  map("<C-c>", M.close, "Close Oculus")
  map("q", M.close, "Close Oculus")
  map("<Esc>", M.close, "Close Oculus")
  map("?", toggle_shortcuts, "Show Oculus keyboard shortcuts")
  map("t", toggle_community_view, "Switch Oculus project and user lists")
  map("s", open_search, "Search Oculus projects, users, or activity")
  map("/", open_search, "Search Oculus projects, users, or activity")
  map("<CR>", select_current, "Select Oculus item")
  map("l", move_right, "Move right in Oculus")
  map("<Right>", move_right, "Move right in Oculus")
  map("<Space>", function()
    if M.state.view == "issue_filters" then
      select_project_issue_filter()
    else
      toggle_filter_type()
    end
  end, "Toggle Oculus item")
  map("o", open_current, "Open Oculus contributor profile")
  map("b", open_activity_in_browser, "Open Oculus activity in browser")
  map("F", function()
    open_filters(true)
  end, "Edit global activity types")
  map("a", function()
    if M.state.view == "contributors" then
      prompt_add_account()
    else
      set_all_filter_types(true)
    end
  end, "Add an Oculus project or user, or enable all filters")
  map("n", function()
    set_all_filter_types(false)
  end, "Disable all Oculus activity filters")
  map("p", next_activity_page, "Load past Oculus activity")
  map("f", function()
    if M.state.view == "activity" and M.state.activity_issue_page then
      render_issue_filters(M.state.activity_project)
    elseif M.state.view == "activity" then
      previous_activity_page()
    else
      open_filters(false)
    end
  end, "Move forward or edit Oculus activity categories")
  map("r", function()
    if M.state.view == "contributors" then
      remove_current_item()
    else
      refresh_activity()
    end
  end, "Remove selected Oculus item or refresh activity")
  map("d", reset_filter_types_to_default, "Reset Oculus activity types")
  map("h", inspect_current, "Inspect Oculus change or issue")
  map("<Tab>", toggle_activity_inspect_queue, "Queue Oculus activity inspection")
  map("u", open_project_issue_activity, "Open Oculus project issues")
  map("k", function()
    move_cursor(1)
  end, "Move down in Oculus")
  map("i", function()
    move_cursor(-1)
  end, "Move up in Oculus")
  map("j", move_left, "Move left in Oculus")
  map("<Left>", move_left, "Move left in Oculus")
  map("<Down>", function()
    move_cursor(1)
  end, "Select next Oculus contributor")
  map("<Up>", function()
    move_cursor(-1)
  end, "Select previous Oculus contributor")
  map("<ScrollWheelDown>", function()
    move_cursor(1)
  end, "Scroll Oculus contributors down")
  map("<ScrollWheelUp>", function()
    move_cursor(-1)
  end, "Scroll Oculus contributors up")
end

function M.close()
  local origin_tab = M.state.origin_tab
  local origin_win = M.state.origin_win
  local origin_view = vim.deepcopy(M.state.origin_view)
  M.state.request_id = M.state.request_id + 1
  stop_activity_page_loading()
  vim.api.nvim_clear_autocmds({ group = autocmd_group })
  if is_valid_buf(M.state.buf) then
    vim.api.nvim_buf_clear_namespace(
      M.state.buf,
      inspect_loading_ns,
      0,
      -1
    )
  end
  close_activity_footer()
  clear_search_window()
  clear_search_state()
  if is_valid_win(M.state.win) then
    M.state.restore_cursor = vim.api.nvim_win_get_cursor(M.state.win)
    M.state.restore_view = vim.api.nvim_win_call(M.state.win, function()
      return vim.fn.winsaveview()
    end)
    if vim.api.nvim_get_current_win() ~= M.state.win then
      vim.api.nvim_set_current_win(M.state.win)
    end
    vim.api.nvim_win_close(M.state.win, true)
  end
  M.state.buf = nil
  M.state.win = nil
  M.state.line_targets = {}
  M.state.inspect_targets = {}
  M.state.activity_title_lines = {}
  M.state.activity_expansion_targets = {}
  M.state.preview_key = nil
  M.state.preview_items = nil
  M.state.preview_contributor = nil
  M.state.preview_project = nil
  M.state.selected_project = nil
  M.state.contributors = {}
  M.state.filter_scope = nil
  M.state.shortcut_return = nil
  M.state.opening_account_prompt = false
  if origin_tab and vim.api.nvim_tabpage_is_valid(origin_tab) then
    vim.api.nvim_set_current_tabpage(origin_tab)
    if is_valid_win(origin_win)
      and vim.api.nvim_win_get_tabpage(origin_win) == origin_tab
    then
      vim.api.nvim_set_current_win(origin_win)
      if origin_view then
        vim.api.nvim_win_call(origin_win, function()
          vim.fn.winrestview(origin_view)
        end)
      end
    end
  end
end

function M.inspection_window_options()
  if not is_valid_win(M.state.win) then
    return nil
  end
  local origin = M.state.origin_win
  if is_valid_win(origin) then
    return {
      number = vim.wo[origin].number,
      relativenumber = vim.wo[origin].relativenumber,
      winhighlight = vim.wo[origin].winhighlight,
    }
  end
  return vim.deepcopy(M.state.origin_window_options)
end

function M.open(opts)
  M.state.opts = opts or {}
  if is_valid_win(M.state.win) then
    vim.api.nvim_set_current_win(
      is_valid_win(M.state.search_win) and M.state.search_win or M.state.win
    )
    update_activity_cursorline()
    return
  end

  local origin_win = vim.api.nvim_get_current_win()
  M.state.origin_tab = vim.api.nvim_get_current_tabpage()
  M.state.origin_win = origin_win
  M.state.highlight_source_win = origin_win
  M.refresh_window_highlights(origin_win)
  M.state.origin_view = vim.api.nvim_win_call(origin_win, function()
    return vim.fn.winsaveview()
  end)
  M.state.origin_window_options = {
    number = vim.wo[origin_win].number,
    relativenumber = vim.wo[origin_win].relativenumber,
    winhighlight = vim.wo[origin_win].winhighlight,
  }
  local buf = make_buf()
  local win = vim.api.nvim_open_win(buf, true, M.window_config(M.state.opts))
  M.state.buf = buf
  M.state.win = win
  M.state.contributors = display_contributors(M.state.opts.contributors)

  vim.wo[win].wrap = false
  vim.wo[win].cursorline = true
  vim.wo[win].cursorlineopt = "line"
  vim.api.nvim_set_hl(0, "OculusActivityIcon", {
    fg = "#fbd38d",
    bg = "NONE",
  })
  vim.api.nvim_set_hl(0, "OculusActivityPreview", {
    fg = "#9ae6b4",
    bg = "NONE",
  })
  vim.api.nvim_set_hl(0, "OculusContributorSelected", {
    fg = "#ffffff",
  })
  vim.wo[win].winhighlight = table.concat({
    "Normal:OculusNormal",
    "NormalFloat:OculusNormal",
    "FloatBorder:OculusBorder",
    "FloatTitle:OculusBorder",
  }, ",")
  use_window_highlights(win)
  vim.wo[win].number = false
  vim.wo[win].relativenumber = false
  vim.wo[win].signcolumn = "no"
  vim.wo[win].winfixbuf = true

  map_keys(buf)
  if M.state.view == "issue_filters" and M.state.activity_project then
    render_issue_filters(M.state.activity_project)
    restore_cursor()
  elseif
    M.state.view == "activity"
    and (M.state.contributor or M.state.activity_project)
    and M.state.events
    and M.state.activity_loaded
  then
    local contributor = M.state.contributor
      and (contributor_by_username(M.state.contributor.username)
        or M.state.contributor)
      or nil
    M.state.contributor = contributor
    if M.state.activity_project then
      M.state.community_view = "projects"
      M.state.selected_project = M.state.activity_project
      M.state.selected_username = nil
    else
      M.state.community_view = "users"
      M.state.selected_username = contributor.username
    end
    render_activity(
      M.state.events,
      M.state.activity_cached,
      M.state.activity_notice,
      {
        commit_page = M.state.activity_commit_page,
        issue_page = M.state.activity_issue_page,
      }
    )
    restore_cursor()
  else
    M.state.community_view = "projects"
    render_contributors()
    restore_cursor()
  end

  vim.api.nvim_clear_autocmds({ group = autocmd_group })
  vim.api.nvim_create_autocmd("VimResized", {
    group = autocmd_group,
    buffer = buf,
    callback = function()
      if is_valid_win(M.state.win) then
        vim.api.nvim_win_set_config(M.state.win, make_win_config(M.state.opts))
        if M.state.view == "contributors" then
          render_contributors()
          if is_valid_win(M.state.search_win) then
            local config = search_win_config()
            if config then
              vim.api.nvim_win_set_config(M.state.search_win, config)
            end
          end
        elseif M.state.view == "activity" then
          render_activity_footer()
          update_activity_cursorline()
        end
      end
    end,
  })

  vim.api.nvim_create_autocmd("CursorMoved", {
    group = autocmd_group,
    buffer = buf,
    callback = function()
      if not is_valid_win(M.state.win) then
        return
      end
      clamp_list_cursor()
      if M.state.view == "activity" then
        update_activity_cursorline()
        return
      end
      if
        M.state.view ~= "contributors"
      then
        return
      end
      local line = vim.api.nvim_win_get_cursor(M.state.win)[1]
      local target = M.state.line_targets[line]
      if type(target) == "table" then
        if target.kind == "project" then
          M.state.selected_project = target.project
          M.state.selected_username = nil
          queue_project_preview(target.project)
        else
          M.state.selected_project = nil
          M.state.selected_username = target.username
          queue_preview(target)
        end
      end
      update_contributor_selection()
    end,
  })

  vim.api.nvim_create_autocmd("WinScrolled", {
    group = autocmd_group,
    callback = function(args)
      if
        M.state.view == "activity"
        and tonumber(args.match) == M.state.win
      then
        update_activity_cursorline()
      end
    end,
  })

  vim.api.nvim_create_autocmd("WinEnter", {
    group = autocmd_group,
    callback = function()
      local entered = vim.api.nvim_get_current_win()
      if not is_valid_win(M.state.win) then
        return
      end
      if entered == M.state.win then
        update_activity_cursorline()
        return
      end
      if M.state.opening_search or M.state.opening_account_prompt then
        return
      end
      if entered == M.state.search_win then
        return
      end
      if vim.api.nvim_win_get_config(entered).relative ~= "" then
        vim.schedule(function()
          if is_valid_win(M.state.win) then
            M.close()
          end
        end)
      end
    end,
  })
end

function M.toggle(opts)
  if is_valid_win(M.state.win) then
    M.close()
  else
    M.open(opts)
  end
end

return M
