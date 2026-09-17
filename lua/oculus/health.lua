-- :checkhealth oculus — what Oculus needs, what it can use, and what it found
-- of your configuration, so a report answers "why doesn't it work" on its own.
local M = {}
local minimum_version = { major = 0, minor = 10 }

local function health()
  return vim.health or require("health")
end

local function start(name)
  health().start(name)
end

local function ok(message)
  health().ok(message)
end

local function warn(message, advice)
  health().warn(message, advice)
end

local function error_(message, advice)
  health().error(message, advice)
end

local function info(message)
  health().info(message)
end

local function executable(name)
  return vim.fn.executable(name) == 1
end

-- The first line of `<command> --version`, for the report.
local function version_of(command)
  local result = vim.system({ command, "--version" }, { text = true }):wait()

  if result.code ~= 0 then
    return nil
  end

  local first = vim.split(result.stdout or "", "\n", { plain = true })[1]
  return first and vim.trim(first) ~= "" and vim.trim(first) or nil
end

local function has_plugin(module)
  return pcall(require, module)
end

local function check_neovim()
  start("Neovim")
  local version = vim.version()

  local supported = version.major > minimum_version.major
    or (
      version.major == minimum_version.major
      and version.minor >= minimum_version.minor
    )

  local text = ("Neovim %d.%d.%d"):format(
    version.major,
    version.minor,
    version.patch
  )

  if supported then
    ok(text)
  else
    error_(
      ("%s is older than the required %d.%d"):format(
        text,
        minimum_version.major,
        minimum_version.minor
      ),
      { "Upgrade Neovim to 0.10 or newer." }
    )
  end
end

local function check_required()
  start("Required tools")

  for _, tool in ipairs({
    {
      name = "curl",
      used_for = "the GitHub and Codeberg APIs",
      advice = "Install curl and make sure it is on your PATH.",
    },
    {
      name = "git",
      used_for = "inspecting changes",
      advice = "Install git and make sure it is on your PATH.",
    },
  }) do
    if executable(tool.name) then
      ok(("%s: %s"):format(tool.name, version_of(tool.name) or "found"))
    else
      error_(
        ("%s is not on your PATH, and is needed for %s"):format(
          tool.name,
          tool.used_for
        ),
        { tool.advice }
      )
    end
  end
end

-- A forge is usable without a token, but rate-limited, so a missing one is a
-- warning rather than an error.
local function check_authentication(config)
  start("Authentication")
  local auth = require("oculus.auth")

  local sources = {
    option = "the token in your setup() options",
    env = "an environment variable",
    gh = "the gh CLI",
  }

  for _, forge in ipairs({
    { provider = "github", label = "GitHub" },
    { provider = "codeberg", label = "Codeberg" },
  }) do
    local token, source = auth.token(forge.provider, config)

    if token then
      ok(("%s: token from %s"):format(
        forge.label,
        sources[source] or tostring(source)
      ))
    else
      warn(
        ("%s: no token, so requests are rate-limited"):format(forge.label),
        { auth.sign_in_hint(forge.provider) }
      )
    end
  end

  if executable("gh") then
    ok("gh: " .. (version_of("gh") or "found"))
  else
    info("gh is not installed; tokens come from your options or environment")
  end
end

local function check_optional_plugins()
  start("Optional plugins")

  for _, plugin in ipairs({
    {
      module = "oil",
      name = "oil.nvim",
      used_for = "browsing an inspection as a directory listing",
    },
    {
      module = "treesitter-context",
      name = "nvim-treesitter-context",
      used_for = "context lines kept in sync across inspect windows",
    },
  }) do
    if has_plugin(plugin.module) then
      ok(("%s is installed"):format(plugin.name))
    else
      info(("%s is not installed (%s)"):format(plugin.name, plugin.used_for))
    end
  end
end

