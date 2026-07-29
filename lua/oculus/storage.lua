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
  }
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
