local M = {}

local defaults = {
  width = 0.64,
  height = 0.70,
  border = "rounded",
  title = " Pantheon opinion ",
  filetype = "markdown",
}

local next_view = 0

local function valid_buf(buf)
  return buf and vim.api.nvim_buf_is_valid(buf)
end

local function valid_win(win)
  return win and vim.api.nvim_win_is_valid(win)
end

local function dimension(value, total, minimum)
  local result = value
  if type(value) == "number" and value > 0 and value <= 1 then
    result = math.floor(total * value)
  end
  result = tonumber(result) or minimum
  return math.max(minimum, math.min(math.floor(result), total - 2))
end

local function window_config(opts)
  local columns = vim.o.columns
  local lines = vim.o.lines - vim.o.cmdheight
  local width = dimension(opts.width, columns, 20)
  local height = dimension(opts.height, lines, 3)
  return {
    relative = "editor",
    width = width,
    height = height,
    row = math.max(0, math.floor((lines - height) / 2) - 1),
    col = math.max(0, math.floor((columns - width) / 2)),
    style = "minimal",
    border = opts.border,
    title = opts.title,
    title_pos = "center",
    zindex = opts.zindex or 60,
  }
end

local function text_lines(value)
  if type(value) == "table" then
    if type(value.lines) == "table" then
      local lines = vim.deepcopy(value.lines)
      for _, line in ipairs(lines) do
        if type(line) ~= "string" then
          return nil
        end
      end
      return lines
    end
    value = value.text or value.content
  end
  if type(value) ~= "string" then
    return nil
  end
  local lines = vim.split(value, "\n", { plain = true })
  for index, line in ipairs(lines) do
    lines[index] = line:gsub("\r$", "")
  end
  return #lines > 0 and lines or { "" }
end

local function set_lines(view, lines, filetype)
  if view.closed or not valid_buf(view.buf) then
    return
  end
  vim.bo[view.buf].readonly = false
  vim.bo[view.buf].modifiable = true
  vim.api.nvim_buf_set_lines(view.buf, 0, -1, false, lines)
  vim.bo[view.buf].modifiable = false
  vim.bo[view.buf].readonly = true
  if filetype then
    vim.bo[view.buf].filetype = filetype
  end
end

local function stop_provider(view)
  if not view.pending or not view.cancel_provider then
    return
  end
  local cancel = view.cancel_provider
  view.cancel_provider = nil
  if type(cancel) == "function" then
    pcall(cancel)
  elseif type(cancel) == "table" and type(cancel.cancel) == "function" then
    pcall(cancel.cancel, cancel)
  end
end

local function close_view(view)
  if view.closed then
    return
  end
  view.closed = true
  stop_provider(view)
  view.pending = false
  if valid_win(view.win) then
    vim.api.nvim_win_close(view.win, true)
  end
  if valid_buf(view.buf) then
    vim.api.nvim_buf_delete(view.buf, { force = true })
  end
end

local function open_view(opts)
  next_view = next_view + 1
  local buf = vim.api.nvim_create_buf(false, true)
  local view = {
    id = next_view,
    buf = buf,
    closed = false,
    pending = false,
    opts = opts,
  }
  vim.api.nvim_buf_set_name(buf, ("pantheon-opinion://%d"):format(view.id))
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.bo[buf].modifiable = false
  vim.bo[buf].readonly = true
  vim.bo[buf].filetype = opts.filetype
  view.win = vim.api.nvim_open_win(buf, opts.enter ~= false, window_config(opts))
  vim.wo[view.win].wrap = true
  vim.wo[view.win].linebreak = true
  vim.wo[view.win].cursorline = false
  vim.keymap.set("n", "q", function()
    close_view(view)
  end, {
    buffer = buf,
    nowait = true,
    silent = true,
    desc = "Close Pantheon opinion",
  })
  vim.keymap.set("n", "<Esc>", function()
    close_view(view)
  end, {
    buffer = buf,
    nowait = true,
    silent = true,
    desc = "Close Pantheon opinion",
  })
  view.close = function()
    close_view(view)
  end
  vim.api.nvim_create_autocmd("BufWipeout", {
    buffer = buf,
    once = true,
    callback = function()
      if view.closed then
        return
      end
      view.closed = true
      stop_provider(view)
      view.pending = false
    end,
  })
  return view
end

local function resolve_opts(opts)
  return vim.tbl_deep_extend(
    "force",
    vim.deepcopy(defaults),
    opts or {}
  )
end

