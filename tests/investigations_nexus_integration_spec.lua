-- Optional: PLEXUS_INVESTIGATION_FIXTURE names a descriptor with store and
-- investigation_id from an existing supported real Git capture.
if not vim.env.PLEXUS_INVESTIGATION_FIXTURE then
  print("SKIP native investigation loop: set PLEXUS_INVESTIGATION_FIXTURE to a captured investigation descriptor")
  return
end

vim.opt.runtimepath:prepend(vim.fn.getcwd())
local root = vim.fn.fnamemodify(vim.fn.getcwd(), ":h")
local binary = vim.env.PLEXUS_BIN or root .. "/plexus/target/debug/plexus"
local launcher = vim.env.NEXUS_SCRIPT or root .. "/nexus/nexus.py"
local fixture = vim.json.decode(table.concat(vim.fn.readfile(vim.env.PLEXUS_INVESTIGATION_FIXTURE), "\n"))
assert(type(fixture.store) == "string" and type(fixture.investigation_id) == "string", "Invalid investigation descriptor")
assert(vim.fn.executable(binary) == 1, "Build Plexus first")
local directory = vim.fn.tempname()
vim.fn.mkdir(directory, "p")
local resources = { schema_version = 1, plexus_command = { binary }, resources = { { id = "local-native", backend = "plexus-native" } } }
vim.fn.writefile({ vim.json.encode(resources) }, directory .. "/resources.json")
local configured = vim.system({ "python3", launcher, "configure", directory .. "/resources.json", directory .. "/nexus" }, { text = true }):wait()
assert(configured.code == 0, configured.stderr)
local oculus = require("oculus")
oculus.config.plexus = { command = { binary }, store = fixture.store }
oculus.config.nexus = { command = { "python3", launcher }, state_dir = directory .. "/nexus" }

local function key(state, lhs)
  for _, mapping in ipairs(vim.api.nvim_buf_get_keymap(state.buf, "n")) do
    if mapping.lhs == lhs then mapping.callback(); return end
  end

  error("Missing mapping " .. lhs)
end

local state = oculus.open_investigations(fixture.investigation_id)
assert(vim.wait(10000, function() return not state.busy end))
assert(not state.error, state.error)
assert(state.view.status == "completed" and #state.view.experiments > 0, "Fixture must offer a supported experiment")
local selected

for row, target in pairs(state.targets) do
  if target.experiment then
    selected = target
    vim.api.nvim_win_set_cursor(state.win, { row, 0 })
    break
  end
end

assert(selected)
key(state, "n")
local nexus = require("oculus.nexus").state
assert(vim.wait(15000, function() return nexus.error or (not nexus.busy and #nexus.jobs == 1) end))
assert(not nexus.error, nexus.error)
assert(nexus.last_job.kind == "discovery_validation" and nexus.last_job.resource_id == "local-native")
assert(nexus.last_job.state == "queued")
key(nexus, "w")
assert(vim.wait(15000, function() return nexus.error or (not nexus.working and nexus.jobs[1].state == "succeeded") end))
assert(not nexus.error, nexus.error)
local job = nexus.jobs[1]
assert(job.state == "succeeded" and job.conclusion == "reproduced_gap", vim.inspect(job))
assert(job.result_investigation_id == fixture.investigation_id and type(job.run_id) == "string")

for row, item in pairs(nexus.targets) do
  if item.id == job.id then vim.api.nvim_win_set_cursor(nexus.win, { row, 0 }); break end
end

key(nexus, "o")
state = require("oculus.investigations").state
assert(nexus.closed and vim.wait(10000, function() return not state.busy end))
assert(not state.error, state.error)
assert(state.view.investigation_id == fixture.investigation_id)
local evidence

for _, item in ipairs(state.view.evidence) do
  if item.opportunity_id == selected.opportunity.id and item.plan_id == job.plan_id then evidence = item; break end
end

assert(evidence and evidence.status == "reproduced_gap", vim.inspect(state.view.evidence))
assert(evidence.runtime.backend == "plexus-native")

for _, report in ipairs(state.view.reports) do
  for _, finding in ipairs(report.opportunities) do
    if finding.id == selected.opportunity.id then assert(finding.status == "inferred") end
  end
end

local rendered = table.concat(vim.api.nvim_buf_get_lines(state.buf, 0, -1, false), "\n")
assert(rendered:find("Evidence: reproduced_gap", 1, true) and rendered:find("relationship remains inferred", 1, true))
state.close()
vim.fn.delete(directory, "rf")
print("Real Oculus finding → Nexus native placement → Plexus fixture → durable inferred investigation evidence passed")
