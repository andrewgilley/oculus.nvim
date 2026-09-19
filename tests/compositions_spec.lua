vim.opt.runtimepath:prepend(vim.fn.getcwd())
local bridge = require("oculus.compositions")
local directory = vim.fn.tempname()
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

local plan = {
  plan_id = "sha256:plan", question = "Does the linked consumer work?", entry = { part = "consumer", export = "run" },
  plan = { schema_version = 1, runtime = { backend = "zug", version = "test" },
    parts = { { name = "provider", role = "provider", project = "test", module = "sha256:module", source = "sha256:source" } },
    connections = { { importer = "consumer", module = "provider", name = "run", status = "satisfied",
      expected = { params = { "i32" } }, provided = { params = { "i32" } } } } },
  cases = { { name = "one", arguments = { 1 }, expected = { 2 } } },
  link = { status = "declared_satisfied" }, blockers = {},
}

local run = { run_id = "sha256:run", record = { schema_version = 1, plan = plan.plan_id, question = plan.question,
  runtime = plan.plan.runtime, link = { status = "satisfied" }, conclusion = "contradicted_by_case", blockers = {},
  cases = { { expected = { 2 }, verdict = "mismatches", observation = { name = "one", outcome = { kind = "returned", values = { 3 } } } } } } }

local config = { command = { "/a path/plexus" }, backend = "zug", zug_command = "/a path/zug", store = directory }
local nexus = { command = { "nexus" }, state_dir = directory .. "/nexus" }
local state = bridge.open(config, nexus, "/a path/manifest.json")
assert(vim.deep_equal(calls[#calls].argv, { "/a path/plexus", "compose", "/a path/manifest.json", vim.fn.fnamemodify(directory, ":p"), "--backend", "zug", "--zug-command", "/a path/zug" }))
respond(plan)
assert(calls[#calls].argv[2] == "composition-runs")
respond({ schema_version = 1, runs = { run } })
assert(not state.error, state.error)
local lines = table.concat(vim.api.nvim_buf_get_lines(state.buf, 0, -1, false), "\n")

for _, value in ipairs({ "provider", "consumer → provider", "Expected: [2]", "contradicted_by_case", "Runtime links: satisfied", "General behavior remains unverified" }) do
  assert(lines:find(value, 1, true), value)
end

local opened
local original_nexus = package.loaded["oculus.nexus"]
package.loaded["oculus.nexus"] = { open = function(...) opened = { ... } end }
state.submit()
assert(state.closed and opened[3].kind == "composition" and opened[3].plan_id == plan.plan_id)
package.loaded["oculus.nexus"] = original_nexus
state = bridge.open(config, nexus)
assert(calls[#calls].argv[2] == "composition" and calls[#calls].argv[3] == plan.plan_id, "Remember archived plan per store")
respond(plan)
respond({ schema_version = 1, runs = {} })
state.history()
respond({ schema_version = 1, runs = { run } })
local count = #calls
state.submit()
assert(not state.closed and #calls == count, "History cannot queue a stale plan")
vim.api.nvim_win_set_cursor(state.win, { 5, 0 })
state.navigate()
respond(plan)
respond({ schema_version = 1, runs = { run } })
state.view.blockers = { "unsupported import" }
state.submit()
assert(not state.closed, "Blocked plans cannot be queued")
state.view.blockers = {}
state.load("sha256:bad")
respond({ schema_version = 1, plan_id = "sha256:bad" })
assert(state.error and state.view.plan_id == plan.plan_id)
state.load(plan.plan_id)
local pending = calls[#calls]
state.close()
assert(pending.killed == 15)
respond(plan, pending)
assert(state.closed)

local native = { schema_version = 1, plan_id = "sha256:native", native_kind = "c_zig_composition", investigation_id = "sha256:investigation",
  opportunity_id = "finding", runtime = { backend = "plexus-native", version = "test" }, composition = { parts = {}, connections = {}, cases = {}, obligations = { "behavior remains scoped" } } }

state = bridge.open(config, nexus, "/native.json", { native = true, investigation_id = native.investigation_id, opportunity_id = "different" })
respond(native)
assert(state.error:find("different opportunity_id", 1, true), "Do not queue another finding's plan")
state.close()
state = bridge.open(config, nexus, "/native.json", { native = true, investigation_id = native.investigation_id, opportunity_id = "finding" })
assert(calls[#calls].argv[2] == "c-zig-compose" and #calls[#calls].argv == 4, "Native plans do not inherit Wasm backend flags")
respond(native)
assert(not state.error, state.error)
package.loaded["oculus.nexus"] = { open = function(...) opened = { ... } end }
state.submit()
assert(opened[3].kind == "investigation_plan")
package.loaded["oculus.nexus"] = original_nexus
vim.fn.delete(vim.fn.stdpath("state") .. "/oculus-composition/" .. vim.fn.sha256(vim.fn.fnamemodify(directory, ":p")) .. ".json")
vim.system, vim.notify = original_system, original_notify
print("Composition rendering, scoped evidence, archived history, Nexus queue, native finding identity and cancellation passed")
