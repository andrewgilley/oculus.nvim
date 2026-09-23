local M = {}
local states = { queued = true, running = true, succeeded = true, failed = true, cancelled = true, interrupted = true }

local function string(value)
  return type(value) == "string" and value ~= ""
end

local function optional_string(value)
  return value == nil or value == vim.NIL or string(value)
end

local function job(value)
  assert(type(value) == "table" and string(value.id) and states[value.state], "Invalid job identity or state")

  for _, key in ipairs({ "resource_id", "plan_id", "artifact_store" }) do
    assert(string(value[key]), "Missing job " .. key)
  end

  for _, key in ipairs({ "hypothesis_id", "binding_id" }) do
    assert(value.kind == "composition" and optional_string(value[key]) or string(value[key]), "Missing job " .. key)
  end

  for _, key in ipairs({ "run_id", "result_hypothesis_id", "result_investigation_id", "error", "retry_of", "conclusion" }) do
    assert(optional_string(value[key]), "Invalid job " .. key)
  end

  assert(value.cancel_requested == nil or type(value.cancel_requested) == "boolean", "Invalid cancellation status")
end

local function validate(command, value)
  assert(type(value) == "table" and value.schema_version == 1, "Unsupported schema")

  if command == "list" or command == "work" then
    assert(type(value.jobs) == "table" and vim.islist(value.jobs), "Missing jobs list")
    for _, record in ipairs(value.jobs) do job(record) end
  elseif command == "resources" then
    assert(type(value.resources) == "table" and vim.islist(value.resources), "Missing resources list")

    if value.scheduler ~= nil then
      assert(type(value.scheduler) == "table", "Invalid scheduler")

      for _, key in ipairs({ "max_concurrent_jobs", "max_memory_bytes", "max_disk_bytes",
        "running_jobs", "reserved_memory_bytes", "reserved_disk_bytes" }) do
        local count = value.scheduler[key]
        local minimum = key:match("^max_") and 1 or 0

        assert(type(count) == "number" and count >= minimum and count < math.huge and count == math.floor(count),
          "Invalid scheduler " .. key)
      end

      assert(value.scheduler.max_concurrent_jobs <= 32, "Invalid scheduler slot limit")
    end

    for _, resource in ipairs(value.resources) do
      assert(type(resource) == "table" and string(resource.id) and string(resource.backend), "Invalid resource")
      assert(type(resource.available) == "boolean" and optional_string(resource.reason), "Invalid resource availability")
      assert(type(resource.policy) == "table", "Missing resource policy")

      local policy_keys = resource.backend == "plexus-native" and { "wall_timeout_ms" }
        or { "max_memory_bytes", "max_fuel_per_case", "wall_timeout_ms" }

      for _, key in ipairs(policy_keys) do
        assert(type(resource.policy[key]) == "number" and resource.policy[key] > 0, "Invalid resource policy " .. key)
      end
    end
  else
    job(value.job)
  end
end

-- Nexus owns placement and lifecycle. Closing the view never kills its worker.
function M.request(config, arguments, callback)
  local command = config.command or { "nexus" }

  if type(command) ~= "table" or not vim.islist(command) or #command == 0 then
    callback(nil, "nexus.command must be a nonempty argv list")
    return
  end

  local argv = vim.deepcopy(command)

  for _, value in ipairs(argv) do
    if not string(value) then callback(nil, "nexus.command entries must be nonempty strings"); return end
  end

  vim.list_extend(argv, arguments)
  local options = { text = true }
  if arguments[1] ~= "work" then options.timeout = config.timeout_ms or 120000 end

  local ok, err = pcall(vim.system, argv, options, function(result)
    vim.schedule(function()
      if result.code ~= 0 then
        callback(nil, vim.trim(result.stderr or "") ~= "" and vim.trim(result.stderr)
          or ("Nexus exited with code " .. tostring(result.code)))

        return
      end

      local decoded, value = pcall(vim.json.decode, result.stdout or "")
      local valid, reason = false, "Invalid JSON"
      if decoded then valid, reason = pcall(validate, arguments[1], value) end

      if not valid then
        callback(nil, "Nexus returned invalid or unsupported JSON: " .. tostring(reason))
        return
      end

      callback(value)
    end)
  end)

  if not ok then callback(nil, tostring(err)) end
end

return M
