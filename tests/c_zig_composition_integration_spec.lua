vim.opt.runtimepath:prepend(vim.fn.getcwd())
local root = vim.fn.fnamemodify(vim.fn.getcwd(), ":h")
local binary = vim.env.PLEXUS_BIN or root .. "/plexus/target/debug/plexus"
local zig = vim.env.PLEXUS_ZIG or vim.fn.exepath("zig")
local launcher = vim.env.NEXUS_SCRIPT or root .. "/nexus/nexus.py"
assert(vim.fn.executable(binary) == 1 and vim.fn.executable(zig) == 1, "Build Plexus and install Zig first")
local directory = vim.fn.tempname()
local producer, consumer = directory .. "/provider", directory .. "/consumer"
vim.fn.mkdir(producer, "p")
vim.fn.mkdir(consumer, "p")

local function command(argv)
  local result = vim.system(argv, { text = true }):wait()
  assert(result.code == 0, result.stderr)
  return vim.trim(result.stdout)
end

local function git(repository, args)
  return command(vim.list_extend({ "git", "-C", repository }, args))
end

local function commit(repository)
  git(repository, { "add", "." })
  git(repository, { "-c", "user.name=Oculus Fixture", "-c", "user.email=test@example.invalid", "commit", "-qm", "fixture" })
  return git(repository, { "rev-parse", "HEAD" })
end

git(producer, { "init", "--quiet" })
git(consumer, { "init", "--quiet" })
vim.fn.writefile({ "// No provider yet" }, producer .. "/api.h")
local base = commit(producer)
vim.fn.writefile({ "int transform(int value);" }, producer .. "/api.h")
vim.fn.writefile({ '#include "api.h"', "int transform(int value) { return value * 2; }" }, producer .. "/api.cpp")
local good = commit(producer)
vim.fn.writefile({ '#include "api.h"', "int transform(int value) { return value * 3; }" }, producer .. "/api.cpp")
local bad = commit(producer)
vim.fn.writefile({ "extern fn transform(value: c_int) c_int;", "pub fn main() u8 { return if (transform(7) == 14) 0 else 1; }" }, consumer .. "/main.zig")
local revision = commit(consumer)
local store, nexus_dir = directory .. "/store", directory .. "/nexus"
vim.fn.writefile({ vim.json.encode({ schema_version = 1, plexus_command = { binary }, resources = { { id = "local-native", backend = "plexus-native" } } }) }, directory .. "/resources.json")
command({ "python3", launcher, "configure", directory .. "/resources.json", nexus_dir })
local oculus = require("oculus")
oculus.config.plexus = { command = { binary }, store = store }
oculus.config.nexus = { command = { "python3", launcher }, state_dir = nexus_dir }
local plans, investigations = {}, {}
local jobs

for index, head in ipairs({ good, bad }) do
  local request = { schema_version = 1, analysis = "c_zig", intent = "Probe the C++ provider through a C ABI wrapper from Zig",
    repository = producer, base = base, head = head, producer_header = "api.h", header_language = "c++",
    consumer_repository = consumer, consumer_revision = revision, consumer_source = "main.zig" }

  local view = vim.json.decode(command({ binary, "investigate", vim.json.encode(request), store }))
  investigations[index] = view.investigation_id
  local state = oculus.open_investigations(view.investigation_id)
  assert(vim.wait(15000, function() return not state.busy end))
  assert(not state.error, state.error)
  local selected

  for row, target in pairs(state.targets) do
    if target.opportunity.kind == "requires_c_abi_wrapper" then selected = target; vim.api.nvim_win_set_cursor(state.win, { row, 0 }); break end
  end

  assert(selected, "Expected a wrapper opportunity")
  local manifest = directory .. "/composition-" .. index .. ".json"

  vim.fn.writefile({ vim.json.encode({ schema_version = 1, investigation_id = view.investigation_id, opportunity_id = selected.opportunity.id,
    producer_sources = { "api.cpp" }, zig = zig, cases = { { name = "doubles-seven", arguments = {}, expected_stdout = "", expected_exit = 0 } } }) }, manifest)

  state.compose(selected, manifest)
  local composition = require("oculus.compositions").state
  assert(vim.wait(60000, function() return not composition.busy end))
  assert(not composition.error, composition.error)
  plans[index] = composition.view.plan_id
  local adapter = composition.view.composition.adaptation
  assert(adapter.kind == "c_abi_wrapper")

  for row, target in pairs(composition.targets) do
    if target.artifact == adapter.artifact then vim.api.nvim_win_set_cursor(composition.win, { row, 0 }); break end
  end

  composition.navigate()
  assert(vim.wait(10000, function() return not composition.busy end))
  assert(not composition.error, composition.error)
  local source_buf = vim.api.nvim_get_current_buf()
  assert(vim.b[source_buf].oculus_archived_source == adapter.artifact)
  assert(table.concat(vim.api.nvim_buf_get_lines(source_buf, 0, -1, false), "\n"):find('extern "C"', 1, true))
  composition.submit()
  jobs = require("oculus.nexus").state
  assert(vim.wait(60000, function() return jobs.error or (not jobs.busy and #jobs.jobs == index) end))
  assert(not jobs.error, jobs.error)
  assert(jobs.last_job.plan_id == plans[index] and jobs.last_job.resource_id == "local-native")
  if index == 1 then jobs.close() end
end

vim.fn.delete(producer, "rf")
vim.fn.delete(consumer, "rf")
jobs.work()

assert(vim.wait(240000, function()
  if jobs.error then return true end
  if jobs.working then return false end
  for _, job in ipairs(jobs.jobs) do if job.state ~= "succeeded" then return false end end
  return true
end), "Native composition jobs did not finish")

assert(not jobs.error, jobs.error)
local outcomes = {}

for _, job in ipairs(jobs.jobs) do
  outcomes[job.plan_id] = job
end

for index, plan in ipairs(plans) do
  if jobs.closed then jobs = oculus.open_nexus(); assert(vim.wait(15000, function() return #jobs.jobs == 2 or jobs.error end)) end
  jobs.open_result(outcomes[plan])
  local state = require("oculus.investigations").state
  assert(vim.wait(15000, function() return not state.busy end))
  assert(not state.error, state.error)
  assert(state.view.investigation_id == investigations[index])
  local rendered = table.concat(vim.api.nvim_buf_get_lines(state.buf, 0, -1, false), "\n")
  assert(rendered:find("doubles-seven", 1, true), rendered)
  assert(rendered:find(index == 1 and "supported_for_cases" or "behavior_failed", 1, true), rendered)
  state.close()
end

vim.fn.delete(vim.fn.stdpath("state") .. "/oculus-composition/" .. vim.fn.sha256(vim.fn.fnamemodify(store, ":p")) .. ".json")
vim.fn.delete(directory, "rf")
print("Real C/Zig finding → reviewed C ABI adapter → native Nexus build/link/behavior → archived investigation evidence passed")
