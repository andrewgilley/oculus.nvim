local M = {}

local function unique_files(inspections)
  local files = {}
  local seen = {}
  for _, inspection in ipairs(inspections or {}) do
    local file = inspection.change_file or inspection.parent_file
    if file and not seen[file] then
      seen[file] = true
      files[#files + 1] = file
    end
  end
  return files
end

local function summary_prompt(inspections, info)
  local first = inspections[1]
  local last = inspections[#inspections]
  local base = first and first.parent or ""
  local head = last and last.commit or ""
  local files = unique_files(inspections)
  local goal = info.kind == "pull_request"
      and ("Pull request #%d: %s"):format(
        info.number,
        info.title or "(no title available)"
      )
    or (
      "Commit " .. head
        .. "; infer its goal from the commit subject and body."
    )
  return table.concat({
    "Summarize this code change for a compact Neovim inspection float.",
    "Return only one or two concise sentences with no heading or bullets.",
    "Explain what the changes accomplish in relation to the stated goal.",
    "Inspect the repository with read-only git commands when needed.",
    "",
    "Goal: " .. goal,
    "Base revision: " .. base,
    "Changed revision: " .. head,
    "Changed files:",
    table.concat(vim.tbl_map(function(file)
      return "- " .. file
    end, files), "\n"),
  }, "\n")
end

local function content_text(content)
  if type(content) == "string" then
    return content
  end
  if type(content) ~= "table" then
    return nil
  end
  local parts = {}
  for _, part in ipairs(content) do
    local text = type(part) == "table"
        and (part.text or part.content)
      or nil
    if type(text) == "string" and text ~= "" then
      parts[#parts + 1] = text
    end
  end
  return #parts > 0 and table.concat(parts, "\n") or nil
end

local function final_message(output)
  local message
  for line in (output or ""):gmatch("[^\r\n]+") do
    local ok, event = pcall(vim.json.decode, line)
    if ok and type(event) == "table" then
      local item = event.item
      if
        event.type == "item.completed"
        and type(item) == "table"
        and item.type == "agent_message"
      then
        message = item.text
          or content_text(item.content)
          or message
      elseif event.type == "message" then
        message = event.text
          or content_text(event.content)
          or message
      end
    end
  end
  return type(message) == "string" and vim.trim(message) or nil
end

local function normalize_summary(text)
  text = vim.trim((text or ""):gsub("[%c%s]+", " "))
  if text == "" then
    return nil
  end
  if vim.fn.strchars(text) > 600 then
    text = vim.fn.strcharpart(text, 0, 599) .. "…"
  end
  return text
end

local function float_dimensions(endpoint, text)
  local main_width = vim.api.nvim_win_get_width(endpoint.win)
  local width = math.max(1, math.min(42, main_width - 4))
  local rows = math.max(
    1,
    math.ceil(vim.fn.strdisplaywidth(text) / width)
  )
  return width, math.min(5, rows)
end

local function float_config(endpoint, width, height)
  local main_width = vim.api.nvim_win_get_width(endpoint.win)
  return {
    relative = "win",
    win = endpoint.win,
    anchor = "NE",
    row = 1,
    col = math.max(0, main_width - 1),
    width = width,
    height = height,
    style = "minimal",
    border = "rounded",
    focusable = false,
    noautocmd = true,
    zindex = 70,
  }
end

local function create_float(group, endpoint)
  if
    not endpoint
    or not vim.api.nvim_win_is_valid(endpoint.win)
    or not vim.api.nvim_buf_is_valid(group.summary_buf)
  then
    return
  end
  local text = vim.api.nvim_buf_get_lines(
    group.summary_buf,
    0,
    1,
    false
  )[1] or ""
  local width, height = float_dimensions(endpoint, text)
  local win = vim.api.nvim_open_win(
    group.summary_buf,
    false,
    float_config(endpoint, width, height)
  )
  vim.wo[win].wrap = true
  vim.wo[win].linebreak = true
  vim.wo[win].number = false
  vim.wo[win].relativenumber = false
  vim.wo[win].signcolumn = "no"
  vim.wo[win].winhighlight =
    "FloatBorder:PantheonInspectSummaryBorder"
  group.summary_windows[endpoint.tab] = {
    endpoint = endpoint,
    win = win,
  }
end

function M.refresh(group)
  if
    not group
    or not group.summary_buf
    or not vim.api.nvim_buf_is_valid(group.summary_buf)
  then
    return
  end
  local text = vim.api.nvim_buf_get_lines(
    group.summary_buf,
    0,
    1,
    false
  )[1] or ""
  for tab, view in pairs(group.summary_windows or {}) do
    if
      vim.api.nvim_tabpage_is_valid(tab)
      and vim.api.nvim_win_is_valid(view.win)
      and vim.api.nvim_win_is_valid(view.endpoint.win)
    then
      local width, height = float_dimensions(view.endpoint, text)
      vim.api.nvim_win_set_config(
        view.win,
        float_config(view.endpoint, width, height)
      )
    end
  end
end

local function set_summary(group, text)
  if
    not group
    or not group.summary_buf
    or not vim.api.nvim_buf_is_valid(group.summary_buf)
  then
    return
  end
  vim.bo[group.summary_buf].modifiable = true
  vim.api.nvim_buf_set_lines(
    group.summary_buf,
    0,
    -1,
    false,
    { text }
  )
  vim.bo[group.summary_buf].modifiable = false
  M.refresh(group)
end

local function codex_summary(repository, prompt, opts, callback)
  local executable = vim.fn.exepath("codex")
  if executable == "" then
    callback(nil, "Codex CLI is not available")
    return
  end
  local command = {
    executable,
    "exec",
    "--ephemeral",
    "--sandbox",
    "read-only",
    "--color",
    "never",
    "--json",
    "-C",
    repository,
    "-",
  }
  local finished = false
  local timer = vim.uv.new_timer()
  local process
  local function finish(text, err)
    if finished then
      return
    end
    finished = true
    if timer and not timer:is_closing() then
      timer:stop()
      timer:close()
    end
    callback(text, err)
  end
  local ok, spawned = pcall(vim.system, command, {
    text = true,
    stdin = prompt,
  }, function(result)
    vim.schedule(function()
      if result.code ~= 0 then
        local err = vim.trim(result.stderr or "")
        finish(nil, err ~= "" and err or "Codex CLI exited unsuccessfully")
        return
      end
      local message = final_message(result.stdout)
      if not message then
        finish(nil, "Codex CLI returned no summary")
        return
      end
      finish(message)
    end)
  end)
  if not ok then
    finish(nil, "could not start Codex CLI: " .. tostring(spawned))
    return
  end
  process = spawned
  local timeout = math.max(
    1,
    tonumber(opts.inspect_summary_timeout) or 120
  ) * 1000
  timer:start(timeout, 0, vim.schedule_wrap(function()
    if process then
      pcall(process.kill, process, 15)
    end
    finish(nil, "Codex CLI summary timed out")
  end))
  return function()
    if finished then
      return
    end
    finished = true
    if timer and not timer:is_closing() then
      timer:stop()
      timer:close()
    end
    if process then
      pcall(process.kill, process, 15)
    end
  end
end

function M.start(group, inspections, info, opts)
  if opts.inspect_summary == false or #inspections == 0 then
    return
  end
  local repository = inspections[1].repository
  if not repository then
    return
  end
  local buf = vim.api.nvim_create_buf(false, true)
  group.summary_buf = buf
  group.summary_windows = {}
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = "markdown"
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "Asking Codex…" })
  vim.bo[buf].modifiable = false
  vim.b[buf].pantheon_inspect_summary = true
  vim.api.nvim_set_hl(0, "PantheonInspectSummaryBorder", {
    fg = 0xffffff,
  })
  for _, session in ipairs(group) do
    create_float(group, session.parent)
    create_float(group, session.change)
  end

  local prompt = summary_prompt(inspections, info)
  local runner = opts.inspect_summary_runner or codex_summary
  local cancel = runner(repository, prompt, opts, function(text, err)
    local summary = normalize_summary(text)
    if summary then
      set_summary(group, summary)
    else
      local reason =
        normalize_summary(tostring(err)) or "unknown error"
      set_summary(group, "Codex summary unavailable: " .. reason)
    end
  end)
  if type(cancel) == "function" then
    group.summary_cancel = cancel
    vim.api.nvim_create_autocmd("BufWipeout", {
      buffer = buf,
      once = true,
      callback = function()
        group.summary_cancel = nil
        cancel()
      end,
    })
  end
end

M._prompt = summary_prompt
M._final_message = final_message
M._normalize = normalize_summary
M._float_config = float_config

return M
