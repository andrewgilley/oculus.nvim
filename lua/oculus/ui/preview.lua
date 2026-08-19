local M = {}
local ui_win = require("oculus.ui.window")

M.preview_ns = vim.api.nvim_create_namespace("oculus_preview")

function M.preview_left_width(window_width)
  local preferred = math.max(40, math.floor(window_width * 0.52))
  return math.max(30, math.min(preferred, window_width - 22))
end

function M.is_formatted_preview(text)
  return text:match('^".*"$')
    or text:match('^PR #%d+ · ".*"$')
    or text:match("^• ")
end

function M.wrapped_preview_text(text, width, limit)
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

    lines[#lines + 1] = ui_win.trim_to_width(line, width)
  end

  return lines
end

function M.render_preview_panel(buf, win, items)
  if not ui_win.is_valid_buf(buf) or not ui_win.is_valid_win(win) then
    return
  end

  vim.api.nvim_buf_clear_namespace(buf, M.preview_ns, 0, -1)
  local window_width = vim.api.nvim_win_get_width(win)
  local left_width = M.preview_left_width(window_width)
  local right_width = math.max(16, window_width - left_width - 3)
  local line_count = vim.api.nvim_buf_line_count(buf)

  for line = 1, line_count do
    local item = items and items[line]
    local text = item and ui_win.trim_to_width(item[1], right_width - 1) or ""
    local group = item and item[2] or "NormalFloat"

    vim.api.nvim_buf_set_extmark(buf, M.preview_ns, line - 1, 0, {
      virt_text = {
        { "│", "WinSeparator" },
        { " " .. text, group },
      },
      virt_text_win_col = left_width,
      hl_mode = "combine",
    })
  end
end

function M.clear_preview(buf)
  if ui_win.is_valid_buf(buf) then
    vim.api.nvim_buf_clear_namespace(buf, M.preview_ns, 0, -1)
  end
end

return M
