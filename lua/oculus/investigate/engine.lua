local M = {}

local function file_executable(path)
  if not path or path == "" then
    return false
  end

  return vim.fn.filereadable(path) == 1
end

function M.plugin_root()
  local info = debug.getinfo(1, "S")
  local script_path = info.source:sub(2)

  -- script is in lua/oculus/investigate/engine.lua, so up 4 dirs is repo root
  local root = vim.fs.dirname(
    vim.fs.dirname(
      vim.fs.dirname(
        vim.fs.dirname(script_path)
      )
    )
  )

  if root and root ~= "" and vim.fn.isdirectory(root) == 1 then
    return vim.fs.normalize(root)
  end

  return vim.fs.normalize(vim.fn.getcwd())
end

function M.find_engine_binary(opts)
  opts = opts or {}

  if opts.engine_path and file_executable(opts.engine_path) then
    return vim.fs.normalize(opts.engine_path)
  end

  local in_path = vim.fn.exepath("oculus-engine")

  if in_path ~= "" then
    return vim.fs.normalize(in_path)
  end

  local root = M.plugin_root()
  local is_windows = vim.fn.has("win32") == 1
  local exe_name = is_windows and "oculus-engine.exe" or "oculus-engine"

  local candidates = {
    vim.fs.joinpath(root, "crates", "oculus-engine", "target", "release", exe_name),
    vim.fs.joinpath(root, "crates", "oculus-engine", "target", "debug", exe_name),
    vim.fs.joinpath(root, "bin", exe_name),
  }

  for _, candidate in ipairs(candidates) do
    if file_executable(candidate) then
      return vim.fs.normalize(candidate)
    end
  end

  return nil
end

function M.run(request, callback)
  if type(request) ~= "table" then
    if callback then
      callback(nil, "invalid investigation request: expected table")
    end

    return
  end

  local repo = request.repo_root or request.cwd or vim.fn.getcwd()
  local binary = M.find_engine_binary(request.opts)

  if not binary then
    local err = "oculus-engine binary not found. Build it with `cargo build --release --manifest-path crates/oculus-engine/Cargo.toml`"

    if callback then
      vim.schedule(function()
        callback(nil, err)
      end)
    end

    return nil, err
  end

  local cmd = {
    binary,
    "investigate",
    "--repo",
    repo,
  }

  if request.target and request.target ~= "" then
    table.insert(cmd, "--target")
    table.insert(cmd, tostring(request.target))
  end

  if request.target_kind and request.target_kind ~= "" then
    table.insert(cmd, "--target-kind")
    table.insert(cmd, tostring(request.target_kind))
  end

  if request.db_path and request.db_path ~= "" then
    table.insert(cmd, "--db")
    table.insert(cmd, tostring(request.db_path))
  end

  if type(request.forge_artifact) == "table" then
    local ok_encode, encoded = pcall(vim.json.encode, request.forge_artifact)

    if ok_encode and encoded and encoded ~= "" then
      table.insert(cmd, "--forge-data")
      table.insert(cmd, encoded)
    end
  end

  local ok, proc = pcall(vim.system, cmd, { text = true }, function(result)
    vim.schedule(function()
      if result.code ~= 0 then
        local err_msg = vim.trim(result.stderr or "")

        if err_msg == "" then
          err_msg = "oculus-engine exited with code " .. tostring(result.code)
        end

        if callback then
          callback(nil, err_msg)
        end

        return
      end

      local stdout = vim.trim(result.stdout or "")

      if stdout == "" then
        if callback then
          callback(nil, "oculus-engine returned empty output")
        end

        return
      end

      local decode_ok, bundle = pcall(vim.json.decode, stdout)

      if not decode_ok or type(bundle) ~= "table" then
        if callback then
          callback(nil, "oculus-engine returned malformed JSON: " .. tostring(bundle))
        end

        return
      end

      if callback then
        callback(bundle, nil)
      end
    end)
  end)

  if not ok then
    local err = tostring(proc)

    if callback then
      vim.schedule(function()
        callback(nil, err)
      end)
    end

    return nil, err
  end

  return proc
end

return M