local function inspection_state(buf)
  local value = vim.b[buf].pantheon_inspect
  if type(value) == "table" then
    return vim.deepcopy(value)
  end
  if buf ~= vim.api.nvim_get_current_buf() then
    return nil
  end
  local ok, state = pcall(
    vim.api.nvim_tabpage_get_var,
    vim.api.nvim_get_current_tabpage(),
    "pantheon_inspect"
  )
  return ok and type(state) == "table" and state or nil
end

function M.context(buf, win)
  buf = buf or vim.api.nvim_get_current_buf()
  win = win or vim.api.nvim_get_current_win()
  if not valid_buf(buf) then
    return nil, "cannot build opinion context for an invalid buffer"
  end

  local inspection = inspection_state(buf)
  local source_path = vim.b[buf].pantheon_inspect_source_path
  local buffer_name = vim.api.nvim_buf_get_name(buf)
  if not source_path and buffer_name ~= "" and not buffer_name:match("^[%w-]+://") then
    source_path = vim.fs.normalize(buffer_name)
  end

  local root = inspection and inspection.repository or nil
  if not root and source_path then
    root = vim.fs.root(source_path, { ".git" })
  end
  if not root then
    root = valid_win(win)
        and vim.api.nvim_win_call(win, vim.fn.getcwd)
      or vim.fn.getcwd()
  end
  root = vim.fs.normalize(root)

  local cursor
  if valid_win(win) and vim.api.nvim_win_get_buf(win) == buf then
    cursor = vim.api.nvim_win_get_cursor(win)
  end
  local relative_path = source_path
      and vim.fs.relpath(root, source_path)
    or nil

  return {
    project = {
      root = root,
      name = vim.fs.basename(root),
    },
    buffer = {
      bufnr = buf,
      path = source_path,
      relative_path = relative_path,
      filetype = vim.bo[buf].filetype,
      cursor = cursor,
    },
    inspection = inspection,
  }
end

function M.show(value, opts)
  opts = resolve_opts(opts)
  local lines = text_lines(value)
  if not lines then
    return nil, "an opinion must be a string or a table with text or lines"
  end
  local view = open_view(opts)
  local filetype = type(value) == "table" and value.filetype or opts.filetype
  set_lines(view, lines, filetype)
  return view
end

function M.consult(request, opts)
  if type(request) ~= "table" then
    return nil, "an opinion request must be a table"
  end
  if request.context ~= nil and type(request.context) ~= "table" then
    return nil, "opinion request context must be a table"
  end
  opts = resolve_opts(opts)
  if type(opts.provider) ~= "function" then
    return nil, "no opinion provider is configured"
  end

  local context, context_err = M.context(request.buf, request.win)
  if not context then
    return nil, context_err
  end
  local provider_request = vim.deepcopy(request)
  provider_request.buf = nil
  provider_request.win = nil
  provider_request.context = vim.tbl_deep_extend(
    "force",
    context,
    provider_request.context or {}
  )

  local view = open_view(opts)
  view.pending = true
  set_lines(view, {
    "",
    "  Consulting model…",
    "",
    "  The result will appear here when it is ready.",
  }, "pantheon-opinion")

  local responded = false
  local function respond(result, err)
    if responded then
      return
    end
    responded = true
    vim.schedule(function()
      if view.closed or not valid_buf(view.buf) then
        return
      end
      view.pending = false
      view.cancel_provider = nil
      if err then
        set_lines(view, {
          "",
          "  Model consultation failed",
          "",
          "  " .. tostring(err),
        }, "pantheon-opinion")
        return
      end
      local lines = text_lines(result)
      if not lines then
        set_lines(view, {
          "",
          "  Model consultation failed",
          "",
          "  The provider returned no displayable opinion.",
        }, "pantheon-opinion")
        return
      end
      local filetype = type(result) == "table"
          and result.filetype
        or opts.filetype
      set_lines(view, lines, filetype or opts.filetype)
    end)
  end

  local ok, provider_result = pcall(opts.provider, provider_request, respond)
  if not ok then
    respond(nil, provider_result)
  elseif type(provider_result) == "function"
    or (
      type(provider_result) == "table"
      and type(provider_result.cancel) == "function"
    )
  then
    if not responded then
      view.cancel_provider = provider_result
      if view.closed then
        view.pending = true
        stop_provider(view)
        view.pending = false
      end
    end
  elseif provider_result ~= nil then
    respond(provider_result)
  end
  return view
end

M.defaults = defaults
M._text_lines = text_lines

return M
