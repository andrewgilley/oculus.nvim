local M = {}
local scope_name = "oculus.nvim"
local scope_version = "0.1.0"
local id_counter = 0

local function config()
  local loaded = package.loaded.oculus

  if type(loaded) == "table"
    and type(loaded.config) == "table"
    and type(loaded.config.telemetry) == "table"
  then
    return loaded.config.telemetry
  end

  local ok, oculus = pcall(require, "oculus")

  if ok and type(oculus.config.telemetry) == "table" then
    return oculus.config.telemetry
  end

  return {}
end

local function report_error(cfg, message)
  if type(cfg.on_error) == "function" then
    vim.schedule(function()
      pcall(cfg.on_error, tostring(message))
    end)
  end
end

local function unix_nano()
  local seconds, microseconds = vim.uv.gettimeofday()
  return ("%d%06d000"):format(seconds, microseconds)
end

local function random_hex(bytes)
  local ok, value = pcall(vim.uv.random, bytes)

  if ok and type(value) == "string" and #value == bytes then
    return (value:gsub(".", function(character)
      return ("%02x"):format(character:byte())
    end))
  end

  id_counter = id_counter + 1

  local seed = table.concat({
    unix_nano(),
    tostring(vim.uv.hrtime()),
    tostring(vim.fn.getpid()),
    tostring(id_counter),
  }, ":")

  return vim.fn.sha256(seed):sub(1, bytes * 2)
end

