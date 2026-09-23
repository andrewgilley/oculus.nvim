vim.opt.runtimepath:prepend(vim.fn.getcwd())
local bridge = require("oculus.nexus")
local directory = vim.fn.tempname()
local original_system, original_notify = vim.system, vim.notify
local calls, errors = {}, {}
vim.notify = function(message) errors[#errors + 1] = message end

vim.system = function(argv, options, callback)
  local call = { argv = argv, options = options, callback = callback }
  calls[#calls + 1] = call
  return { kill = function(_, signal) call.killed = signal end }
end

local function respond(call, value, code)
  local completed = false
  call.callback({ code = code or 0, stdout = type(value) == "string" and value or vim.json.encode(value), stderr = code and value or "" })
  vim.schedule(function() completed = true end)
  assert(vim.wait(1000, function() return completed end))
end

local function job(state)
  return {
    id = "job-1", state = state or "queued", resource_id = "local-zug", hypothesis_id = "sha256:original",
    binding_id = "sum", plan_id = "sha256:plan", artifact_store = "/a store/plexus",
  }
end

local config = { command = { "/a path/nexus" }, state_dir = directory }
local state_dir = vim.fn.fnamemodify(directory, ":p")

local state = bridge.open(config, { command = { "/a path/plexus" } }, {
  hypothesis_id = "sha256:original", binding_id = "sum", artifact_store = "/a store/plexus",
})

assert(vim.deep_equal(calls[1].argv, { "/a path/nexus", "submit", "sha256:original", "sum", "/a store/plexus", state_dir }))
respond(calls[1], { schema_version = 1, job = job() })
assert(vim.deep_equal(calls[2].argv, { "/a path/nexus", "list", state_dir }))
respond(calls[2], { schema_version = 1, jobs = { job() } })
local rendered = table.concat(vim.api.nvim_buf_get_lines(state.buf, 0, -1, false), "\n")
assert(rendered:find("job-1 · queued · local-zug", 1, true))
assert(not vim.api.nvim_win_get_config(state.win).title and not vim.api.nvim_win_get_config(state.win).footer)
local bindings = {}
for _, mapping in ipairs(vim.api.nvim_buf_get_keymap(state.buf, "n")) do bindings[mapping.lhs] = mapping.callback end
assert(bindings.w and bindings.c and bindings.R and bindings.o and bindings.s and bindings.g)
assert(not bindings.j and not bindings.k, "preserve cursor navigation")
state.work()
local worker = calls[#calls]
assert(worker.argv[2] == "work" and worker.options.timeout == nil, "Nexus owns execution timeouts")
local count = #calls
state.work()
assert(#calls == count, "only one work request per view")
state.cancel(job("running"))
local cancellation = calls[#calls]
assert(cancellation.argv[2] == "cancel", "cancellation must be available while worker is pending")
respond(cancellation, { schema_version = 1, job = job("cancelled") })
respond(calls[#calls], { schema_version = 1, jobs = { job("cancelled") } })
respond(worker, { schema_version = 1, jobs = { job("cancelled") } })
respond(calls[#calls], { schema_version = 1, jobs = { job("cancelled") } })
assert(not state.working and state.jobs[1].state == "cancelled")
state.retry(job("cancelled"))
local retried = job()
retried.id, retried.retry_of = "job-2", "job-1"
respond(calls[#calls], { schema_version = 1, job = retried })
respond(calls[#calls], { schema_version = 1, jobs = { job("cancelled"), retried } })
assert(state.last_job.retry_of == "job-1" and #state.jobs == 2)
rendered = table.concat(vim.api.nvim_buf_get_lines(state.buf, 0, -1, false), "\n")
assert(rendered:find("Queue: 1 queued · 0 running", 1, true))
assert(rendered:find("Finished: 0 succeeded · 0 failed · 1 cancelled · 0 interrupted", 1, true))
state.refresh("jobs")
local old_read = calls[#calls]
state.refresh("resources")

respond(calls[#calls], { schema_version = 1, resources = {
  { id = "local-zug", backend = "zug", available = false, reason = "Worker missing",
    policy = { max_memory_bytes = 65536, max_fuel_per_case = 1000, wall_timeout_ms = 3000 } },
} })

respond(old_read, { schema_version = 1, jobs = {} })
assert(state.mode == "resources" and #state.jobs == 2, "stale reads must not overwrite a newer view")
rendered = table.concat(vim.api.nvim_buf_get_lines(state.buf, 0, -1, false), "\n")
assert(rendered:find("unavailable", 1, true) and rendered:find("Worker missing", 1, true))
assert(rendered:find("Guest linear memory bytes: 65536", 1, true))
state.refresh("resources")

local resource_response = {
  schema_version = 1, resources = {}, total_execution_slots = 3,
  scheduler = { max_concurrent_jobs = 3, max_memory_bytes = 131072, max_disk_bytes = 268435456,
    running_jobs = 2, reserved_memory_bytes = 65536, reserved_disk_bytes = 4096 },
}

respond(calls[#calls], resource_response)
rendered = table.concat(vim.api.nvim_buf_get_lines(state.buf, 0, -1, false), "\n")
assert(rendered:find("Shared slots: 2/3", 1, true))
assert(rendered:find("Reserved guest memory bytes: 65536/131072", 1, true))
assert(rendered:find("Reserved declared disk bytes: 4096/268435456", 1, true))
assert(rendered:find("host RSS is unmeasured", 1, true))

for _, invalid in ipairs({ -1, 1.5, "2", false }) do
  local response = vim.deepcopy(resource_response)
  response.scheduler.running_jobs = invalid
  state.refresh("resources")
  respond(calls[#calls], response)
  assert(state.error:find("invalid or unsupported JSON", 1, true))
  assert(state.scheduler.running_jobs == 2, "invalid counts must not replace the last valid snapshot")
end

state.refresh("resources")
respond(calls[#calls], { schema_version = 1, resources = {} })
assert(state.scheduler == nil, "older Nexus responses must clear stale reservation counts")

for _, invalid in ipairs({
  { schema_version = 2, jobs = {} }, { schema_version = 1, jobs = { job("invented") } },
  { schema_version = 1, jobs = { { id = "missing-fields", state = "queued" } } },
  "not JSON",
}) do
  state.refresh("jobs")
  respond(calls[#calls], invalid)
  assert(state.error:find("invalid or unsupported JSON", 1, true) and #state.jobs == 2)
end

state.refresh()
respond(calls[#calls], "Nexus deployment unavailable", 1)
assert(state.error == "Nexus deployment unavailable")
state.work()
local closing_work = calls[#calls]
state.refresh()
local closing_read = calls[#calls]
state.close()
assert(not closing_work.killed and not closing_read.killed, "closing UI must not kill Nexus processes")
respond(closing_read, { schema_version = 1, jobs = {} })
count = #calls
respond(closing_work, { schema_version = 1, jobs = {} })
assert(#calls == count and #state.jobs == 2, "closed view ignores late callbacks")
local original_plexus = package.loaded["oculus.plexus"]
local opened
package.loaded["oculus.plexus"] = { open = function(...) opened = { ... } end }
state = bridge.open(config, { command = { "/a path/plexus" }, store = "/wrong/store" })
respond(calls[#calls], { schema_version = 1, jobs = {} })
local done = job("succeeded")
done.result_hypothesis_id = "sha256:evidence"
state.open_result(done)
assert(state.closed and opened[1].store == done.artifact_store and opened[3] == done.result_hypothesis_id)
assert(opened[1].command[1] == "/a path/plexus")
package.loaded["oculus.plexus"] = original_plexus
local oculus = require("oculus")
assert(vim.deep_equal(oculus.config.nexus.command, { "nexus" }))
assert(oculus.config.nexus.state_dir == vim.fn.stdpath("data") .. "/oculus/nexus")
oculus.config.nexus = config
vim.cmd.runtime("plugin/oculus.lua")
vim.cmd.OculusNexus()
assert(vim.deep_equal(calls[#calls].argv, { "/a path/nexus", "list", state_dir }))
respond(calls[#calls], { schema_version = 1, jobs = {} })
bridge.state.close()
local client = require("oculus.nexus.client")

for _, command in ipairs({ {}, { "" }, "nexus", { "nexus", false } }) do
  count = #calls
  local err
  client.request({ command = command }, { "list", directory }, function(_, error) err = error end)
  assert(err and #calls == count)
end

vim.system = function() error("Executable unavailable") end
local launch_error
client.request(config, { "list", directory }, function(_, err) launch_error = err end)
assert(launch_error:find("Executable unavailable", 1, true))
vim.system, vim.notify = original_system, original_notify
print("Nexus UI submission, resources, cancellation, evidence and callback lifecycle passed")
