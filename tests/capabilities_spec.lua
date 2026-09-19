vim.opt.runtimepath:prepend(vim.fn.getcwd())
local bridge = require("oculus.capabilities")
local directory = vim.fn.tempname()
vim.fn.mkdir(directory, "p")
local source = directory .. "/extract.rs"
vim.fn.writefile({ "fn normalize() {", "    match kind {}", "}" }, source)
local file = assert(io.open(source, "rb"))
local digest = "sha256:" .. vim.fn.sha256(file:read("*a"))
file:close()
local original_system, original_notify = vim.system, vim.notify
local calls, errors = {}, {}
vim.notify = function(message) errors[#errors + 1] = message end

vim.system = function(argv, opts, callback)
  local call = { argv = argv, opts = opts, callback = callback }
  calls[#calls + 1] = call
  return { kill = function(_, signal) call.killed = signal end }
end

local function respond(call, value)
  local complete = false
  call.callback({ code = 0, stdout = vim.json.encode(value), stderr = "" })
  vim.schedule(function() complete = true end)
  assert(vim.wait(1000, function() return complete end))
end

local location = { path = source, line = 2, column = 5, digest = digest, artifact = digest }

local report = {
  schema_version = 1, kind = "rust_capability_delta", report_id = "sha256:report", rule_version = "enum-rule/1",
  producer = { project = "wit-parser", before_revision = "v1", after_revision = "v2",
    before_snapshot = "sha256:before", after_snapshot = "sha256:after" },
  consumer = { project = "plexus", source = location },
  deltas = { { path = "wit_parser::TypeDefKind::FixedLengthList", kind = "added" } },
  opportunities = { { id = "gap", kind = "missing_match_arm", status = "inferred",
    title = "Represent fixed-size lists", explanation = "A parser variant reaches a rejecting consumer match.",
    consumer_location = location,
    evidence_path = { { relation = "consumes", description = "Consumer match", source = location } },
    limitations = { "Syntactic match; no whole-program proof." },
    validation = { kind = "plexus_wit_fixture", label = "Extract a fixed-size list WIT fixture" } } },
  limitations = { "Compiler facts are scoped to the captured configuration." },
}

local source_win = vim.api.nvim_get_current_win()
local original_buf = vim.api.nvim_get_current_buf()
vim.api.nvim_buf_set_lines(original_buf, 0, -1, false, { "unsaved user work" })
local config = { command = { "/path with spaces/plexus" }, store = directory .. "/store", backend = "zug" }
local state = bridge.open(config, directory .. "/manifest; $(touch nope).json")
assert(state.source_win == source_win and vim.api.nvim_win_get_buf(source_win) == original_buf)
assert(vim.api.nvim_win_get_config(state.win).relative == "", "must be a normal source-adjacent split")
assert(#calls == 1 and #calls[1].argv == 4 and calls[1].argv[2] == "rust-discover", "no backend flag or auto execution")
assert(calls[1].argv[3]:find("$(touch nope)", 1, true))
respond(calls[1], report)
assert(not state.busy and #calls == 1)
local initial_lines = table.concat(vim.api.nvim_buf_get_lines(state.buf, 0, -1, false), "\n")
local opportunity_section = assert(initial_lines:find("OPPORTUNITIES ·", 1, true))
local provenance_section = assert(initial_lines:find("PROVENANCE", 1, true))
local deltas_section = assert(initial_lines:find("ALL API DELTAS", 1, true))

assert(opportunity_section < provenance_section and provenance_section < deltas_section,
  "Actionable opportunities must precede long provenance and the full API delta listing")

assert(initial_lines:find("Report: " .. report.report_id, 1, true) > provenance_section)
assert(initial_lines:find("Snapshots: sha256:before", 1, true) > provenance_section)
assert(initial_lines:find("wit-parser → plexus", 1, true) < opportunity_section)
local row
for line, opportunity in pairs(state.targets) do if opportunity.id == "gap" then row = line; break end end
assert(row)
vim.api.nvim_win_set_cursor(state.win, { row, 0 })
state.navigate()
assert(state.error:find("unsaved changes", 1, true))
assert(vim.api.nvim_win_get_buf(source_win) == original_buf)
vim.bo[original_buf].modified = false
state.navigate()
assert(vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(source_win)) == source)
assert(vim.deep_equal(vim.api.nvim_win_get_cursor(source_win), { 2, 4 }))
local source_buf = vim.api.nvim_win_get_buf(source_win)
vim.api.nvim_buf_set_lines(source_buf, 0, 1, false, { "// changed buffer" })
state.navigate(report.opportunities[1])
assert(state.error:find("unsaved changes", 1, true))
vim.bo[source_buf].modified = false
vim.fn.writefile({ "// changed on disk" }, source)
state.navigate(report.opportunities[1])
assert(state.error:find("Stale source", 1, true))
assert(vim.api.nvim_win_get_buf(source_win) == source_buf)
vim.api.nvim_set_current_win(state.win)
state.validate(report.opportunities[1])
assert(#calls == 2 and #calls[2].argv == 5 and calls[2].argv[2] == "rust-validate")
assert(calls[2].argv[3] == report.report_id and calls[2].argv[4] == "gap")

respond(calls[2], { schema_version = 1, validation_id = "sha256:validation", report_id = report.report_id,
  opportunity_id = "gap", status = "reproduced_gap", diagnostic = "fixed-size lists are unsupported" })

assert(state.report.opportunities[1].status == "inferred")
local lines = table.concat(vim.api.nvim_buf_get_lines(state.buf, 0, -1, false), "\n")
assert(lines:find("Fixture result: reproduced_gap", 1, true))
assert(lines:find("opportunity remains inferred", 1, true))
state.refresh()
state.cancel()
assert(calls[3].killed == 15)
local wrong = vim.deepcopy(report)
wrong.report_id = "sha256:cancelled"
respond(calls[3], wrong)
assert(state.report.report_id == report.report_id)
state.refresh()
respond(calls[4], { schema_version = 1, kind = "wrong" })
assert(state.report.report_id == report.report_id and state.error:find("Invalid capability report", 1, true))
state.refresh()
state.close()
assert(calls[5].killed == 15 and state.closed)
respond(calls[5], wrong)
assert(state.report.report_id == report.report_id)
assert(vim.api.nvim_win_is_valid(source_win) and vim.api.nvim_win_get_buf(source_win) == source_buf)
-- Both existing dashboards expose discovery and return to the original source.
local oculus = require("oculus")
oculus.config.plexus = vim.deepcopy(config)
oculus.config.plexus.backend = "wasmtime"
local original_input = vim.ui.input
vim.ui.input = function(_, callback) callback(directory .. "/discovery.json") end
local window = require("oculus.window")
window.open({ projects = {}, contributors = {}, width = 0.8, height = 0.8 })
local open_discovery

for _, mapping in ipairs(vim.api.nvim_buf_get_keymap(window.state.buf, "n")) do
  if mapping.lhs == "C" then open_discovery = mapping.callback end
end

assert(open_discovery, "Oculus start screen must expose capability discovery")
open_discovery()
assert(not window.state.win and bridge.state.source_win == source_win)
assert(calls[#calls].argv[2] == "rust-discover")
bridge.state.close()
local investigation = oculus.open_plexus(directory .. "/hypothesis.json")
local discover_from_investigation

for _, mapping in ipairs(vim.api.nvim_buf_get_keymap(investigation.buf, "n")) do
  if mapping.lhs == "D" then discover_from_investigation = mapping.callback end
end

assert(discover_from_investigation, "Plexus dashboard must expose capability discovery")
discover_from_investigation()
assert(investigation.closed and bridge.state.source_win == source_win)
assert(calls[#calls].argv[2] == "rust-discover")
bridge.state.close()
vim.ui.input = original_input
vim.system, vim.notify = original_system, original_notify
vim.fn.delete(directory, "rf")
assert(#errors == 4, vim.inspect(errors))
print("Capabilities source navigation, scoped validation, and lifecycle passed")
