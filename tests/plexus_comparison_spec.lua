vim.opt.runtimepath:prepend(vim.fn.getcwd())
local bridge = require("oculus.plexus")
local directory = vim.fn.tempname()
vim.fn.mkdir(directory, "p")
local original_system, original_notify, original_input = vim.system, vim.notify, vim.ui.input
local calls, errors, prompts = {}, {}, {}
vim.notify = function(message) errors[#errors + 1] = message end
vim.ui.input = function(options, callback) prompts[#prompts + 1] = { options = options, callback = callback } end

vim.system = function(argv, _, callback)
  local call = { argv = argv, callback = callback }
  calls[#calls + 1] = call
  return { kill = function(_, signal) call.killed = signal end }
end

local function respond(call, value)
  local completed = false
  call.callback({ code = 0, stdout = vim.json.encode(value), stderr = "" })
  vim.schedule(function() completed = true end)
  assert(vim.wait(1000, function() return completed end))
end

local function id(character) return "sha256:" .. character:rep(64) end
local left, right = id("a"), id("b")

local view = {
  schema_version = 1, hypothesis_id = id("d"), question = "Keep the investigation",
  analysis = { subject = {}, providers = {} }, bindings = {},
  evidence = { { attachment = { obligation = "bytes/cases", run = left },
    freshness = "current", conclusion = "contradicted_by_case" } },
}

local report = {
  schema_version = 1, kind = "runtime_comparison", comparison_id = id("c"),
  left_run = left, right_run = right,
  left_runtime = { backend = "wasmtime", version = "48.0.2" },
  right_runtime = { backend = "zug", version = "test" },
  left_conclusion = "contradicted_by_case", right_conclusion = "contradicted_by_case",
  status = "agreement_for_cases",
  cases = { { name = "sum four bytes", status = "agreement", expected = { 10 }, left_values = { 9 }, right_values = { 9 } } },
  limitations = { "Agreement does not prove the expected result.", "Identical archived inputs only." },
}

local linked = vim.deepcopy(report)
linked.kind, linked.left_link, linked.right_link = "composition_runtime_comparison", "satisfied", "inconclusive"
local comparison = require("oculus.plexus.comparison")
local linked_lines = table.concat(comparison.lines(linked, left, right), "\n")
assert(linked_lines:find("Link obligation: satisfied", 1, true) and linked_lines:find("Link obligation: inconclusive", 1, true))
linked.right_link = "verified"
assert(not pcall(comparison.lines, linked, left, right))
local config = { command = { "/path with spaces/plexus" }, store = directory, backend = "zug", zug_command = "/tmp/zug" }
local state = bridge.open(config, directory .. "/hypothesis.json")
respond(calls[1], view)
local investigation = vim.api.nvim_buf_get_lines(state.buf, 0, -1, false)
local compare_key

for _, mapping in ipairs(vim.api.nvim_buf_get_keymap(state.buf, "n")) do
  if mapping.lhs == "d" then compare_key = mapping.callback end
end

assert(compare_key, "comparison must be accessible from the investigation")
assert(table.concat(vim.api.nvim_buf_get_lines(state.footer_buf, 0, -1, false), "\n"):find("d compare", 1, true))
compare_key()
assert(prompts[1].options.default == left)
prompts[1].callback(left)
prompts[2].callback(" " .. right .. " ")

assert(vim.deep_equal(calls[2].argv, { config.command[1], "compare-runs", left, right, vim.fn.fnamemodify(directory, ":p") }),
  "compare must pass explicit IDs and store without execution backend flags")

respond(calls[2], report)
assert(state.comparison.comparison_id == report.comparison_id and not state.busy)
assert(vim.deep_equal(investigation, vim.api.nvim_buf_get_lines(state.buf, 0, -1, false)))
local comparison_win = state.raw_win
local rendered = table.concat(vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(comparison_win), 0, -1, false), "\n")

for _, expected in ipairs({ "agreement_for_cases", "wasmtime 48.0.2", "zug test", "Individual conclusion: contradicted_by_case",
  "both runtimes may agree on a wrong result", "sum four bytes", "Expected: [10]", "Left: [9]", "Right: [9]", report.limitations[1] }) do
  assert(rendered:find(expected, 1, true), "missing comparison detail: " .. expected)
end

assert(not vim.api.nvim_win_get_config(comparison_win).title)
assert(not vim.api.nvim_win_get_config(comparison_win).footer)
local inspect_json

for _, mapping in ipairs(vim.api.nvim_buf_get_keymap(vim.api.nvim_win_get_buf(comparison_win), "n")) do
  if mapping.lhs == "J" then inspect_json = mapping.callback end
end

assert(inspect_json)
inspect_json()
assert(vim.bo[vim.api.nvim_win_get_buf(state.raw_win)].filetype == "json")
local raw = vim.json.decode(table.concat(vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(state.raw_win), 0, -1, false), "\n"))
assert(raw.comparison_id == report.comparison_id)

local malformed = {
  function(value) value.left_run = right end,
  function(value) value.kind = "other" end,
  function(value) value.comparison_id = "not-an-artifact" end,
  function(value) value.status = "verified_composition" end,
  function(value) value.left_runtime = vim.NIL end,
  function(value) value.right_conclusion = "verified" end,
  function(value) value.cases = { invalid = true } end,
  function(value) value.cases[1].status = "verified" end,
  function(value) value.cases[1].left_values = { "9" } end,
  function(value) value.cases[1].right_values = { 2147483648 } end,
  function(value) value.limitations = { 5 } end,
}

for _, mutate in ipairs(malformed) do
  local invalid = vim.deepcopy(report)
  mutate(invalid)
  local old_window = state.raw_win
  state.compare(left, right)
  respond(calls[#calls], invalid)
  assert(state.error:find("Invalid comparison response", 1, true))
  assert(state.raw_win == old_window and vim.api.nvim_win_is_valid(old_window), "malformed response must preserve prior report")
  assert(state.comparison.comparison_id == report.comparison_id)
end

local count = #calls
state.compare("bad", right)
assert(#calls == count and state.error:find("two sha256", 1, true))
state.compare(left, right)
local cancelled = calls[#calls]
state.cancel()
assert(cancelled.killed == 15)
state.compare(left, right)
local divergence = vim.deepcopy(report)
divergence.comparison_id = id("e")
divergence.status, divergence.cases[1].status = "divergence", "divergence"
divergence.cases[1].right_values = { 10 }
respond(calls[#calls], divergence)
respond(cancelled, report)
assert(state.comparison.comparison_id == divergence.comparison_id, "late cancelled callback must not replace newer comparison")
local inconclusive = vim.deepcopy(report)
inconclusive.status, inconclusive.cases[1].status = "inconclusive", "inconclusive"
inconclusive.cases[1].right_values = vim.NIL
inconclusive.right_conclusion = "unsupported"
state.compare(left, right)
respond(calls[#calls], inconclusive)
rendered = table.concat(vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(state.raw_win), 0, -1, false), "\n")
assert(rendered:find("Right: unavailable", 1, true) and rendered:find("Individual conclusion: unsupported", 1, true))
compare_key()
prompts[#prompts].callback(left)
local stale_prompt = prompts[#prompts]
state.refresh()
respond(calls[#calls], view)
count = #calls
stale_prompt.callback(right)
assert(#calls == count, "input started before a new request must not submit a comparison")
state.compare(left, right)
local closing = calls[#calls]
state.close()
assert(closing.killed == 15)
respond(closing, divergence)
assert(state.closed and not vim.api.nvim_win_is_valid(state.raw_win))
assert(state.comparison.comparison_id == report.comparison_id)
vim.system, vim.notify, vim.ui.input = original_system, original_notify, original_input
vim.fn.delete(vim.fn.stdpath("state") .. "/oculus-plexus/" .. vim.fn.sha256(vim.fn.fnamemodify(config.store, ":p")) .. ".json")
vim.fn.delete(directory, "rf")
print("Plexus runtime comparison UI and lifecycle passed")
