local M = {}

local actions = require("pantheon.actions")
local browser = require("pantheon.browser")
local github = require("pantheon.github")

local ns = vim.api.nvim_create_namespace("pantheon")
local preview_ns = vim.api.nvim_create_namespace("pantheon_preview")
local contributor_selection_ns = vim.api.nvim_create_namespace(
  "pantheon_contributor_selection"
)
local autocmd_group = vim.api.nvim_create_augroup(
  "PantheonWindow",
  { clear = true }
)

M.state = {
  buf = nil,
  win = nil,
  footer_buf = nil,
  footer_win = nil,
  view = "contributors",
  contributor = nil,
  events = nil,
  line_targets = {},
  request_id = 0,
  preview_key = nil,
  preview_items = nil,
  contributors = {},
  selected_username = nil,
  contributor_offset = 1,
  filter_scope = nil,
  activity_cached = nil,
  activity_notice = nil,
  activity_error = nil,
  activity_loaded = false,
  activity_cursor_min_line = 1,
  activity_scroll_limit_line = nil,
  restore_cursor = nil,
  shortcut_return = nil,
  opts = {},
}

local function is_valid_win(win)
  return win and vim.api.nvim_win_is_valid(win)
end

local function is_valid_buf(buf)
  return buf and vim.api.nvim_buf_is_valid(buf)
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
    title = opts.title or " Pantheon ",
    title_pos = "center",
  }
end

local function make_buf()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = "pantheon"
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
  vim.bo[buf].filetype = "pantheon"
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
  local lines = {
    "  " .. string.rep("─", math.max(1, width - 4)),
    "  ? shortcuts   j/← back   q close",
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
    "Normal:PantheonNormal",
    "NormalFloat:PantheonNormal",
  }, ",")
  vim.wo[M.state.footer_win].number = false
  vim.wo[M.state.footer_win].relativenumber = false
  vim.wo[M.state.footer_win].signcolumn = "no"
end

local function update_activity_cursorline()
  if M.state.view ~= "activity" or not is_valid_win(M.state.win) then
    return
  end
  if vim.api.nvim_get_current_win() ~= M.state.win then
    return
  end
  local footer_height = is_valid_win(M.state.footer_win) and 2 or 0
  local visible_rows = math.max(
    1,
    vim.api.nvim_win_get_height(M.state.win) - footer_height
  )
  local limit_line = M.state.activity_scroll_limit_line
  if limit_line then
    local cursor = vim.api.nvim_win_get_cursor(M.state.win)
    if cursor[1] > limit_line then
      vim.api.nvim_win_set_cursor(M.state.win, { limit_line, cursor[2] })
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
  return vim.list_extend({}, contributors or {})
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

local function activity_time(timestamp)
  if not timestamp then
    return "unknown time"
  end
  local year, month, day, hour, minute, second = timestamp:match(
    "^(%d%d%d%d)%-(%d%d)%-(%d%d)T(%d%d):(%d%d):(%d%d)Z$"
  )
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
  local event_date = os.date("*t", local_time)
  local time = os.date("%I:%M %p", local_time):gsub("^0", " ")

  local date = ("%02d/%02d/%02d"):format(
    event_date.month,
    event_date.day,
    event_date.year % 100
  )
  return date .. " — " .. time
end

