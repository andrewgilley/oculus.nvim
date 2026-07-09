local M = {}

local function windows_edge()
  local variables = { "PROGRAMFILES(X86)", "PROGRAMFILES", "LOCALAPPDATA" }
  for _, variable in ipairs(variables) do
    local root = vim.env[variable]
    if root then
      local candidate = root .. "\\Microsoft\\Edge\\Application\\msedge.exe"
      if vim.fn.executable(candidate) == 1 then
        return candidate
      end
    end
  end
end

function M.command(config, url)
  local configured = config.browser_command

  if type(configured) == "function" then
    return configured(url)
  elseif type(configured) == "table" and #configured > 0 then
    local command = {}
    local has_url = false
    for _, argument in ipairs(configured) do
      local replaced, count = argument:gsub("{url}", function()
        return url
      end)
      command[#command + 1] = replaced
      has_url = has_url or count > 0
    end
    if not has_url then
      command[#command + 1] = url
    end
    return command
  end

  if vim.uv.os_uname().sysname == "Windows_NT" then
    local edge = windows_edge()
    if edge then
      return { edge, "--new-window", url }
    end
  end
end

function M.open(url, config)
  local command = M.command(config, url)
  if not command then
    return vim.ui.open(url)
  end

  local ok, process = pcall(vim.system, command, { detach = true })
  if not ok then
    return nil, process
  end
  return process
end

return M