local function attribute_value(value)
  local value_type = type(value)

  if value_type == "string" then
    return { stringValue = value }
  elseif value_type == "boolean" then
    return { boolValue = value }
  elseif value_type == "number" then
    if value == math.floor(value) then
      return { intValue = tostring(value) }
    end

    return { doubleValue = value }
  elseif value_type == "table" and vim.islist(value) then
    local values = {}

    for _, item in ipairs(value) do
      local encoded = attribute_value(item)

      if encoded then
        values[#values + 1] = encoded
      end
    end

    return { arrayValue = { values = values } }
  end
end

local function attributes(values)
  local result = {}

  for key, value in pairs(values or {}) do
    local encoded = attribute_value(value)

    if type(key) == "string" and encoded then
      result[#result + 1] = { key = key, value = encoded }
    end
  end

  table.sort(result, function(left, right)
    return left.key < right.key
  end)

  return result
end

local function merged(left, right)
  local result = vim.deepcopy(left or {})

  for key, value in pairs(right or {}) do
    if value ~= nil then
      result[key] = value
    end
  end

  return result
end

local function endpoint(cfg)
  if type(cfg.endpoint) == "string" and cfg.endpoint ~= "" then
    return cfg.endpoint
  end

  local traces_endpoint = vim.env.OTEL_EXPORTER_OTLP_TRACES_ENDPOINT

  if type(traces_endpoint) == "string" and traces_endpoint ~= "" then
    return traces_endpoint
  end

  local base = vim.env.OTEL_EXPORTER_OTLP_ENDPOINT

  if type(base) ~= "string" or base == "" then
    return nil
  end

  return base:gsub("/+$", "") .. "/v1/traces"
end

local function environment_headers(cfg)
  local result = {}
  local encoded = vim.env.OTEL_EXPORTER_OTLP_HEADERS

  for entry in tostring(encoded or ""):gmatch("[^,]+") do
    local key, value = entry:match("^%s*([^=]+)=(.*)%s*$")

    if key and value then
      result[vim.trim(key)] = vim.trim(value)
    end
  end

  for key, value in pairs(cfg.headers or {}) do
    result[tostring(key)] = tostring(value)
  end

  return result
end

local function resource_attributes(cfg)
  return merged({
    ["service.name"] = cfg.service_name or scope_name,
    ["service.version"] = cfg.service_version or scope_version,
    ["deployment.environment.name"] = cfg.environment
      or vim.env.OTEL_SERVICE_ENVIRONMENT
      or "dev",
  }, cfg.resource_attributes)
end

function M._build_payload(span, cfg)
  cfg = cfg or config()

  local otlp_span = {
    traceId = span.trace_id,
    spanId = span.span_id,
    parentSpanId = span.parent_span_id,
    name = span.name,
    kind = 1,
    startTimeUnixNano = span.start_time_unix_nano,
    endTimeUnixNano = span.end_time_unix_nano,
    attributes = attributes(span.attributes),
    status = span.error_type and {
      code = 2,
      message = span.error_type,
    } or { code = 1 },
  }

  if not otlp_span.parentSpanId then
    otlp_span.parentSpanId = nil
  end

  return {
    resourceSpans = {
      {
        resource = {
          attributes = attributes(resource_attributes(cfg)),
        },
        scopeSpans = {
          {
            scope = {
              name = scope_name,
              version = scope_version,
            },
            spans = { otlp_span },
          },
        },
      },
    },
  }
end

local function export_http(payload, cfg)
  local target = endpoint(cfg)

  if not target then
    report_error(
      cfg,
      "telemetry is enabled but no OTLP traces endpoint is configured"
    )

    return
  end

  local executable = vim.fn.exepath("curl")

  if executable == "" then
    report_error(cfg, "curl is required for the OTLP/HTTP exporter")
    return
  end

  local command = {
    executable,
    "--silent",
    "--show-error",
    "--fail",
    "--max-time",
    tostring(math.max(1, tonumber(cfg.timeout) or 5)),
    "--request",
    "POST",
    "--header",
    "Content-Type: application/json",
  }

  for key, value in pairs(environment_headers(cfg)) do
    command[#command + 1] = "--header"
    command[#command + 1] = key .. ": " .. value
  end

  vim.list_extend(command, {
    "--data-binary",
    "@-",
    target,
  })

  local ok, process = pcall(vim.system, command, {
    stdin = vim.json.encode(payload),
    text = true,
  }, function(result)
    if result.code ~= 0 then
      local message = vim.trim(result.stderr or "")

      report_error(
        cfg,
        message ~= "" and message
          or "OTLP/HTTP export failed with code " .. tostring(result.code)
      )
    end
  end)

  if not ok then
    report_error(cfg, process)
  end
end

local function export(span, cfg)
  local payload = M._build_payload(span, cfg)

  if type(cfg.exporter) == "function" then
    local exported_span = vim.deepcopy(span)

    vim.schedule(function()
      local ok, err = pcall(cfg.exporter, payload, exported_span)

      if not ok then
        report_error(cfg, err)
      end
    end)

    return
  end

  export_http(payload, cfg)
end

function M.enabled()
  return config().enabled == true
end

function M.start(name, span_attributes, parent)
  local cfg = config()

  if cfg.enabled ~= true then
    return nil
  end

  parent = type(parent) == "table" and parent or {}

  local parent_trace_id = type(parent.trace_id) == "string"
      and parent.trace_id:match("^%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x$")
    and parent.trace_id
    or nil

  local parent_span_id = type(parent.span_id) == "string"
      and parent.span_id:match("^%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x$")
    and parent.span_id
    or nil

  return {
    name = name,
    trace_id = parent_trace_id or random_hex(16),
    span_id = random_hex(8),
    parent_span_id = parent_trace_id and parent_span_id or nil,
    start_time_unix_nano = unix_nano(),
    attributes = vim.deepcopy(span_attributes or {}),
  }
end

function M.context(span)
  if type(span) ~= "table" then
    return nil
  end

  return {
    trace_id = span.trace_id,
    span_id = span.span_id,
  }
end

function M.finish(span, finish_attributes, error_type)
  if type(span) ~= "table" or span.finished then
    return M.context(span)
  end

  span.finished = true
  span.end_time_unix_nano = unix_nano()
  span.attributes = merged(span.attributes, finish_attributes)
  span.error_type = error_type
  export(span, config())
  return M.context(span)
end

function M.record(name, span_attributes, parent, error_type)
  local span = M.start(name, span_attributes, parent)
  return M.finish(span, nil, error_type)
end

return M