local function check_agents()
  start("AI integration")
  local available = false

  if executable("codex") then
    ok("codex: " .. (version_of("codex") or "found"))
    available = true
  else
    info("codex is not installed")
  end

  local gemini_key = vim.env.GEMINI_API_KEY or vim.env.GOOGLE_API_KEY

  if executable("agy") then
    if gemini_key and gemini_key ~= "" then
      ok("agy: " .. (version_of("agy") or "found") .. ", with an API key")
      available = true
    else
      warn(
        "agy is installed, but neither GEMINI_API_KEY nor GOOGLE_API_KEY is set",
        { "Set one of them to list Gemini models." }
      )
    end
  else
    info("agy is not installed")
  end

  if not available then
    info(
      "The overview's describe and patch-location commands need codex or agy;"
        .. " everything else works without them"
    )
  end
end

local function check_paths(config)
  start("Inspecting changes")
  local repositories = config.inspect_repositories or {}
  local missing = {}

  for _, path in ipairs(config.inspect_search_paths or {}) do
    if vim.fn.isdirectory(vim.fn.expand(path)) ~= 1 then
      missing[#missing + 1] = path
    end
  end

  if vim.tbl_count(repositories) > 0 then
    ok(("%d repository path(s) configured"):format(vim.tbl_count(repositories)))
  end

  if #(config.inspect_search_paths or {}) == 0 then
    info(
      "No inspect_search_paths set; clones are found in the current directory"
        .. " or under inspect_discovery_roots"
    )
  elseif #missing == 0 then
    ok(("%d search path(s), all present"):format(#config.inspect_search_paths))
  else
    warn(
      ("search paths that do not exist: %s"):format(table.concat(missing, ", ")),
      { "Remove them from inspect_search_paths, or create them." }
    )
  end

  for _, root in ipairs(config.inspect_discovery_roots or {}) do
    if vim.fn.isdirectory(vim.fn.expand(root)) ~= 1 then
      warn(("discovery root does not exist: %s"):format(root))
    end
  end
end

local function check_tracking(config)
  start("Tracking file")
  local path = config.tracking_file

  if not path then
    info("No tracking_file configured; lists come from your setup() options")
    return
  end

  local expanded = vim.fn.expand(path)

  if vim.uv.fs_stat(expanded) == nil then
    warn(
      ("tracking_file does not exist: %s"):format(expanded),
      { "Create the file; Oculus never writes it with defaults." }
    )

    return
  end

  local tracking = require("oculus.tracking")
  local probe = { tracking_file = expanded }
  local loaded, err = tracking.load(probe)

  if loaded then
    local tree = probe._tracking.tree or {}

    ok(("%s: %d project(s), %d user(s)"):format(
      expanded,
      #(tree.projects or {}),
      #(tree.users or {})
    ))
  else
    error_(tostring(err), { "See :h oculus-tracking-file for the format." })
  end
end

local function check_telemetry(config)
  start("Telemetry")
  local telemetry = config.telemetry or {}

  if not telemetry.enabled then
    ok("off (nothing is exported, and nothing is ever sent to the author)")
    return
  end

  local endpoint = telemetry.endpoint
    or vim.env.OTEL_EXPORTER_OTLP_TRACES_ENDPOINT
    or vim.env.OTEL_EXPORTER_OTLP_ENDPOINT

  if telemetry.exporter then
    ok("on, exported by your own exporter function")
  elseif endpoint then
    ok(("on, exported to %s"):format(endpoint))
  else
    warn(
      "on, but no endpoint is configured, so spans go nowhere",
      {
        "Set telemetry.endpoint, or OTEL_EXPORTER_OTLP_TRACES_ENDPOINT.",
      }
    )
  end
end

function M.check()
  local oculus = require("oculus")
  local config = oculus.config or {}
  check_neovim()
  check_required()
  check_authentication(config)
  check_paths(config)
  check_tracking(config)
  check_optional_plugins()
  check_agents()
  check_telemetry(config)
end

return M
