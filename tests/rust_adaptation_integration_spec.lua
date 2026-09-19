vim.opt.runtimepath:prepend(vim.fn.getcwd())
local root = vim.fn.fnamemodify(vim.fn.getcwd(), ":h")
local binary = vim.env.PLEXUS_BIN or root .. "/plexus/target/debug/plexus"
local launcher = vim.env.NEXUS_SCRIPT or root .. "/nexus/nexus.py"
assert(vim.fn.executable(binary) == 1, "Build Plexus first")
local directory = vim.fn.tempname()

local function command(argv, cwd)
  local result = vim.system(argv, { text = true, cwd = cwd }):wait()
  assert(result.code == 0, result.stderr)
  return vim.trim(result.stdout)
end

local function commit(repository)
  command({ "git", "-C", repository, "add", "." })
  command({ "git", "-C", repository, "-c", "user.name=Oculus Fixture", "-c", "user.email=test@example.invalid", "commit", "-qm", "fixture" })
end

-- A workspace whose producer replaces `magnitude` with `measure`. The consumer
-- calls the removed function; its integration test pins the behavior.
local function repository(name, measure)
  local path = directory .. "/" .. name
  for _, dir in ipairs({ "/producer/src", "/consumer/src", "/consumer/tests" }) do vim.fn.mkdir(path .. dir, "p") end
  vim.fn.writefile({ "[workspace]", "members=['producer','consumer']", "resolver='2'" }, path .. "/Cargo.toml")
  vim.fn.writefile({ "[package]", "name='signal-math'", "version='0.1.0'", "edition='2021'" }, path .. "/producer/Cargo.toml")

  vim.fn.writefile({ "[package]", "name='wave-reader'", "version='0.1.0'", "edition='2021'", "[dependencies]",
    "math_alias={package='signal-math',path='../producer',default-features=false}" }, path .. "/consumer/Cargo.toml")

  vim.fn.writefile({ "pub fn magnitude(sample: u32) -> u32 { sample + 1 }" }, path .. "/producer/src/lib.rs")
  vim.fn.writefile({ "use math_alias::magnitude as level;", "pub fn read(x: u32) -> u32 { level(x) }" }, path .. "/consumer/src/lib.rs")
  vim.fn.writefile({ "#[test]", "fn reads_one() {", "    assert_eq!(wave_reader::read(1), 2);", "}" }, path .. "/consumer/tests/read.rs")
  command({ "cargo", "generate-lockfile", "--offline" }, path)
  command({ "git", "-C", path, "init", "--quiet" })
  commit(path)
  vim.fn.writefile({ measure }, path .. "/producer/src/lib.rs")
  commit(path)
  return path
end

local store, nexus_dir = directory .. "/store", directory .. "/nexus"
vim.fn.mkdir(directory, "p")
vim.fn.writefile({ vim.json.encode({ schema_version = 1, plexus_command = { binary }, resources = { { id = "local-native", backend = "plexus-native" } } }) }, directory .. "/resources.json")
command({ "python3", launcher, "configure", directory .. "/resources.json", nexus_dir })
local oculus = require("oculus")
oculus.config.plexus = { command = { binary }, store = store }
oculus.config.nexus = { command = { "python3", launcher }, state_dir = nexus_dir }

local repositories = { repository("same", "pub fn measure(value: u32) -> u32 { value + 1 }"),
  repository("changed", "pub fn measure(value: u32) -> u32 { value + 2 }") }

local plans, investigations, jobs = {}, {}, nil
local original_input = vim.ui.input

