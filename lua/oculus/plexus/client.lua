local M = {}

-- The CLI is the versioned boundary: no shell interpolation or local reasoning.
function M.request(config, arguments, callback)
  local command = config.command or { "plexus" }

  if type(command) ~= "table" or #command == 0 then
    callback(nil, "plexus.command must be a nonempty argv list")
    return
  end

  local argv = vim.deepcopy(command)

  for _, value in ipairs(argv) do
    if type(value) ~= "string" or value == "" then
      callback(nil, "plexus.command entries must be nonempty strings")
      return
    end
  end

  vim.list_extend(argv, arguments)
  local runtime_commands = { hypothesize = true, revise = true, run = true, replay = true, compose = true, ["compose-run"] = true, ["component-plan"] = true }

  if runtime_commands[arguments[1]] then
    local backend = config.backend or "wasmtime"

    if backend ~= "wasmtime" and backend ~= "zug" then
      callback(nil, "plexus.backend must be wasmtime or zug")
      return
    end

    if backend == "zug" then
      if type(config.zug_command) ~= "string" or config.zug_command:sub(1, 1) ~= "/" then
        callback(nil, "plexus.zug_command must be an absolute executable path")
        return
      end

      vim.list_extend(argv, { "--backend", "zug", "--zug-command", config.zug_command })
    end
  end

  local active = true

  local ok, process = pcall(vim.system, argv, {
    text = true,
    timeout = arguments[1] == "investigate" and (config.capture_timeout_ms or 300000) or (config.timeout_ms or 120000),
  }, function(result)
    vim.schedule(function()
      if not active then return end
      active = false

      if result.code ~= 0 then
        callback(nil, vim.trim(result.stderr or "") ~= "" and vim.trim(result.stderr)
          or ("Plexus exited with code " .. tostring(result.code)))

        return
      end

      local decoded, value = pcall(vim.json.decode, result.stdout or "")

      local version = decoded and type(value) == "table" and (value.schema_version
        or (type(value.plan) == "table" and value.plan.schema_version)
        or (type(value.record) == "table" and value.record.schema_version)
        or (type(value.replay) == "table" and type(value.replay.record) == "table"
          and value.replay.record.schema_version))

      local component_run = arguments[1] == "component-checksum-run" and (version == 2 or version == 3)

      if version ~= 1 and not component_run then
        callback(nil, "Plexus returned invalid or unsupported JSON")
        return
      end

      callback(value)
    end)
  end)

  if not ok then
    active = false
    callback(nil, tostring(process))
    return
  end

  return {
    cancel = function()
      if not active then return end
      active = false
      pcall(process.kill, process, 15)
    end,
  }
end

return M
