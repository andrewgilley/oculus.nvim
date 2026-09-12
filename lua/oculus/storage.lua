local M = {}

function M.load(path)
  if vim.fn.filereadable(path) ~= 1 then
    return nil
  end

  local ok_read, lines = pcall(vim.fn.readfile, path)

  if not ok_read then
    return nil
  end

  local ok_decode, data = pcall(vim.json.decode, table.concat(lines, "\n"))

  if not ok_decode or type(data) ~= "table" then
    return nil
  end

  return data
end

function M.save(path, config)
  if type(config.tracking_file) == 'string' then
    local function canonical(value)
      value = vim.fn.fnamemodify(vim.fn.expand(value), ':p')
      return vim.uv.fs_realpath(value) or value
    end

    if canonical(path) == canonical(config.tracking_file) then
      return false, 'state_file and tracking_file must be different files'
    end
  end

  local directory = vim.fn.fnamemodify(path, ":h")

  if
    vim.fn.mkdir(directory, "p") == 0
    and vim.fn.isdirectory(directory) ~= 1
  then
    return false, "could not create " .. directory
  end

  local payload = {
    activity_types = config.activity_types,
    user_activity_types = config.user_activity_types or {},
    project_activity_types = config.project_activity_types,
    project_issue_filters = config.project_issue_filters or {},
    contributors = config.contributors or {},
    projects = config.projects or {},
    project_directories = config.project_directories or {},
    project_order = config.project_order or {},
    removed_contributors = config.removed_contributors or {},
    removed_projects = config.removed_projects or {},
    inspect_overviews = config.inspect_overviews or {},
    search_history = config.search_history or {},
  }

  -- Tracking membership belongs only to its external file. Filter/history
  -- saves must not replace the user's legacy lists (including after errors).
  if config.tracking_file then
    local saved = M.load(path) or {}

    for _, key in ipairs({ 'contributors', 'projects', 'project_directories',
      'project_order', 'removed_contributors', 'removed_projects' }) do
      payload[key] = saved[key] or {}
    end
  end

  local ok_encode, encoded = pcall(vim.json.encode, payload)

  if not ok_encode then
    return false, encoded
  end

  local temporary = path .. ".tmp"
  local ok_write, write_error = pcall(vim.fn.writefile, { encoded }, temporary)

  if not ok_write then
    return false, write_error
  end

  local ok_rename, rename_error = vim.uv.fs_rename(temporary, path)

  if not ok_rename then
    pcall(vim.fn.delete, temporary)
    return false, rename_error
  end

  return true
end

return M
