vim.opt.runtimepath:prepend(vim.fn.getcwd())
local bridge = require("oculus.plexus")
local client = require("oculus.plexus.client")
local directory = vim.fn.tempname()
vim.fn.mkdir(directory, "p")
local original_system, original_notify = vim.system, vim.notify
local calls, errors = {}, {}
vim.notify = function(message) errors[#errors + 1] = message end

vim.system = function(argv, opts, callback)
  local call = { argv = argv, opts = opts, callback = callback }
  calls[#calls + 1] = call
  return { kill = function(_, signal) call.killed = signal end }
end

local function respond(call, value, code, stderr)
  local completed = false
  call.callback({ code = code or 0, stdout = type(value) == "string" and value or vim.json.encode(value), stderr = stderr })
  vim.schedule(function() completed = true end)
  assert(vim.wait(1000, function() return completed end))
end

local ref = { world = { project = "consumer", world = "world" }, item = "increment" }

local view = {
  schema_version = 1, hypothesis_id = "sha256:first", parent = vim.NIL, question = "Does this work?",
  analysis = { hypothetical = true, subject = { status = "declaration_reachable",
    requirements = { { evidence = ref, selected = vim.NIL, candidates = {} } } }, providers = {} },
  bindings = { { id = "increment", requirement = ref, provider = ref, ["function"] = vim.NIL,
    relevance_path = { ref }, plan = "sha256:plan", mapping = { kind = "direct_s32" },
    mapping_check = "scalar_shape_checked", implementation_conformance = "unresolved",
    cases_obligation = "increment/cases", build = { kind = "observed_wat_normalization", project = "provider",
      source = "sha256:source", module = "sha256:module" },
    runtime = { backend = "wasmtime", version = "48.0.2" }, tested_export = "increment" } },
  composition_execution = "unresolved", uncovered_requirements = {},
  evidence = { { attachment = { obligation = "removed/cases", run = "sha256:old" },
    freshness = "stale", reason = "binding removed", conclusion = "supported_for_cases" } },
}

local config = { command = { "/path with spaces/plexus", "--wrapper-option" }, store = directory .. "/store with spaces" }
local state = bridge.open(config, directory .. "/manifest; $(touch nope).json")
assert(state.busy and #calls == 1)
assert(calls[1].argv[1] == config.command[1] and calls[1].argv[3] == "hypothesize")
assert(calls[1].argv[4]:find("$(touch nope)", 1, true))
assert(calls[1].opts.text and calls[1].opts.timeout == 120000)
respond(calls[1], view)
assert(not state.busy and state.view.hypothesis_id == view.hypothesis_id)
local rendered = table.concat(vim.api.nvim_buf_get_lines(state.buf, 0, -1, false), "\n")
assert(rendered:find("Selected: unresolved", 1, true))
assert(rendered:find("Pinned runtime: wasmtime 48.0.2", 1, true))
assert(rendered:find("removed/cases · stale", 1, true))
assert(not vim.api.nvim_win_get_config(state.win).title)
assert(not vim.api.nvim_win_get_config(state.win).footer)
assert(vim.api.nvim_win_get_config(state.footer_win).relative == "win")
local inspect_json

for _, mapping in ipairs(vim.api.nvim_buf_get_keymap(state.buf, "n")) do
  assert(mapping.lhs ~= "j" and mapping.lhs ~= "k", "preserve cursor navigation")
  if mapping.lhs == "J" then inspect_json = mapping.callback end
end

assert(inspect_json)
inspect_json()
assert(vim.api.nvim_win_is_valid(state.raw_win))
assert(vim.bo[vim.api.nvim_win_get_buf(state.raw_win)].filetype == "json")
vim.api.nvim_win_close(state.raw_win, true)
state.run(view.bindings[1])
assert(calls[2].argv[3] == "run" and calls[2].argv[4] == "sha256:plan")
local next_view = vim.deepcopy(view)
next_view.hypothesis_id = "sha256:attached"
respond(calls[2], { run_id = "sha256:run", record = { schema_version = 1, conclusion = "inconclusive" } })
assert(calls[3].argv[3] == "attach")

assert(calls[3].argv[4] == view.hypothesis_id and calls[3].argv[5] == "increment/cases"
  and calls[3].argv[6] == "sha256:run")

respond(calls[3], next_view)
assert(state.view.hypothesis_id == "sha256:attached")
state.revise()
assert(calls[4].argv[3] == "revise" and calls[4].argv[4] == "sha256:attached")
respond(calls[4], "", 1, "manifest missing")
assert(state.error == "manifest missing" and state.view.hypothesis_id == "sha256:attached")
state.refresh()
state.cancel()
assert(calls[5].killed == 15 and not state.busy)
respond(calls[5], view)
assert(state.view.hypothesis_id == "sha256:attached", "cancelled callback must be ignored")
state.refresh()
respond(calls[6], "not JSON")
assert(state.error:find("invalid or unsupported JSON", 1, true))
state.refresh()
respond(calls[7], { schema_version = 1, hypothesis_id = "invalid" })
assert(state.view.hypothesis_id == "sha256:attached", "malformed view must preserve previous display")
state.refresh()
state.close()
assert(calls[8].killed == 15)
respond(calls[8], view)
assert(state.closed and not vim.api.nvim_win_is_valid(state.win))
local reopened = bridge.open(config)
assert(calls[9].argv[3] == "hypothesis" and calls[9].argv[4] == "sha256:attached")
respond(calls[9], next_view)
assert(reopened.manifest:find("$(touch nope)", 1, true))
reopened.close()
local completed

client.request({ command = { "plexus" }, backend = "zug", zug_command = "/tmp/zug runtime" },
  { "run", "sha256:plan", directory }, function(value, err) completed = value or err end)

assert(vim.deep_equal(vim.list_slice(calls[10].argv, 5), { "--backend", "zug", "--zug-command", "/tmp/zug runtime" }))
respond(calls[10], { run_id = "run", record = { schema_version = 1 } })
assert(completed.run_id == "run")
client.request({ backend = "zug", zug_command = "relative" }, { "run" }, function(_, err) completed = err end)
assert(type(completed) == "string" and completed:find("absolute", 1, true))
vim.system = function() error("missing executable") end
client.request({}, { "history" }, function(_, err) completed = err end)
assert(completed:find("missing executable", 1, true))
vim.system, vim.notify = original_system, original_notify
assert(#errors == 3)
vim.fn.delete(vim.fn.stdpath("state") .. "/oculus-plexus/" .. vim.fn.sha256(vim.fn.fnamemodify(config.store, ":p")) .. ".json")
vim.fn.delete(directory, "rf")
print("Plexus UI lifecycle and process contract passed")