local function footer(lines, text)
  -- lines[#lines + 1] = ""
  lines[#lines + 1] = "  " .. text
end

local function preview_left_width(window_width)
  local preferred = math.max(40, math.floor(window_width * 0.46))
  return math.max(30, math.min(preferred, window_width - 22))
end

local function event_detail(item)
  if item.detail then
    if type(item.detail) == "table" then
      return item.detail
    end
    local detail = item.detail
    local has_wrapped_preview = detail:match('^".*"$')
      or detail:match('^PR #%d+ · ".*"$')
    if not has_wrapped_preview then
      detail = '"' .. detail .. '"'
    end
    return detail
  end
end

local function quoted_detail_line(text)
  if text == "…" then
    return text
  end
  local has_wrapped_preview = text:match('^".*"$')
    or text:match('^PR #%d+ · ".*"$')
  if has_wrapped_preview then
    return text
  end
  return '"' .. text .. '"'
end

local function event_summary(item)
  if item.summary then
    local summary = item.summary
    local has_wrapped_preview = summary:match('^".*"$')
      or summary:match('^PR #%d+ · ".*"$')
    if not has_wrapped_preview then
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

local function preview_lines(item, width)
  local detail = event_detail(item)
  if not detail then
    return nil
  end
  local indent = "     "
  local content_width = math.max(1, width - vim.fn.strdisplaywidth(indent) - 1)
  local lines = {}
  local details = type(detail) == "table" and detail or { detail }
  for _, detail_item in ipairs(details) do
    local remaining = quoted_detail_line(detail_item)
    for _ = 1, 3 do
      if remaining == "" then
        break
      end
      local text = trim_to_width(remaining, content_width)
      lines[#lines + 1] = indent .. pad_cell(text, content_width) .. " "
      if vim.fn.strdisplaywidth(remaining) <= content_width then
        break
      end
      local suffix_width = text:sub(-4) == '…"' and 2 or 1
      local consumed = math.max(1, vim.fn.strchars(text) - suffix_width)
      remaining = vim.fn.strcharpart(remaining, consumed)
    end
  end
  return lines
end

local function without_detail(item)
  local result = vim.tbl_extend("force", {}, item)
  result.detail = nil
  return result
end

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

local function preview_items(contributor)
  return {
    [2] = { "PREVIEW", "Title" },
    [4] = { contributor.name or contributor.username, "Function" },
    [5] = { "@" .. contributor.username, "Identifier" },
    [7] = { contributor.description or "GitHub contributor", "Comment" },
    [9] = { "", "Special" },
    [10] = {
      "",
      "Comment",
    },
  }
end

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
  if not contributor or M.state.view ~= "contributors" then
    return
  end

  local key = contributor.username
  if M.state.preview_key == key then
    return
  end
  M.state.preview_key = key
  render_preview_panel(preview_items(contributor))
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
  if M.state.view ~= "contributors" or not is_valid_win(M.state.win) then
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
        hl_group = "PantheonContributorSelected",
        hl_mode = "replace",
        priority = 10000,
      }
    )
  end
end

local function render_contributors()
  close_activity_footer()
  M.state.view = "contributors"
  M.state.contributor = nil
  M.state.events = nil
  M.state.line_targets = {}
  M.state.preview_key = nil

  local lines = {
    "",
    "  COMMUNITY FIGURES",
    "  Public GitHub activity",
    "",
  }

  local contributors = M.state.contributors
  local left_width = preview_left_width(vim.api.nvim_win_get_width(M.state.win))
  local name_width = 4
  local username_width = 6
  for _, contributor in ipairs(contributors) do
    local contributor_name = contributor.name or contributor.username
    name_width = math.max(name_width, #contributor_name)
    username_width = math.max(username_width, #(contributor.username) + 1)
  end
  username_width = math.min(username_width, 14)
  local available_name_width = left_width - username_width - 5
  name_width = math.min(name_width, math.max(10, available_name_width))

  lines[#lines + 1] = ("  %s  %s"):format(
    pad_cell("USER", name_width),
    pad_cell("GITHUB", username_width)
  )

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

  for index = offset, math.min(#contributors, offset + list_limit - 1) do
    local contributor = contributors[index]
    local line = #lines + 1
    local handle = "@" .. contributor.username
    local prefix = ("  %s  %s"):format(
      pad_cell(contributor.name or contributor.username, name_width),
      pad_cell(handle, username_width)
    )
    lines[line] = pad_cell(prefix, left_width)
    M.state.line_targets[line] = contributor
  end

  if #contributors == 0 then
    lines[#lines + 1] = "  No contributors configured."
  end
  lines[#lines + 1] = "  " .. string.rep("─", math.max(1, left_width - 2))
  local separator_line = #lines
  lines[#lines + 1] = "  ?: shortcuts  q: quit"
  local commands_line = #lines
  while #lines < math.min(vim.api.nvim_win_get_height(M.state.win), 25) do
    lines[#lines + 1] = ""
  end
  set_lines(lines)
  vim.wo[M.state.win].cursorline = false

  highlight(2, 2, -1, "Title")
  highlight(3, 2, -1, "Comment")
  highlight(5, 2, -1, "Comment")
  for line, _ in pairs(M.state.line_targets) do
    local username_start = lines[line]:find("@", 1, true)
    highlight(
      line,
      2,
      username_start and (username_start - 2) or -1,
      "Function"
    )
    if username_start then
      highlight(
        line,
        username_start - 1,
        username_start + username_width,
        "Identifier"
      )
    end
  end
  highlight(separator_line, 2, -1, "WinSeparator")
  highlight(commands_line, 2, -1, "Comment")

  local selected_line
  for line, contributor in pairs(M.state.line_targets) do
    if contributor.username == M.state.selected_username then
      selected_line = line
      break
    end
  end
  selected_line = selected_line or (M.state.line_targets[6] and 6)
  if selected_line and is_valid_win(M.state.win) then
    local contributor = M.state.line_targets[selected_line]
    M.state.selected_username = contributor.username
    vim.api.nvim_win_set_cursor(M.state.win, { selected_line, 0 })
    queue_preview(contributor)
    update_contributor_selection()
  end
end

local function filter_type_set(scope)
  local types
  if scope.global then
    types = M.state.opts.activity_types
  else
    types = activity_types_for(scope)
  end

  local enabled = {}
  if types == nil then
    for _, event_type in ipairs(actions.event_types) do
      enabled[event_type] = true
    end
  else
    for _, event_type in ipairs(types) do
      enabled[event_type] = true
    end
  end
  return enabled
end

local function persist_filter_config()
  if M.state.opts.persist_filters then
    local ok, err = require("pantheon.storage").save(
      M.state.opts.state_file,
      M.state.opts
    )
    if not ok then
      vim.notify(
        "Pantheon could not save activity filters: " .. tostring(err),
        vim.log.levels.ERROR
      )
    end
  end
end

local function save_filter_type_set(scope, enabled)
  local types = {}
  for _, event_type in ipairs(actions.event_types) do
    if enabled[event_type] then
      types[#types + 1] = event_type
    end
  end

  if scope.global then
    M.state.opts.activity_types = types
  else
    M.state.opts.user_activity_types = M.state.opts.user_activity_types or {}
    M.state.opts.user_activity_types[scope.username] = types
  end

  persist_filter_config()
end

local function render_filters(scope, selected_type)
  close_activity_footer()
  M.state.view = "filters"
  M.state.filter_scope = scope
  M.state.line_targets = {}

  local scope_name = scope.global and "All contributors"
    or ((scope.name or scope.username) .. " · @" .. scope.username)
  local enabled = filter_type_set(scope)
  local lines = {
    "",
    "  ACTIVITY TYPES",
    "  " .. scope_name,
    "  Checked event kinds are shown in previews and activity feeds.",
    "",
  }

  local selected_line
  for _, event_type in ipairs(actions.event_types) do
    local line = #lines + 1
    local checkbox = enabled[event_type] and "[x]" or "[ ]"
    lines[line] = ("  %s  %-28s %s"):format(
      checkbox,
      actions.type_label(event_type),
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
  for _, event_type in ipairs(actions.event_types) do
    enabled[event_type] = value
  end
  save_filter_type_set(M.state.filter_scope, enabled)
  render_filters(M.state.filter_scope, target and target.event_type or nil)
end

local function reset_filter_types_to_default()
  if M.state.view ~= "contributors" then
    return
  end
  M.state.opts.activity_types = nil
  M.state.opts.user_activity_types = {}
  persist_filter_config()
  render_contributors()
end

local function render_loading(contributor)
  close_activity_footer()
  M.state.view = "activity"
  M.state.activity_loaded = false
  M.state.activity_error = nil
  local lines = {
    "",
    "  " .. (contributor.name or contributor.username),
    "  @" .. contributor.username,
    "",
    "  Loading recent GitHub activity…",
  }
  footer(lines, "? shortcuts   j/← back   q close")
  set_lines(lines)
  vim.wo[M.state.win].cursorline = true
  highlight(2, 2, -1, "Function")
  highlight(3, 2, -1, "Comment")
  highlight(5, 2, -1, "DiagnosticInfo")
end

local function render_error(message)
  close_activity_footer()
  M.state.view = "activity"
  M.state.activity_loaded = false
  M.state.activity_error = message
  local contributor = M.state.contributor
  local lines = {
    "",
    "  " .. (contributor.name or contributor.username),
    "  @" .. contributor.username,
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

local function render_activity(events, cached, notice)
  M.state.view = "activity"
  local contributor = M.state.contributor
  M.state.events = events
  M.state.activity_cached = cached
  M.state.activity_notice = notice
  M.state.activity_loaded = true
  M.state.activity_error = nil
  M.state.line_targets = {}
  M.state.activity_scroll_limit_line = nil
  local width = vim.api.nvim_win_get_width(M.state.win)
  local lines = {
    "",
    "  " .. (contributor.name or contributor.username),
    ("  %s%s"):format(
      "@" .. contributor.username,
      cached and " · cached" or ""
    ),
  }
  if notice then
    lines[#lines + 1] = "  " .. notice
  end
  lines[#lines + 1] = ""

  local first_event_line
  local scroll_limit_line
  local activity_line_kinds = {}
  for _, event in ipairs(events) do
    local item = actions.describe(event)
    local event_line = #lines + 1
    first_event_line = first_event_line or event_line
    activity_line_kinds[event_line] = "main"
    local item_width = width - 2
    if item.detail then
      lines[event_line] = activity_item_line(
        without_detail(item),
        activity_time(event.created_at),
        item_width
      )
      local detail_lines = preview_lines(item, item_width)
      if detail_lines then
        for _, detail_line in ipairs(detail_lines) do
          lines[#lines + 1] = detail_line
          M.state.line_targets[#lines] = vim.trim(detail_line) == "…"
              and (item.group_url or item.url)
            or item.url
          activity_line_kinds[#lines] = "preview"
        end
      end
      lines[#lines + 1] = pad_cell("", item_width)
      scroll_limit_line = #lines
    else
      lines[event_line] = activity_item_line(
        item,
        activity_time(event.created_at),
        item_width
      )
      lines[#lines + 1] = pad_cell("", item_width)
      M.state.line_targets[#lines] = item.url
      scroll_limit_line = #lines
    end
    M.state.line_targets[event_line] = item.url
  end

  if #events == 0 then
    lines[#lines + 1] = "  No recent public activity was returned."
    lines[#lines + 1] = ""
    scroll_limit_line = #lines
  end
  M.state.activity_scroll_limit_line = scroll_limit_line
  lines[#lines + 1] = ""
  lines[#lines + 1] = ""
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
        highlight(line, 0, -1, "PantheonActivityPreview")
      elseif kind == "main" then
        highlight(line, 0, 5, "PantheonActivityIcon")
      end
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

local function render_shortcuts()
  close_activity_footer()
  M.state.view = "shortcuts"
  M.state.line_targets = {}

  local lines = {
    "",
    "  KEYBOARD SHORTCUTS",
    "  Commands available throughout Pantheon",
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
    { "i / <Up>", "Select the previous item" },
    { "k / <Down>", "Select the next item" },
    { "l / <Right> / <CR>", "Select or open the current item" },
    { "j / <Left>", "Return to the previous page" },
  })
  section("STARTUP USER LIST", {
    { "f", "Edit filters for the selected contributor" },
    { "F", "Edit global activity filters" },
    { "d", "Reset activity filters to defaults" },
    { "o", "Open the selected GitHub profile" },
  })
  section("ACTIVITY", {
    { "o", "Open the selected activity on GitHub" },
    { "r", "Refresh activity without using the cache" },
  })
  section("FILTER CHECKLIST", {
    { "<Space> / l / <CR>", "Toggle the selected activity type" },
    { "a", "Enable every activity type" },
    { "n", "Disable every activity type" },
  })
  section("GENERAL", {
    { "?", "Open or close this shortcut page" },
    { "q / <Esc> / <C-c>", "Close Pantheon" },
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
  if not cursor or not is_valid_win(M.state.win) then
    return
  end

  local line_count = vim.api.nvim_buf_line_count(M.state.buf)
  local line = math.min(math.max(cursor[1] or 1, 1), line_count)
  local column = math.max(cursor[2] or 0, 0)
  vim.api.nvim_win_set_cursor(M.state.win, { line, column })
  M.state.restore_cursor = nil
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

local function load_activity(contributor, force)
  M.state.view = "activity"
  M.state.contributor = contributor
  M.state.request_id = M.state.request_id + 1
  local request_id = M.state.request_id
  render_loading(contributor)

  local request_opts = vim.tbl_extend(
    "force",
    M.state.opts,
    { force = force or false }
  )
  local callback = function(events, err, cached, notice)
    if request_id ~= M.state.request_id or not is_valid_win(M.state.win) then
      return
    end
    if err then
      render_error(err)
    else
      local filtered = actions.filter(events, activity_types_for(contributor))
      local results = vim.list_slice(
        filtered,
        1,
        M.state.opts.results_limit or 8
      )
      render_activity(results, cached, notice)
      github.enrich_pull_requests(results, request_opts, function(with_prs)
        if request_id ~= M.state.request_id or M.state.view ~= "activity" then
          return
        end
        render_activity(with_prs, cached, notice)
        github.enrich_pushes(with_prs, request_opts, function(enriched)
          if request_id ~= M.state.request_id or M.state.view ~= "activity" then
            return
          end
          render_activity(enriched, cached, notice)
        end)
      end)
    end
  end

  github.events(contributor.username, request_opts, callback)
end

local function target_on_cursor()
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
    vim.notify("Pantheon: " .. tostring(err), vim.log.levels.ERROR)
  end
end

local function select_current()
  local target = target_on_cursor()
  if M.state.view == "contributors" and type(target) == "table" then
    M.state.selected_username = target.username
    load_activity(target, false)
  elseif M.state.view == "activity" and type(target) == "string" then
    open_url(target)
  elseif M.state.view == "filters" then
    toggle_filter_type()
  end
end

local function open_filters(global)
  if global then
    render_filters({ global = true })
    return
  end

  local contributor
  if M.state.view == "contributors" then
    contributor = target_on_cursor()
  elseif M.state.view == "activity" then
    contributor = M.state.contributor
  end
  if type(contributor) == "table" and contributor.username then
    render_filters(contributor)
  end
end

local function open_current()
  local target = target_on_cursor()
  if M.state.view == "contributors" and type(target) == "table" then
    open_url("https://github.com/" .. target.username)
  elseif M.state.view == "activity" then
    if type(target) == "string" then
      open_url(target)
    elseif M.state.contributor then
      open_url("https://github.com/" .. M.state.contributor.username)
    end
  end
end

local function move_cursor(direction)
  if
    M.state.view ~= "contributors"
    and M.state.view ~= "filters"
    and M.state.view ~= "activity"
  then
    vim.cmd.normal({ direction > 0 and "j" or "k", bang = true })
    return
  end

  if M.state.view == "contributors" and #M.state.contributors > 0 then
    local target = target_on_cursor()
    local username = type(target) == "table" and target.username
      or M.state.selected_username
    local current_index = 1
    for index, contributor in ipairs(M.state.contributors) do
      if contributor.username == username then
        current_index = index
        break
      end
    end
    local next_index = ((current_index - 1 + direction) %
      #M.state.contributors) + 1
    M.state.selected_username = M.state.contributors[next_index].username
    render_contributors()
    return
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
    M.state.selected_username = target.username
  end
  queue_preview(target)
end

local function go_back()
  if M.state.view == "shortcuts" and M.state.shortcut_return then
    local return_state = M.state.shortcut_return
    M.state.shortcut_return = nil
    if return_state.view == "activity" and M.state.contributor then
      if M.state.activity_error then
        render_error(M.state.activity_error)
      elseif M.state.activity_loaded and M.state.events then
        render_activity(
          M.state.events,
          M.state.activity_cached,
          M.state.activity_notice
        )
      else
        load_activity(M.state.contributor, false)
      end
    elseif return_state.view == "filters" and M.state.filter_scope then
      render_filters(M.state.filter_scope, return_state.selected_type)
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
  elseif M.state.view == "activity" or M.state.view == "filters" then
    M.state.request_id = M.state.request_id + 1
    render_contributors()
  end
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

local function map_keys(buf)
  local map = function(lhs, rhs, desc)
    vim.keymap.set("n", lhs, rhs, {
      buffer = buf,
      nowait = true,
      silent = true,
      desc = desc,
    })
  end
  map("<C-c>", M.close, "Close Pantheon")
  map("q", M.close, "Close Pantheon")
  map("<Esc>", M.close, "Close Pantheon")
  map("?", toggle_shortcuts, "Show Pantheon keyboard shortcuts")
  map("<CR>", select_current, "Select Pantheon item")
  map("l", select_current, "Move right in Pantheon")
  map("<Right>", select_current, "Move right in Pantheon")
  map("<Space>", toggle_filter_type, "Toggle Pantheon activity type")
  map("o", open_current, "Open Pantheon item in browser")
  map("f", function()
    open_filters(false)
  end, "Edit contributor activity types")
  map("F", function()
    open_filters(true)
  end, "Edit global activity types")
  map("a", function()
    set_all_filter_types(true)
  end, "Enable all Pantheon activity types")
  map("n", function()
    set_all_filter_types(false)
  end, "Disable all Pantheon activity types")
  map("d", reset_filter_types_to_default, "Reset Pantheon activity types")
  map("i", function()
    move_cursor(-1)
  end, "Move up in Pantheon")
  map("k", function()
    move_cursor(1)
  end, "Move down in Pantheon")
  map("j", go_back, "Move left in Pantheon")
  map("<Left>", go_back, "Move left in Pantheon")
  map("<Down>", function()
    move_cursor(1)
  end, "Select next Pantheon contributor")
  map("<Up>", function()
    move_cursor(-1)
  end, "Select previous Pantheon contributor")
  map("<ScrollWheelDown>", function()
    move_cursor(1)
  end, "Scroll Pantheon contributors down")
  map("<ScrollWheelUp>", function()
    move_cursor(-1)
  end, "Scroll Pantheon contributors up")
  map("r", function()
    if M.state.view == "activity" and M.state.contributor then
      github.clear(M.state.contributor.username)
      load_activity(M.state.contributor, true)
    end
  end, "Refresh Pantheon activity")
end

function M.close()
  M.state.request_id = M.state.request_id + 1
  vim.api.nvim_clear_autocmds({ group = autocmd_group })
  close_activity_footer()
  if is_valid_win(M.state.win) then
    M.state.restore_cursor = vim.api.nvim_win_get_cursor(M.state.win)
    vim.api.nvim_win_close(M.state.win, true)
  end
  M.state.buf = nil
  M.state.win = nil
  M.state.line_targets = {}
  M.state.preview_key = nil
  M.state.preview_items = nil
  M.state.contributors = {}
  M.state.filter_scope = nil
  M.state.shortcut_return = nil
end

function M.open(opts)
  M.state.opts = opts or {}
  if is_valid_win(M.state.win) then
    vim.api.nvim_set_current_win(M.state.win)
    update_activity_cursorline()
    return
  end

  local buf = make_buf()
  local win = vim.api.nvim_open_win(buf, true, make_win_config(M.state.opts))
  M.state.buf = buf
  M.state.win = win
  M.state.contributors = display_contributors(M.state.opts.contributors)

  vim.wo[win].wrap = false
  vim.wo[win].cursorline = true
  vim.wo[win].cursorlineopt = "line"
  vim.api.nvim_set_hl(0, "PantheonNormal", { bg = "NONE" })
  vim.api.nvim_set_hl(0, "PantheonBorder", { fg = "#ffffff", bg = "NONE" })
  vim.api.nvim_set_hl(0, "PantheonActivityIcon", {
    fg = "#fbd38d",
    bg = "NONE",
  })
  vim.api.nvim_set_hl(0, "PantheonActivityPreview", {
    fg = "#9ae6b4",
    bg = "NONE",
  })
  vim.api.nvim_set_hl(0, "PantheonContributorSelected", {
    fg = "#ffffff",
  })
  vim.api.nvim_set_hl(0, "PantheonCursorLine", {
    bg = "#3a3a3a",
  })
  vim.wo[win].winhighlight = table.concat({
    "Normal:PantheonNormal",
    "NormalFloat:PantheonNormal",
    "CursorLine:PantheonCursorLine",
    "FloatBorder:PantheonBorder",
    "FloatTitle:PantheonBorder",
  }, ",")
  vim.wo[win].number = false
  vim.wo[win].relativenumber = false
  vim.wo[win].signcolumn = "no"
  vim.wo[win].winfixbuf = true

  map_keys(buf)
  if
    M.state.view == "activity"
    and M.state.contributor
    and M.state.events
    and M.state.activity_loaded
  then
    local contributor = contributor_by_username(M.state.contributor.username)
      or M.state.contributor
    M.state.contributor = contributor
    M.state.selected_username = contributor.username
    render_activity(
      M.state.events,
      M.state.activity_cached,
      M.state.activity_notice
    )
    restore_cursor()
  else
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
        if M.state.view == "contributors" and M.state.preview_items then
          render_preview_panel(M.state.preview_items)
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
      if M.state.view == "activity" then
        update_activity_cursorline()
        return
      end
      if M.state.view ~= "contributors" then
        return
      end
      local line = vim.api.nvim_win_get_cursor(M.state.win)[1]
      local contributor = M.state.line_targets[line]
      if type(contributor) == "table" then
        M.state.selected_username = contributor.username
        queue_preview(contributor)
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