for index, path in ipairs(repositories) do
  local request = { schema_version = 1, repository = path, base = "HEAD^", head = "HEAD", producer_manifest = "producer/Cargo.toml",
    consumer_repository = path, consumer_manifest = "consumer/Cargo.toml", intent = "Can the consumer move to the replacement?" }

  local view = vim.json.decode(command({ binary, "investigate", vim.json.encode(request), store }))
  investigations[index] = view.investigation_id
  local state = oculus.open_investigations(view.investigation_id)
  assert(vim.wait(15000, function() return not state.busy end))
  assert(not state.error, state.error)
  local selected

  for row, target in pairs(state.targets) do
    if target.opportunity and target.opportunity.kind == "candidate_substitution" then
      selected = target
      vim.api.nvim_win_set_cursor(state.win, { row, 0 })
      break
    end
  end

  assert(selected, "Expected a substitution finding")
  local rendered = table.concat(vim.api.nvim_buf_get_lines(state.buf, 0, -1, false), "\n")
  assert(rendered:find("p: adapt the consumer's calls", 1, true), rendered)
  -- The developer only names the tests; Oculus writes the contract request.
  vim.ui.input = function(_, callback) callback("reads_one") end
  state.compose(selected)
  vim.ui.input = original_input
  local composition = require("oculus.compositions").state
  assert(vim.wait(60000, function() return not composition.busy end))
  assert(not composition.error, composition.error)
  plans[index] = composition.view.plan_id
  assert(composition.view.native_kind == "rust_call_site_adaptation")
  local shown = table.concat(vim.api.nvim_buf_get_lines(composition.buf, 0, -1, false), "\n")
  assert(shown:find("RUST CALL-SITE ADAPTATION", 1, true), shown)
  assert(shown:find("signal_math::magnitude → signal_math::measure", 1, true), shown)
  assert(shown:find("reads_one · consumer test", 1, true), shown)
  local patch = composition.view.composition.adaptation.patch

  for row, target in pairs(composition.targets) do
    if target.artifact == patch then vim.api.nvim_win_set_cursor(composition.win, { row, 0 }); break end
  end

  composition.navigate()
  assert(vim.wait(10000, function() return not composition.busy end))
  assert(not composition.error, composition.error)
  local diff = table.concat(vim.api.nvim_buf_get_lines(vim.api.nvim_get_current_buf(), 0, -1, false), "\n")
  assert(diff:find("-use math_alias::magnitude as level;", 1, true), diff)
  assert(diff:find("+pub fn read(x: u32) -> u32 { math_alias::measure(x) }", 1, true), diff)
  -- Review never changes the developer's worktree.
  assert(vim.fn.readfile(path .. "/consumer/src/lib.rs")[1] == "use math_alias::magnitude as level;")
  composition.submit()
  jobs = require("oculus.nexus").state
  assert(vim.wait(60000, function() return jobs.error or (not jobs.busy and #jobs.jobs == index) end))
  assert(not jobs.error, jobs.error)
  assert(jobs.last_job.plan_id == plans[index] and jobs.last_job.resource_id == "local-native")
  if index == 1 then jobs.close() end
end

-- The plans run from the archive alone.
for _, path in ipairs(repositories) do vim.fn.delete(path, "rf") end
jobs.work()

assert(vim.wait(240000, function()
  if jobs.error then return true end
  if jobs.working then return false end
  for _, job in ipairs(jobs.jobs) do if job.state ~= "succeeded" then return false end end
  return true
end), "Rust adaptation jobs did not finish")

assert(not jobs.error, jobs.error)
local outcomes = {}
for _, job in ipairs(jobs.jobs) do outcomes[job.plan_id] = job end

for index, plan in ipairs(plans) do
  if jobs.closed then jobs = oculus.open_nexus(); assert(vim.wait(15000, function() return #jobs.jobs == 2 or jobs.error end)) end
  jobs.open_result(outcomes[plan])
  local state = require("oculus.investigations").state
  assert(vim.wait(15000, function() return not state.busy end))
  assert(not state.error, state.error)
  assert(state.view.investigation_id == investigations[index])
  local rendered = table.concat(vim.api.nvim_buf_get_lines(state.buf, 0, -1, false), "\n")
  assert(rendered:find(index == 1 and "supported_for_cases" or "behavior_failed", 1, true), rendered)
  assert(rendered:find("Adaptation needed: true", 1, true), rendered)
  assert(rendered:find("Case: reads_one · " .. (index == 1 and "passed" or "failed"), 1, true), rendered)
  assert(rendered:find("Selected consumer tests only", 1, true), rendered)
  state.close()
end

vim.fn.delete(vim.fn.stdpath("state") .. "/oculus-composition/" .. vim.fn.sha256(vim.fn.fnamemodify(store, ":p")) .. ".json")
vim.fn.delete(directory, "rf")
print("Real Rust substitution → reviewed call-site patch → Nexus before/after consumer builds and tests → investigation evidence passed")
