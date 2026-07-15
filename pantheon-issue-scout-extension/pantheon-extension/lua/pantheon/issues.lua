local M = {}

local browser = require("pantheon.browser")
local skill = require("pantheon.issue_skill")

local ns = vim.api.nvim_create_namespace("pantheon_issues")
local autocmd_group = vim.api.nvim_create_augroup(
  "PantheonIssuesWindow",
  { clear = true }
)

M.state = {
  buf = nil,
  win = nil,
  opts = {},
  items = nil,
  line_targets = {},
  selected = nil,
  view = "list",
  preferences = "",
  request_id = 0,
  process = nil,
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

local function window_config(opts)
  local width = dimension(opts.issue_width or opts.width, vim.o.columns, 0.90, 60)
  local height = dimension(opts.issue_height or opts.height, vim.o.lines, 0.82, 18)
  local row = math.max(0, math.min(opts.issue_row or opts.row or 1, vim.o.lines - height - 2))
  return {
    relative = "editor",
    width = width,
    height = height,
    row = row,
    col = math.floor((vim.o.columns - width) / 2),
    style = "minimal",
    border = opts.border or "rounded",
    title = opts.issue_title or " Pantheon Issues ",
    title_pos = "center",
  }
end

local function make_buf()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = "pantheon-issues"
  return buf
end

local function set_lines(lines)
  if not is_valid_buf(M.state.buf) then
    return
  end
  vim.bo[M.state.buf].modifiable = true
  vim.api.nvim_buf_set_lines(M.state.buf, 0, -1, false, lines)
  vim.bo[M.state.buf].modifiable = false
  vim.api.nvim_buf_clear_namespace(M.state.buf, ns, 0, -1)
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

local function clean_text(value)
  if value == nil then
    return ""
  end
  return tostring(value):gsub("[%c%s]+", " "):gsub("^%s+", ""):gsub("%s+$", "")
end

local function join(value)
  if type(value) ~= "table" then
    return clean_text(value)
  end
  local result = {}
  for _, item in ipairs(value) do
    local text = clean_text(item)
    if text ~= "" then
      result[#result + 1] = text
    end
  end
  return table.concat(result, ", ")
end

local function trim_to_width(text, width)
  if vim.fn.strdisplaywidth(text) <= width then
    return text
  end
  return vim.fn.strcharpart(text, 0, math.max(1, width - 3)) .. "..."
end

local function append_wrapped(lines, prefix, value, width)
  local text = clean_text(value)
  if text == "" then
    return
  end

  local first_prefix = "  " .. prefix .. ": "
  local next_prefix = string.rep(" ", vim.fn.strdisplaywidth(first_prefix))
  local current = first_prefix
  local current_width = vim.fn.strdisplaywidth(current)

  for word in text:gmatch("%S+") do
    local separator = current_width > vim.fn.strdisplaywidth(first_prefix) and " " or ""
    local candidate = current .. separator .. word
    if vim.fn.strdisplaywidth(candidate) > width and current_width > vim.fn.strdisplaywidth(first_prefix) then
      lines[#lines + 1] = current
      current = next_prefix .. word
    else
      current = candidate
    end
    current_width = vim.fn.strdisplaywidth(current)
  end

  lines[#lines + 1] = current
end

local function normalize_item(item, index)
  if type(item) ~= "table" then
    return nil, ("result %d is not an object"):format(index)
  end

  local repository = clean_text(item.repository)
  local issue_number = tonumber(item.issue_number)
  local title = clean_text(item.title)
  local url = clean_text(item.url)
  local score = tonumber(item.score)

  if repository == "" or not issue_number or title == "" or url == "" or not score then
    return nil, ("result %d is missing repository, issue_number, title, url, or score"):format(index)
  end
  if not url:match("^https://github%.com/") then
    return nil, ("result %d has a non-GitHub URL"):format(index)
  end

  item.issue_number = math.floor(issue_number)
  item.score = math.max(0, math.min(100, math.floor(score)))
  item.repository = repository
  item.title = title
  item.url = url
  item.id = clean_text(item.id)
  if item.id == "" then
    item.id = repository .. "#" .. item.issue_number
  end
  item.label = clean_text(item.label)
  if item.label == "" then
    item.label = ("[%d] %s#%d - %s"):format(
      item.score,
      repository,
      item.issue_number,
      title
    )
  end
  return item
end

local function extract_json(text)
  local value = type(text) == "string" and vim.trim(text) or ""
  value = value:gsub("^```[%w_-]*%s*", ""):gsub("%s*```$", "")
  local first = value:find("%[")
  local last
  for index = #value, 1, -1 do
    if value:sub(index, index) == "]" then
      last = index
      break
    end
  end
  if first and last and last >= first then
    return value:sub(first, last)
  end
  return value
end

local function decode_items(stdout, limit)
  local ok, decoded = pcall(vim.json.decode, extract_json(stdout))
  if not ok then
    return nil, "command output was not valid JSON: " .. clean_text(decoded)
  end
  if type(decoded) ~= "table" or not vim.islist(decoded) then
    return nil, "command output must be a JSON array"
  end

  local items = {}
  for index, item in ipairs(decoded) do
    local normalized, err = normalize_item(item, index)
    if not normalized then
      return nil, err
    end
    items[#items + 1] = normalized
    if #items >= limit then
      break
    end
  end
  if #items == 0 then
    return nil, "command returned an empty issue list"
  end
  return items
end

local function prompt_for(opts, preferences)
  if type(opts.issue_prompt) == "function" then
    return opts.issue_prompt(preferences)
  elseif type(opts.issue_prompt) == "string" and opts.issue_prompt ~= "" then
    local prompt = opts.issue_prompt
    if preferences ~= "" then
      prompt = prompt .. "\n\nUser preferences:\n" .. preferences
    end
    return prompt
  end
  return skill.build(preferences)
end

local function command_for(opts, prompt)
  local configured = opts.issue_command
  if type(configured) == "function" then
    configured = configured(prompt)
  end
  if type(configured) ~= "table" or #configured == 0 then
    return nil, nil, "issue_command must be a non-empty argv table or a function returning one"
  end

  local command = {}
  local prompt_in_arguments = false
  for index, argument in ipairs(configured) do
    if type(argument) ~= "string" then
      return nil, nil, ("issue_command argument %d is not a string"):format(index)
    end
    local replaced, count = argument:gsub("{prompt}", function()
      return prompt
    end)
    command[#command + 1] = replaced
    prompt_in_arguments = prompt_in_arguments or count > 0
  end
  return command, prompt_in_arguments and nil or prompt
end

local function target_on_cursor()
  if not is_valid_win(M.state.win) then
    return nil
  end
  local line = vim.api.nvim_win_get_cursor(M.state.win)[1]
  return M.state.line_targets[line]
end

local function render_message(title, message)
  M.state.view = "message"
  M.state.line_targets = {}
  local width = is_valid_win(M.state.win) and vim.api.nvim_win_get_width(M.state.win) or 80
  local lines = { "", "  " .. title, "" }
  append_wrapped(lines, "Details", message, math.max(30, width - 2))
  lines[#lines + 1] = ""
  lines[#lines + 1] = "  r retry   q close"
  set_lines(lines)
  highlight(2, 2, -1, "Title")
  highlight(#lines, 2, -1, "Comment")
  if is_valid_win(M.state.win) then
    vim.api.nvim_win_set_cursor(M.state.win, { 2, 0 })
  end
end

local function render_list()
  M.state.view = "list"
  M.state.selected = nil
  M.state.line_targets = {}

  local width = vim.api.nvim_win_get_width(M.state.win)
  local lines = {
    "",
    ("  High-signal GitHub issues (%d)"):format(#M.state.items),
    "  Enter details   o browser   r refresh   q close",
    "",
  }

  for _, item in ipairs(M.state.items) do
    local line = #lines + 1
    lines[#lines + 1] = "  " .. trim_to_width(item.label, math.max(20, width - 4))
    M.state.line_targets[line] = item

    local metadata = table.concat(vim.tbl_filter(function(value)
      return value ~= ""
    end, {
      clean_text(item.difficulty),
      clean_text(item.scope),
      join(item.domains),
    }), " | ")
    if metadata ~= "" then
      lines[#lines + 1] = "    " .. trim_to_width(metadata, math.max(20, width - 6))
    end
  end

  set_lines(lines)
  highlight(2, 2, -1, "Title")
  highlight(3, 2, -1, "Comment")
  for line in pairs(M.state.line_targets) do
    highlight(line, 2, -1, "Normal")
  end

  local first_line = next(M.state.line_targets)
  if first_line then
    for line in pairs(M.state.line_targets) do
      if line < first_line then
        first_line = line
      end
    end
    vim.api.nvim_win_set_cursor(M.state.win, { first_line, 0 })
  end
end

local function render_detail(item)
  M.state.view = "detail"
  M.state.selected = item
  M.state.line_targets = {}

  local width = math.max(40, vim.api.nvim_win_get_width(M.state.win) - 2)
  local lines = { "", "  " .. item.label, "" }
  append_wrapped(lines, "Repository", item.repository, width)
  append_wrapped(lines, "Score", ("%d / 100 (%s confidence)"):format(item.score, clean_text(item.confidence)), width)
  append_wrapped(lines, "Difficulty", item.difficulty, width)
  append_wrapped(lines, "Scope", item.scope, width)
  append_wrapped(lines, "Domains", join(item.domains), width)
  append_wrapped(lines, "Languages", join(item.languages), width)
  append_wrapped(lines, "Summary", item.summary, width)
  append_wrapped(lines, "Technical puzzle", item.technical_puzzle, width)
  append_wrapped(lines, "Career signal", item.career_signal, width)
  append_wrapped(lines, "First step", item.first_step, width)
  append_wrapped(lines, "Initial deliverable", item.deliverable, width)
  append_wrapped(lines, "Assignment", item.assignment_status, width)
  append_wrapped(lines, "Labels", join(item.labels), width)
  append_wrapped(lines, "Recent activity", item.activity_note, width)
  append_wrapped(lines, "Updated", item.updated_at, width)
  append_wrapped(lines, "Warning", item.warning, width)
  append_wrapped(lines, "URL", item.url, width)
  lines[#lines + 1] = ""
  lines[#lines + 1] = "  j/Left back   o browser   r refresh   q close"

  set_lines(lines)
  highlight(2, 2, -1, "Title")
  highlight(#lines, 2, -1, "Comment")
  vim.api.nvim_win_set_cursor(M.state.win, { 2, 0 })
end

local function open_url(item)
  item = item or M.state.selected or target_on_cursor()
  if type(item) ~= "table" or not item.url then
    return
  end
  local ok, err = browser.open(item.url, M.state.opts)
  if not ok and err then
    vim.notify("Pantheon Issues: " .. tostring(err), vim.log.levels.ERROR)
  end
end

local function run()
  M.state.request_id = M.state.request_id + 1
  local request_id = M.state.request_id
  local prompt = prompt_for(M.state.opts, M.state.preferences)
  local command, stdin, err = command_for(M.state.opts, prompt)
  if not command then
    render_message("Issue scout is not configured", err)
    return
  end

  render_message("Searching GitHub issues", "The configured command is running. Results will appear here when it finishes.")
  local ok, process = pcall(vim.system, command, {
    text = true,
    stdin = stdin,
    timeout = M.state.opts.issue_timeout or 180000,
  }, function(result)
    vim.schedule(function()
      if request_id ~= M.state.request_id or not is_valid_win(M.state.win) then
        return
      end
      M.state.process = nil
      if result.code ~= 0 then
        local detail = clean_text(result.stderr)
        if detail == "" then
          detail = ("command exited with status %d"):format(result.code)
        end
        render_message("Issue scout failed", detail)
        return
      end

      local items, decode_err = decode_items(
        result.stdout,
        M.state.opts.issue_results_limit or 12
      )
      if not items then
        render_message("Issue scout returned unusable output", decode_err)
        return
      end
      M.state.items = items
      render_list()
    end)
  end)

  if not ok then
    render_message("Issue scout could not start", clean_text(process))
    return
  end
  M.state.process = process
end

local function move_cursor(direction)
  if M.state.view ~= "list" or not is_valid_win(M.state.win) then
    vim.cmd.normal({ direction > 0 and "j" or "k", bang = true })
    return
  end

  local selectable = {}
  for line in pairs(M.state.line_targets) do
    selectable[#selectable + 1] = line
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
end

local function select_current()
  if M.state.view == "list" then
    local item = target_on_cursor()
    if item then
      render_detail(item)
    end
  elseif M.state.view == "detail" then
    open_url(M.state.selected)
  end
end

local function go_back()
  if M.state.view == "detail" and M.state.items then
    render_list()
  end
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

  map("q", M.close, "Close Pantheon issues")
  map("<Esc>", M.close, "Close Pantheon issues")
  map("<C-c>", M.close, "Close Pantheon issues")
  map("<CR>", select_current, "Open Pantheon issue details")
  map("l", select_current, "Open Pantheon issue details")
  map("<Right>", select_current, "Open Pantheon issue details")
  map("j", go_back, "Return to Pantheon issue list")
  map("<Left>", go_back, "Return to Pantheon issue list")
  map("o", open_url, "Open Pantheon issue in browser")
  map("r", run, "Refresh Pantheon issues")
  map("i", function()
    move_cursor(-1)
  end, "Select previous Pantheon issue")
  map("k", function()
    move_cursor(1)
  end, "Select next Pantheon issue")
  map("<Up>", function()
    move_cursor(-1)
  end, "Select previous Pantheon issue")
  map("<Down>", function()
    move_cursor(1)
  end, "Select next Pantheon issue")
end

function M.close()
  M.state.request_id = M.state.request_id + 1
  if M.state.process then
    pcall(function()
      M.state.process:kill(15)
    end)
  end
  M.state.process = nil
  vim.api.nvim_clear_autocmds({ group = autocmd_group })
  if is_valid_win(M.state.win) then
    vim.api.nvim_win_close(M.state.win, true)
  end
  M.state.buf = nil
  M.state.win = nil
  M.state.line_targets = {}
  M.state.selected = nil
end

function M.open(opts, preferences, force)
  M.state.opts = opts or {}
  local next_preferences = type(preferences) == "string" and vim.trim(preferences) or ""
  local preferences_changed = next_preferences ~= M.state.preferences
  M.state.preferences = next_preferences

  if is_valid_win(M.state.win) then
    vim.api.nvim_set_current_win(M.state.win)
    if force or preferences_changed then
      run()
    end
    return
  end

  local buf = make_buf()
  local win = vim.api.nvim_open_win(buf, true, window_config(M.state.opts))
  M.state.buf = buf
  M.state.win = win
  M.state.view = "list"

  vim.wo[win].wrap = false
  vim.wo[win].cursorline = true
  vim.wo[win].cursorlineopt = "line"
  vim.wo[win].number = false
  vim.wo[win].relativenumber = false
  vim.wo[win].signcolumn = "no"
  vim.wo[win].winfixbuf = true

  map_keys(buf)
  if force or not M.state.items then
    run()
  else
    render_list()
  end

  vim.api.nvim_clear_autocmds({ group = autocmd_group })
  vim.api.nvim_create_autocmd("VimResized", {
    group = autocmd_group,
    buffer = buf,
    callback = function()
      if not is_valid_win(M.state.win) then
        return
      end
      vim.api.nvim_win_set_config(M.state.win, window_config(M.state.opts))
      if M.state.view == "detail" and M.state.selected then
        render_detail(M.state.selected)
      elseif M.state.view == "list" and M.state.items then
        render_list()
      end
    end,
  })
end

return M
