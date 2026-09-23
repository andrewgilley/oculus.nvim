vim.opt.runtimepath:prepend(vim.fn.getcwd())
local bridge = require("oculus.components")
local original_system, original_notify = vim.system, vim.notify
local calls = {}
vim.notify = function() end

vim.system = function(argv, options, callback)
  local call = { argv = argv, options = options, callback = callback }
  calls[#calls + 1] = call
  return { kill = function(_, signal) call.killed = signal end }
end

local function respond(value, call)
  call = call or calls[#calls]
  call.callback({ code = 0, stdout = vim.json.encode(value), stderr = "" })
  local complete = false
  vim.schedule(function() complete = true end)
  assert(vim.wait(1000, function() return complete end))
end

local plan = { schema_version = 1, kind = "component_reference", plan_id = "sha256:plan", profile = "plexus-component-checksum/4",
  source = "sha256:source", component = "sha256:component", wit = "sha256:wit", export = "summarize",
  runtime = { backend = "zug", version = "test" }, limits = { fuel_per_case = 100000, memory_bytes = 65536 }, memory_count = 2,
  properties = { instance_lifecycle = "fresh_per_case", retained_state = false, granted_host_imports = {} },
  cases = { { name = "text", value = "héllo", expected = { bytes = 6 } } }, blockers = {}, scope = "Selected typed cases only" }

local run = { run_id = "sha256:run", record = { schema_version = 2, plan = plan.plan_id, profile = plan.profile,
  source = plan.source, component = plan.component, wit = plan.wit, export = plan.export, runtime = plan.runtime,
  fuel_per_case = 100000, memory_bytes = 65536, host_grants = {}, host_trace = {}, conclusion = "contradicted_by_case",
  cases = { { case = plan.cases[1], outcome = { status = "returned", value = { bytes = 5 } } } }, scope = plan.scope } }

local comparison = { comparison_id = "sha256:comparison", record = { schema_version = 1, left_run = run.run_id,
  right_run = "sha256:other", conclusion = "agreement_for_cases", cases = { "agreement" }, scope = "Only selected cases" } }

local config = { command = { "/a path/plexus" }, backend = "zug", zug_command = "/a path/zug", store = "/tmp/component-store", component_export = "summarize" }
local state = bridge.open(config, {}, { source = "/a path/component.wat", cases = "/a path/cases.json" })

assert(vim.deep_equal(calls[#calls].argv, { "/a path/plexus", "component-plan", "/a path/component.wat", "/a path/cases.json",
  vim.fn.fnamemodify(config.store, ":p"), "--component-export", "summarize", "--backend", "zug", "--zug-command", "/a path/zug" }))

respond(plan)
assert(not state.error, state.error)
local function rendered() return table.concat(vim.api.nvim_buf_get_lines(state.buf, 0, -1, false), "\n") end
assert(rendered():find("héllo", 1, true) and rendered():find("fresh_per_case", 1, true))
assert(rendered():find("Selected typed cases only", 1, true))
assert(#calls == 1, "Preparation never executes cases")
local opened
local original_nexus = package.loaded["oculus.nexus"]
package.loaded["oculus.nexus"] = { open = function(...) opened = { ... } end }
state.submit()
assert(state.closed and opened[3].kind == "component_reference" and opened[3].plan_id == plan.plan_id)
package.loaded["oculus.nexus"] = original_nexus
state = bridge.open(config, {})
assert(calls[#calls].argv[2] == "component-history")
respond({ schema_version = 1, plans = { plan }, runs = { run }, comparisons = { comparison } })
local count = #calls
state.submit()
assert(not state.closed and #calls == count, "History cannot queue stale plans")
state.load_run(run.run_id)
respond(run)
assert(not state.error, state.error)
assert(rendered():find("contradicted_by_case", 1, true) and rendered():find('Observed: {"bytes":5}', 1, true))
state.compare(run.run_id, "sha256:other")
respond(comparison)
respond(run)
local other = vim.deepcopy(run)
other.run_id, other.record.runtime.backend = "sha256:other", "wasmtime"
respond(other)
assert(not state.error, state.error)
assert(rendered():find("Runtime agreement: agreement_for_cases", 1, true))
assert(rendered():find("Left case conclusion: contradicted_by_case", 1, true))
assert(rendered():find("Right case conclusion: contradicted_by_case", 1, true))
state.load_comparison(comparison.comparison_id)
assert(calls[#calls].argv[2] == "component-checksum-comparison")
respond(comparison)
respond(run)
respond(other)
state.load_plan(plan.plan_id)
respond(plan)
state.view.blockers = { "unsupported" }
state.submit()
assert(not state.closed)
state.load_plan("sha256:bad")
respond({ schema_version = 1, kind = "component_reference", plan_id = "sha256:bad" })
assert(state.error and state.view.plan_id == plan.plan_id)
state.load_plan(plan.plan_id)
local pending = calls[#calls]
state.close()
assert(pending.killed == 15)
respond(plan, pending)
local nexus_client = require("oculus.nexus.client")

local job = { id = "job", kind = "component_reference", state = "queued", resource_id = "local-zug", plan_id = plan.plan_id,
  artifact_store = config.store, hypothesis_id = vim.NIL, binding_id = vim.NIL, obligation_id = vim.NIL }

local accepted

nexus_client.request({ command = { "nexus" } }, { "submit-component", plan.plan_id, config.store, "/tmp/nexus" }, function(value, err)
  assert(not err, err)
  accepted = value.job
end)

respond({ schema_version = 2, job = job })
assert(accepted.kind == "component_reference")
vim.system, vim.notify = original_system, original_notify
print("Component typed plans, queued handoff, archived runs/comparisons, scientific conclusions, versioned Nexus jobs and cancellation passed")
