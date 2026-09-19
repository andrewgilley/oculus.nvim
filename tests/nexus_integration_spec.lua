vim.opt.runtimepath:prepend(vim.fn.getcwd())
local root = vim.fn.fnamemodify(vim.fn.getcwd(), ":h")
local binary = vim.env.PLEXUS_BIN or root .. "/plexus/target/debug/plexus"
local worker = vim.env.PLEXUS_ZUG_WORKER or root .. "/zug/zig-out/bin/zug-plexus"
local launcher = vim.env.NEXUS_SCRIPT or root .. "/nexus/nexus.py"
assert(vim.fn.executable(binary) == 1 and vim.fn.executable(worker) == 1, "Build Plexus and Zug first")
local directory = vim.fn.tempname()
vim.fn.mkdir(directory, "p")
local nexus_dir, store = directory .. "/nexus", directory .. "/artifacts"

local config = {
  schema_version = 1, plexus_command = { binary },
  resources = { { id = "local-wasmtime", backend = "wasmtime" },
    { id = "local-zug", backend = "zug", zug_command = worker } },
}

vim.fn.writefile({ vim.json.encode(config) }, directory .. "/resources.json")
local configured = vim.system({ "python3", launcher, "configure", directory .. "/resources.json", nexus_dir }, { text = true }):wait()
assert(configured.code == 0, configured.stderr)
local oculus = require("oculus")
oculus.config.nexus = { command = { "python3", launcher }, state_dir = nexus_dir }
oculus.config.plexus = { command = { binary }, store = store }
local jobs_view

local function key(state, lhs)
  for _, mapping in ipairs(vim.api.nvim_buf_get_keymap(state.buf, "n")) do
    if mapping.lhs == lhs then mapping.callback(); return end
  end

  error("Missing mapping " .. lhs)
end

for index, backend in ipairs({ "wasmtime", "zug" }) do
  oculus.config.plexus.backend = backend
  oculus.config.plexus.zug_command = worker
  local investigation = oculus.open_plexus(root .. "/plexus/fixtures/fixed-length-lists/adapter/hypothesis.json")
  assert(vim.wait(15000, function() return not investigation.busy end))
  assert(not investigation.error, investigation.error)

  for row in pairs(investigation.targets) do
    vim.api.nvim_win_set_cursor(investigation.win, { row, 0 })
    break
  end

  key(investigation, "n")
  jobs_view = require("oculus.nexus").state
  assert(vim.wait(15000, function() return jobs_view.error or (not jobs_view.busy and #jobs_view.jobs == index) end))
  assert(not jobs_view.error, jobs_view.error)
  assert(jobs_view.last_job.state == "queued" and jobs_view.last_job.resource_id == "local-" .. backend)
  if index == 1 then jobs_view.close() end
end

key(jobs_view, "s")
assert(vim.wait(15000, function() return jobs_view.error or jobs_view.resources end))
assert(not jobs_view.error, jobs_view.error)
assert(#jobs_view.resources == 2 and jobs_view.resources[1].available and jobs_view.resources[2].available)
key(jobs_view, "g")
key(jobs_view, "w")

assert(vim.wait(30000, function()
  if jobs_view.error then return true end
  if jobs_view.working or #jobs_view.jobs ~= 2 then return false end
  return jobs_view.jobs[1].state == "succeeded" and jobs_view.jobs[2].state == "succeeded"
end))

assert(not jobs_view.error, jobs_view.error)
local zug_job

for _, job in ipairs(jobs_view.jobs) do
  assert(job.conclusion == "supported_for_cases" and type(job.result_hypothesis_id) == "string")
  assert(job.artifact_store == vim.fn.fnamemodify(store, ":p"):gsub("/$", ""))
  if job.resource_id == "local-zug" then zug_job = job end
end

assert(zug_job)
local rendered = table.concat(vim.api.nvim_buf_get_lines(jobs_view.buf, 0, -1, false), "\n")
assert(rendered:find("Evidence conclusion: supported_for_cases", 1, true))

for row, job in pairs(jobs_view.targets) do
  if job.id == zug_job.id then vim.api.nvim_win_set_cursor(jobs_view.win, { row, 0 }); break end
end

key(jobs_view, "o")
local evidence = require("oculus.plexus").state
assert(jobs_view.closed and vim.wait(15000, function() return not evidence.busy end))
assert(not evidence.error, evidence.error)
assert(evidence.view.hypothesis_id == zug_job.result_hypothesis_id)
assert(evidence.view.composition_execution == "unresolved")
assert(evidence.view.evidence[1].attachment.run == zug_job.run_id)
assert(evidence.view.evidence[1].conclusion == "supported_for_cases")
evidence.close()
vim.fn.delete(vim.fn.stdpath("state") .. "/oculus-plexus/" .. vim.fn.sha256(vim.fn.fnamemodify(store, ":p")) .. ".json")
vim.fn.delete(directory, "rf")
print("Real Oculus → Nexus placement → Plexus → Wasmtime/Zug → attached Oculus evidence passed")
