local M = {}

M.window_highlight_ns = vim.api.nvim_create_namespace("oculus_window_highlights")

M.window_highlight_groups = {
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

function M.is_valid_win(win)
  return win and vim.api.nvim_win_is_valid(win)
end

function M.is_valid_buf(buf)
  return buf and vim.api.nvim_buf_is_valid(buf)
end

function M.window_highlight_name(win, group)
  if not M.is_valid_win(win) then
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

function M.source_highlight(win, group)
  local name = M.window_highlight_name(win, group)

  if M.is_valid_win(win) then
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

function M.sync_window_highlights(source_win)
  local current_normal = {}
  local current_border = {}

  for _, group in ipairs(M.window_highlight_groups) do
    local definition = M.source_highlight(source_win, group)
    vim.api.nvim_set_hl(M.window_highlight_ns, group, definition)

    if group == "Normal" then
      current_normal = vim.deepcopy(definition)
    elseif group == "FloatBorder" then
      current_border = vim.deepcopy(definition)
    end
  end

  vim.api.nvim_set_hl(
    M.window_highlight_ns,
    "OculusNormal",
    current_normal
  )

  vim.api.nvim_set_hl(
    M.window_highlight_ns,
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
    M.window_highlight_ns,
    "OculusBorder",
    current_border
  )

  vim.api.nvim_set_hl(
    M.window_highlight_ns,
    "FloatBorder",
    current_border
  )

  vim.api.nvim_set_hl(0, "OculusBorder", current_border)

  vim.api.nvim_set_hl(M.window_highlight_ns, "OculusActivityIcon", {
    fg = "#fbd38d",
    bg = "NONE",
  })

  vim.api.nvim_set_hl(M.window_highlight_ns, "OculusActivityPreview", {
    fg = "#9ae6b4",
    bg = "NONE",
  })

  vim.api.nvim_set_hl(
    M.window_highlight_ns,
    "OculusContributorSelected",
    { fg = "#ffffff" }
  )

  vim.api.nvim_set_hl(M.window_highlight_ns, "OculusActivityQueued", {
    fg = "#fbd38d",
    bold = true,
  })
end

function M.use_window_highlights(win)
  if M.is_valid_win(win) then
    vim.api.nvim_win_set_hl_ns(win, M.window_highlight_ns)
  end
end

function M.apply_window_highlights(win, source_win, state)
  if M.is_valid_win(source_win) and state then
    state.highlight_source_win = source_win
  end

  if state then
    state.highlight_generation = (state.highlight_generation or 0) + 1
  end

  M.sync_window_highlights(source_win or (state and state.highlight_source_win))
  M.use_window_highlights(win)
end

function M.refresh_window_highlights(source_win, state)
  if M.is_valid_win(source_win) and state then
    state.highlight_source_win = source_win
  end

  source_win = source_win or (state and state.highlight_source_win)

  if state then
    state.highlight_generation = (state.highlight_generation or 0) + 1
    local generation = state.highlight_generation
    M.sync_window_highlights(source_win)

    vim.schedule(function()
      if generation == state.highlight_generation then
        M.sync_window_highlights(source_win)
      end
    end)
  else
    M.sync_window_highlights(source_win)
  end
end

function M.inspection_window_options(source_win)
  M.sync_window_highlights(source_win)

  return {
    number = true,
    relativenumber = true,
    cursorline = true,
    winhighlight = "Normal:OculusNormal,FloatBorder:OculusBorder",
  }
end

function M.dimension(value, total, fallback, minimum)
  local result = fallback

  if type(value) == "number" then
    result = value <= 1 and math.floor(total * value) or math.floor(value)
  end

  return math.max(minimum or 1, math.min(total, result))
end

function M.make_win_config(opts)
  local width = M.dimension(opts.width, vim.o.columns, math.floor(vim.o.columns * 0.7), 20)
  local height = M.dimension(opts.height, vim.o.lines, math.floor(vim.o.lines * 0.7), 5)
  local col = math.floor((vim.o.columns - width) / 2)
  local row = math.floor((vim.o.lines - height) / 2)

  return {
    relative = "editor",
    width = width,
    height = height,
    col = col,
    row = row,
    style = "minimal",
    border = opts.border or "rounded",
    zindex = 50,
  }
end

function M.make_buf()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = "oculus"
  return buf
end

function M.make_footer_buf()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = "oculus-footer"
  return buf
end

function M.footer_win_config(state)
  if not M.is_valid_win(state.win) then
    return nil
  end

  local main_pos = vim.api.nvim_win_get_position(state.win)
  local main_width = vim.api.nvim_win_get_width(state.win)
  local main_height = vim.api.nvim_win_get_height(state.win)
  local border = (state.opts and state.opts.border) or "rounded"
  local has_border = border ~= "none"
  local border_offset = has_border and 1 or 0

  return {
    relative = "editor",
    width = main_width,
    height = 1,
    row = main_pos[1] + main_height + border_offset,
    col = main_pos[2],
    style = "minimal",
    border = has_border and { "", "", "", "", "─", "─", "─", "" } or "none",
    zindex = 51,
  }
end

function M.trim_to_width(text, width)
  if #text <= width then
    return text
  end

  if width <= 3 then
    return text:sub(1, width)
  end

  return text:sub(1, width - 1) .. "…"
end

function M.pad_cell(text, width)
  local len = vim.fn.strdisplaywidth(text)
  if len >= width then
    return text
  end
  return text .. string.rep(" ", width - len)
end

function M.left_pad_cell(text, width)
  local len = vim.fn.strdisplaywidth(text)
  if len >= width then
    return text
  end
  return string.rep(" ", width - len) .. text
end

return M
