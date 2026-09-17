local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)
local oculus = require("oculus")
local health = require("oculus.health")

-- Runs a check with vim.health captured, returning the report as a list of
-- { level, message } pairs.
local function report(config)
  local original = vim.health
  local entries = {}

  local function record(level)
    return function(message, advice)
      entries[#entries + 1] = {
        level = level,
        message = message,
        advice = advice,
      }
    end
  end

  vim.health = {
    start = record("start"),
    ok = record("ok"),
    warn = record("warn"),
    error = record("error"),
    info = record("info"),
  }

  local original_config = oculus.config
  oculus.config = config
  local ran, err = pcall(health.check)
  oculus.config = original_config
  vim.health = original
  assert(ran, err)
  return entries
end

local function find(entries, pattern)
  for _, entry in ipairs(entries) do
    if type(entry.message) == "string" and entry.message:find(pattern) then
      return entry
    end
  end
end

local function sections(entries)
  local names = {}

  for _, entry in ipairs(entries) do
    if entry.level == "start" then
      names[#names + 1] = entry.message
    end
  end

  return names
end

-- Every section reports, whatever the configuration.
do
  local entries = report({})

  assert(vim.deep_equal(sections(entries), {
    "Neovim",
    "Required tools",
    "Authentication",
    "Inspecting changes",
    "Tracking file",
    "Optional plugins",
    "AI integration",
    "Telemetry",
  }), vim.inspect(sections(entries)))

  assert(find(entries, "^Neovim %d"), vim.inspect(entries))
  assert(find(entries, "^curl"), "curl is reported")
  assert(find(entries, "^git"), "git is reported")
end

-- Telemetry is off by default, and says so plainly.
do
  local entries = report({})
  local telemetry = assert(find(entries, "nothing is ever sent to the author"))
  assert(telemetry.level == "ok", telemetry.level)
end

-- Telemetry on with nowhere to export to is a warning, not silence.
do
  local endpoint = vim.env.OTEL_EXPORTER_OTLP_TRACES_ENDPOINT
  local fallback = vim.env.OTEL_EXPORTER_OTLP_ENDPOINT
  vim.env.OTEL_EXPORTER_OTLP_TRACES_ENDPOINT = nil
  vim.env.OTEL_EXPORTER_OTLP_ENDPOINT = nil
  local entries = report({ telemetry = { enabled = true } })
  local warning = assert(find(entries, "no endpoint is configured"))
  assert(warning.level == "warn", warning.level)
  assert(warning.advice[1]:find("telemetry.endpoint", 1, true))

  local exported = report({
    telemetry = { enabled = true, endpoint = "http://localhost:4318/v1/traces" },
  })

  assert(find(exported, "http://localhost:4318/v1/traces").level == "ok")

  local custom = report({
    telemetry = { enabled = true, exporter = function() end },
  })

  assert(find(custom, "your own exporter function").level == "ok")
  vim.env.OTEL_EXPORTER_OTLP_TRACES_ENDPOINT = endpoint
  vim.env.OTEL_EXPORTER_OTLP_ENDPOINT = fallback
end

-- Search paths that do not exist are the most common "it can't find my clone".
do
  local entries = report({
    inspect_search_paths = { root, "/nonexistent/oculus/search/path" },
  })

  local warning = assert(find(entries, "search paths that do not exist"))
  assert(warning.level == "warn", warning.level)
  assert(warning.message:find("/nonexistent/oculus/search/path", 1, true))
  local present = report({ inspect_search_paths = { root } })
  assert(find(present, "1 search path%(s%), all present"))
  local none = report({ inspect_search_paths = {} })
  assert(find(none, "No inspect_search_paths set"))
end

-- A tracking file that is missing, unreadable, or fine.
do
  local missing = report({ tracking_file = "/nonexistent/oculus/tracking.json" })
  local warning = assert(find(missing, "tracking_file does not exist"))
  assert(warning.level == "warn", warning.level)
  local path = vim.fn.tempname() .. ".json"
  local invalid_path = vim.fn.tempname() .. ".json"
  local invalid = assert(io.open(invalid_path, "w"))
  invalid:write("{ not json")
  invalid:close()

  vim.fn.writefile({
    '{ "version": 1, "projects": [',
    '  { "repository": "neovim/neovim", "provider": "github" }',
    '], "users": [{ "username": "folke", "provider": "github" }] }',
  }, path)

  local loaded = report({ tracking_file = path })
  local entry = assert(find(loaded, "1 project%(s%), 1 user%(s%)"))
  assert(entry.level == "ok", entry.level)
  local broken = report({ tracking_file = invalid_path })
  local failure = assert(find(broken, "Cannot load tracking file"))
  assert(failure.level == "error", failure.level)
  assert(failure.advice[1]:find("oculus-tracking-file", 1, true))
  os.remove(path)
  os.remove(invalid_path)
end

print("health_spec: ok")
