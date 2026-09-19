vim.opt.runtimepath:prepend(vim.fn.getcwd())
local root = vim.fn.fnamemodify(vim.fn.getcwd(), ":h")
local binary = vim.env.PLEXUS_BIN or root .. "/plexus/target/debug/plexus"
local worker = vim.env.PLEXUS_ZUG_WORKER or root .. "/zug/zig-out/bin/zug-plexus"
local launcher = vim.env.NEXUS_SCRIPT or root .. "/nexus/nexus.py"
assert(vim.fn.executable(binary) == 1 and vim.fn.executable(worker) == 1, "Build Plexus and Zug first")
local directory = vim.fn.tempname()
vim.fn.mkdir(directory .. "/sources", "p")
local source = root .. "/plexus/fixtures/compositions/checksum-link/"

for _, name in ipairs({ "composition.json", "behavior-mismatch.json", "provider.wat", "provider-xor.wat", "consumer.wat" }) do
  vim.fn.writefile(vim.fn.readfile(source .. name, "b"), directory .. "/sources/" .. name, "b")
end

local store, nexus_dir = directory .. "/store", directory .. "/nexus"

local config = { schema_version = 1, plexus_command = { binary }, resources = {
  { id = "local-wasmtime", backend = "wasmtime" }, { id = "local-zug", backend = "zug", zug_command = worker },
} }

vim.fn.writefile({ vim.json.encode(config) }, directory .. "/resources.json")
local result = vim.system({ "python3", launcher, "configure", directory .. "/resources.json", nexus_dir }, { text = true }):wait()
assert(result.code == 0, result.stderr)
local oculus = require("oculus")
oculus.config.nexus = { command = { "python3", launcher }, state_dir = nexus_dir }
oculus.config.plexus = { command = { binary }, store = store, zug_command = worker }
vim.cmd.runtime("plugin/oculus.lua")
local jobs, plans = nil, {}

for index, item in ipairs({ { "wasmtime", "composition.json" }, { "zug", "composition.json" }, { "wasmtime", "behavior-mismatch.json" } }) do
  oculus.config.plexus.backend = item[1]
  vim.cmd.OculusComposition(directory .. "/sources/" .. item[2])
  local state = require("oculus.compositions").state
  assert(vim.wait(15000, function() return not state.busy end))
  assert(not state.error, state.error)
  assert(#state.view.plan.parts == 2 and #state.view.cases == 5)
  assert(state.view.plan.runtime.backend == item[1])
  plans[index] = state.view.plan_id
  state.submit()
  jobs = require("oculus.nexus").state
  assert(vim.wait(15000, function() return jobs.error or (not jobs.busy and #jobs.jobs == index) end))
  assert(not jobs.error, jobs.error)
  assert(jobs.last_job.kind == "composition" and jobs.last_job.resource_id == "local-" .. item[1])
  if index < 3 then jobs.close() end
end

vim.fn.delete(directory .. "/sources", "rf")
jobs.work()

assert(vim.wait(45000, function()
  if jobs.error then return true end
  if jobs.working then return false end
  for _, job in ipairs(jobs.jobs) do if job.state ~= "succeeded" then return false end end
  return true
end), "Composition queue did not complete")

assert(not jobs.error, jobs.error)
local by_plan = {}
for _, job in ipairs(jobs.jobs) do by_plan[job.plan_id] = job end
assert(by_plan[plans[1]].conclusion == "supported_for_cases")
assert(by_plan[plans[2]].conclusion == "supported_for_cases")
assert(by_plan[plans[3]].conclusion == "contradicted_by_case")
jobs.open_result(by_plan[plans[3]])
local state = require("oculus.compositions").state
assert(vim.wait(10000, function() return not state.busy end))
assert(not state.error, state.error)
local rendered = table.concat(vim.api.nvim_buf_get_lines(state.buf, 0, -1, false), "\n")
assert(rendered:find("Runtime links: satisfied", 1, true))
assert(rendered:find("contradicted_by_case", 1, true) and rendered:find("mismatches", 1, true))
state.compare(by_plan[plans[1]].run_id, by_plan[plans[2]].run_id)
assert(vim.wait(10000, function() return not state.busy end))
assert(not state.error, state.error)
rendered = table.concat(vim.api.nvim_buf_get_lines(state.buf, 0, -1, false), "\n")
assert(rendered:find("agreement_for_cases", 1, true))
state.close()
state = oculus.open_composition(plans[1])
assert(vim.wait(10000, function() return not state.busy end))
assert(not state.error and state.view.plan_id == plans[1], state.error)
state.close()
vim.fn.delete(vim.fn.stdpath("state") .. "/oculus-composition/" .. vim.fn.sha256(vim.fn.fnamemodify(store, ":p")) .. ".json")
vim.fn.delete(directory, "rf")
print("Real Oculus → Nexus linked Wasmtime/Zug compositions, behavior contradiction, runtime comparison and archived reopening passed")
