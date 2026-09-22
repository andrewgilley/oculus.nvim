vim.opt.runtimepath:prepend(vim.fn.getcwd())
local root = vim.fn.fnamemodify(vim.fn.getcwd(), ":h")
local binary = vim.env.PLEXUS_BIN or root .. "/plexus/target/debug/plexus"
assert(vim.fn.executable(binary) == 1, "Build Plexus first")
local directory = vim.fn.tempname()
local repository = directory .. "/repository"
vim.fn.mkdir(repository .. "/producer/src", "p")
vim.fn.mkdir(repository .. "/consumer/src", "p")
local function write(path, lines) vim.fn.writefile(lines, repository .. "/" .. path) end

local function run(argv)
  local result = vim.system(argv, { text = true, cwd = repository }):wait()
  assert(result.code == 0, result.stderr)
  return vim.trim(result.stdout)
end

local function commit(message)
  run({ "git", "add", "." })
  run({ "git", "-c", "user.name=Oculus Test", "-c", "user.email=test@example.invalid", "commit", "-m", message })
  return run({ "git", "rev-parse", "HEAD" })
end

write("Cargo.toml", { "[workspace]", "members=['producer','consumer']", "resolver='2'" })
write("producer/Cargo.toml", { "[package]", "name='capture-producer'", "version='0.1.0'", "edition='2021'" })
write("consumer/Cargo.toml", { "[package]", "name='capture-consumer'", "version='0.1.0'", "edition='2021'", "[dependencies]", "capture-producer={path='../producer',default-features=false}" })
write("producer/src/lib.rs", { "pub enum Mode { Known }" })
local consumer_lines = { "use capture_producer::Mode;", "pub fn handle(mode: Mode)->Result<(),()> { match mode { Mode::Known=>Ok(()), _=>Err(()) } }" }
write("consumer/src/lib.rs", consumer_lines)
run({ "cargo", "generate-lockfile", "--offline" })
run({ "git", "init", "--quiet" })
local base = commit("initial enum")
write("producer/src/lib.rs", { "pub enum Mode { Known, NewlyPossible }" })
local head = commit("new capability")
-- Dirty working copies must never replace the selected committed observation.
write("producer/src/lib.rs", { "pub enum Mode { OnlyDirtyWork }" })
local oculus = require("oculus")
oculus.config.plexus = { command = { binary }, store = directory .. "/artifacts" }
oculus.config.projects = {}
local old_input = vim.ui.input
local answers = { repository, "HEAD", "HEAD^", "producer/Cargo.toml", repository, "HEAD", "consumer/Cargo.toml", "What can this consumer now support?" }
vim.ui.input = function(_, callback) callback(table.remove(answers, 1)) end
vim.cmd.runtime("plugin/oculus.lua")
vim.cmd.OculusInvestigate()
vim.ui.input = old_input
assert(#answers == 0)
local bridge = require("oculus.investigations")
local state = bridge.state
assert(vim.wait(60000, function() return not state.busy end), "Capture did not finish")
assert(not state.error, state.error)
assert(state.view.status == "completed", vim.inspect(state.view))
assert(state.view.observation.base == base and state.view.observation.head == head)
assert(state.view.observation.consumer_revision == head)
assert(#state.view.experiments == 0 and #state.view.reports == 1)
local investigation_id = state.view.investigation_id
local finding = state.view.reports[1].opportunities[1]
assert(finding and finding.status == "inferred")
assert(finding.consumer_location.path == repository .. "/consumer/src/lib.rs")
local rendered = table.concat(vim.api.nvim_buf_get_lines(state.buf, 0, -1, false), "\n")
assert(rendered:find("NewlyPossible", 1, true) and not rendered:find("OnlyDirtyWork", 1, true))
assert(rendered:find("No supported experiment", 1, true))
state.close()
-- Recreate the module to discard its in-memory state before reopening the catalog.
package.loaded["oculus.investigations"] = nil
vim.cmd.OculusInvestigations()
bridge = require("oculus.investigations")
state = bridge.state
assert(vim.wait(10000, function() return not state.busy end))
assert(not state.error, state.error)
assert(#state.catalog_value.investigations == 1)
assert(state.catalog_value.investigations[1].investigation_id == investigation_id)
state.navigate(state.catalog_value.investigations[1])
assert(vim.wait(10000, function() return not state.busy end))
assert(not state.error, state.error)
local target
for _, value in pairs(state.targets) do target = value; break end
assert(target)
state.navigate(target)
assert(vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(state.source_win)) == finding.consumer_location.path)
assert(state.closed, "following a location hands the screen to the source")

-- Following a location closes the float, so reopen the stored investigation
-- before navigating again.
local function reopen()
  state = bridge.open(oculus.config.plexus, oculus.config.nexus, investigation_id)
  assert(vim.wait(10000, function() return not state.busy end))
  assert(not state.error, state.error)
  for _, value in pairs(state.targets) do
    if value.source then return value end
  end
  error("reopened investigation has no navigable finding")
end

-- The archived source is still navigable after removing the entire repository.
vim.fn.delete(repository, "rf")
target = reopen()
state.navigate(target)
assert(vim.wait(10000, function() return not state.busy end))
assert(not state.error, state.error)
local archived = vim.api.nvim_win_get_buf(state.source_win)
assert(vim.b[archived].oculus_archived_source == finding.consumer_location.artifact)
assert(vim.bo[archived].readonly and not vim.bo[archived].modifiable)
local content = table.concat(vim.api.nvim_buf_get_lines(archived, 0, -1, false), "\n")
assert(content == table.concat(consumer_lines, "\n") .. "\n")
target = reopen()
state.refresh()
assert(vim.wait(10000, function() return not state.busy end))
assert(not state.error and state.view.investigation_id == investigation_id, state.error)
state.queue(target)
assert(not require("oculus.nexus").state, "generic inference must not invent an experiment")
state.close()
vim.fn.delete(directory, "rf")
print("Real prompted Git change → Plexus capture/discovery → durable Oculus catalog and archived source passed")
