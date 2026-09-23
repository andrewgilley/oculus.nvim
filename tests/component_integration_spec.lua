vim.opt.runtimepath:prepend(vim.fn.getcwd())
local root = vim.fn.fnamemodify(vim.fn.getcwd(), ":h")
local binary = vim.env.PLEXUS_BIN or root .. "/plexus/target/debug/plexus"
local worker = vim.env.PLEXUS_ZUG_WORKER or root .. "/zug/zig-out/bin/zug-plexus"
local launcher = vim.env.NEXUS_SCRIPT or root .. "/nexus/nexus.py"
assert(vim.fn.executable(binary) == 1 and vim.fn.executable(worker) == 1, "Build Plexus and Zug first")
local directory = vim.fn.tempname()
vim.fn.mkdir(directory .. "/sources", "p")
local fixture = root .. "/plexus/fixtures/fixed-length-lists/component/"

local profiles = { { "checksum.wat", "cases.json", "checksum" }, { "checksum-list.wat", "list-cases.json", "checksum" },
  { "scan.wat", "scan-cases.json", "scan" }, { "summarize.wat", "summarize-cases.json", "summarize" } }

for _, profile in ipairs(profiles) do
  for index = 1, 2 do vim.fn.writefile(vim.fn.readfile(fixture .. profile[index], "b"), directory .. "/sources/" .. profile[index], "b") end
end

local wrong = vim.json.decode(table.concat(vim.fn.readfile(fixture .. "cases.json"), "\n"))
wrong[1].expected = wrong[1].expected + 1
vim.fn.writefile({ vim.json.encode(wrong) }, directory .. "/sources/wrong-cases.json")
profiles[5] = { "checksum.wat", "wrong-cases.json", "checksum" }
local store, nexus_dir = directory .. "/store", directory .. "/nexus"

local resources = { schema_version = 1, plexus_command = { binary }, resources = {
  { id = "local-wasmtime", backend = "wasmtime" }, { id = "local-zug", backend = "zug", zug_command = worker },
} }

vim.fn.writefile({ vim.json.encode(resources) }, directory .. "/resources.json")
local result = vim.system({ "python3", launcher, "configure", directory .. "/resources.json", nexus_dir }, { text = true }):wait()
assert(result.code == 0, result.stderr)
local oculus = require("oculus")
oculus.config.nexus = { command = { "python3", launcher }, state_dir = nexus_dir }
oculus.config.plexus = { command = { binary }, store = store, zug_command = worker }
vim.cmd.runtime("plugin/oculus.lua")
local jobs, plans, count = nil, {}, 0

local function ready(state)
  assert(vim.wait(30000, function() return not state.busy end), "Component view request timed out")
  assert(not state.error, state.error)
end

for profile_index, profile in ipairs(profiles) do
  plans[profile_index] = {}

  for _, backend in ipairs({ "wasmtime", "zug" }) do
    count = count + 1
    oculus.config.plexus.backend, oculus.config.plexus.component_export = backend, profile[3]
    vim.cmd.OculusComponent({ args = { directory .. "/sources/" .. profile[1], directory .. "/sources/" .. profile[2] } })
    local state = require("oculus.components").state
    ready(state)
    assert(state.view.export == profile[3] and state.view.runtime.backend == backend)
    assert(state.view.properties.instance_lifecycle == "fresh_per_case" and not state.view.properties.retained_state)
    assert(state.view.limits.fuel_per_case == 100000 and state.view.limits.memory_bytes == 65536)
    assert(state.view.case_count > 0)
    plans[profile_index][backend] = state.view.plan_id
    state.submit()
    jobs = require("oculus.nexus").state
    assert(vim.wait(30000, function() return jobs.error or (not jobs.busy and #jobs.jobs == count) end))
    assert(not jobs.error, jobs.error)
    assert(jobs.last_job.kind == "component_reference" and jobs.last_job.resource_id == "local-" .. backend)
    for _, job in ipairs(jobs.jobs) do assert(job.state == "queued" and job.run_id == vim.NIL, "Queuing must not execute") end
    if count < 10 then jobs.close() end
  end
end

vim.fn.delete(directory .. "/sources", "rf")
jobs.work()

assert(vim.wait(90000, function()
  if jobs.error then return true end
  if jobs.working then return false end
  for _, job in ipairs(jobs.jobs) do if job.state ~= "succeeded" then return false end end
  return true
end), "Component queue did not complete")

assert(not jobs.error, jobs.error)
local by_plan = {}
for _, job in ipairs(jobs.jobs) do by_plan[job.plan_id] = job end
local comparisons = {}

for profile_index, pair in ipairs(plans) do
  local left, right = by_plan[pair.wasmtime], by_plan[pair.zug]
  local expected = profile_index == 5 and "contradicted_by_case" or "supported_for_cases"
  assert(left.conclusion == expected and right.conclusion == expected)
  if not jobs.closed then jobs.open_result(right) else oculus.open_component({ run_id = right.run_id }) end
  local state = require("oculus.components").state
  ready(state)
  assert(state.run.record.plan == pair.zug and state.run.record.conclusion == expected)
  local rendered = table.concat(vim.api.nvim_buf_get_lines(state.buf, 0, -1, false), "\n")
  assert(rendered:find("Expected:", 1, true) and rendered:find("Observed:", 1, true))
  state.compare(left.run_id, right.run_id)
  ready(state)
  assert(state.comparison.record.conclusion == "agreement_for_cases")
  comparisons[profile_index] = state.comparison.comparison_id
  rendered = table.concat(vim.api.nvim_buf_get_lines(state.buf, 0, -1, false), "\n")
  assert(rendered:find("Left case conclusion: " .. expected, 1, true))
  assert(rendered:find("Right case conclusion: " .. expected, 1, true))
  state.close()
end

local state = oculus.open_component({ comparison_id = comparisons[5] })
ready(state)
assert(state.comparison.comparison_id == comparisons[5])
state.history()
ready(state)
assert(#state.history_value.plans == 10 and #state.history_value.runs == 10 and #state.history_value.comparisons == 5)
local comparison_row

for row, target in pairs(state.targets) do
  if target.comparison_id == comparisons[5] then comparison_row = row end
end

assert(comparison_row)
vim.api.nvim_win_set_cursor(state.win, { comparison_row, 0 })
state.navigate()
ready(state)
assert(state.comparison.comparison_id == comparisons[5])
state.load_plan(plans[4].wasmtime)
ready(state)
assert(state.view.export == "summarize")
local source_row
for row, target in pairs(state.targets) do if target.path == "component.wat" then source_row = row end end
assert(source_row)
vim.api.nvim_win_set_cursor(state.win, { source_row, 0 })
state.navigate()
ready(state)
local source_buf = vim.api.nvim_get_current_buf()
assert(vim.b[source_buf].oculus_archived_source == state.view.source and vim.bo[source_buf].readonly)
vim.api.nvim_win_close(vim.api.nvim_get_current_win(), true)
state.close()
vim.fn.delete(directory, "rf")
print("Real Oculus → Nexus queued components: all four profiles on both runtimes, contradictions vs agreement, archived inputs and persisted comparisons passed")
