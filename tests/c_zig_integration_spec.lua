vim.opt.runtimepath:prepend(vim.fn.getcwd())
local root = vim.fn.fnamemodify(vim.fn.getcwd(), ":h")
local binary = vim.env.PLEXUS_BIN or root .. "/plexus/target/debug/plexus"
assert(vim.fn.executable(binary) == 1, "Build Plexus first")
local directory = vim.fn.tempname()
local producer, consumer = directory .. "/codec-cpp", directory .. "/viewer-zig"
vim.fn.mkdir(producer .. "/include", "p")
vim.fn.mkdir(consumer .. "/src", "p")

local function git(repository, args)
  local result = vim.system(vim.list_extend({ "git", "-C", repository }, args), { text = true }):wait()
  assert(result.code == 0, result.stderr)
  return vim.trim(result.stdout)
end

local function commit(repository)
  git(repository, { "add", "." })
  git(repository, { "-c", "user.name=Oculus Test", "-c", "user.email=test@example.invalid", "commit", "-qm", "fixture" })
  return git(repository, { "rev-parse", "HEAD" })
end

git(producer, { "init", "--quiet" })
git(consumer, { "init", "--quiet" })
vim.fn.writefile({ 'extern "C" int old(int);', "int parse(int);" }, producer .. "/include/api.h")
local base = commit(producer)
vim.fn.writefile({ 'extern "C" int replacement(int);', 'extern "C" int ready(int);', "int parse(int);" }, producer .. "/include/api.h")
local head = commit(producer)
local zig = { "pub extern fn old(x: c_int) c_int;", "pub extern fn ready(x: c_int) c_int;", "pub extern fn parse(x: c_int) c_int;" }
vim.fn.writefile(zig, consumer .. "/src/bindings.zig")
local revision = commit(consumer)
local oculus = require("oculus")
oculus.config.plexus = { command = { binary }, store = directory .. "/store" }
oculus.config.projects = {}
local old_input = vim.ui.input
-- The include directories prompt accepts an empty answer: this header is
-- self-contained, so the repository root and its own directory suffice.
local answers = { producer, head, base, "include/api.h", "c++", "", consumer, revision, "src/bindings.zig", "Which C++ changes help the Zig consumer?" }
vim.ui.input = function(_, callback) callback(table.remove(answers, 1)) end
vim.cmd.runtime("plugin/oculus.lua")
vim.cmd("OculusInvestigate c-zig")
vim.ui.input = old_input
assert(#answers == 0)
local bridge = require("oculus.investigations")
local state = bridge.state
assert(vim.wait(30000, function() return not state.busy end), "C/Zig capture did not finish")
assert(not state.error, state.error)
assert(state.view.status == "completed", vim.inspect(state.view))
assert(state.view.observation.analysis == "c_zig")
assert(state.view.observation.base == base and state.view.observation.head == head)
local kinds = {}

for _, finding in ipairs(state.view.reports[1].opportunities) do
  kinds[finding.kind] = true
  assert(finding.status == "inferred")
end

assert(kinds.c_abi_binding_enabled and kinds.candidate_c_abi_substitution and kinds.requires_c_abi_wrapper)
assert(#state.view.experiments == 0)
local investigation = state.view.investigation_id
local report = vim.deepcopy(state.view.reports)
state.close()
vim.fn.delete(producer, "rf")
vim.fn.delete(consumer, "rf")
state = oculus.open_investigations(investigation)
assert(vim.wait(10000, function() return not state.busy end))
assert(not state.error, state.error)
assert(vim.deep_equal(state.view.reports, report))
local rendered = table.concat(vim.api.nvim_buf_get_lines(state.buf, 0, -1, false), "\n")
assert(rendered:find("C/C++ ABI → Zig", 1, true))

-- Each finding sits under what it means for the Zig consumer.
for _, heading in ipairs({ "NEWLY POSSIBLE", "SUBSTITUTION PATHS", "ONE ADAPTER AWAY", "BROKEN BY THIS CHANGE" }) do
  assert(rendered:find(heading, 1, true), heading)
end

local function detail_of(kind)
  for row, target in pairs(state.targets) do
    if target.kind == "finding" and target.opportunity.kind == kind then
      vim.api.nvim_win_set_cursor(state.win, { row, 0 })
      state.show_detail()
      return (table.concat(vim.api.nvim_buf_get_lines(state.detail_buf, 0, -1, false), " "):gsub("%s+", " "))
    end
  end

  error("no " .. kind .. " finding")
end

local wrapper = detail_of("requires_c_abi_wrapper")
assert(wrapper:find("✓ observed", 1, true) and wrapper:find("◐ inferred", 1, true), wrapper)
assert(wrapper:find("p Prepare a native composition from selected implementation sources and behavioral cases", 1, true), wrapper)
-- Nothing links to a removed binding; its detail points to what could replace it.
local removed = detail_of("c_abi_binding_removed")
assert(removed:find("no executable step for this finding yet", 1, true) and removed:find("RELATED · same requirement", 1, true), removed)
assert(removed:find("⇄ replacement may replace old", 1, true) and removed:find("⇄ ready may replace old", 1, true), removed)
for _, obligation in ipairs(state.view.reasoning.obligations) do assert(obligation.status == "unresolved") end
local selected

for row, target in pairs(state.targets) do
  if target.source and target.source.path == consumer .. "/src/bindings.zig" then
    selected = target
    vim.api.nvim_win_set_cursor(state.win, { row, 0 })
    break
  end
end

assert(selected)
state.navigate()
assert(vim.wait(10000, function() return not state.busy end))
assert(not state.error, state.error)
assert(table.concat(vim.api.nvim_buf_get_lines(vim.api.nvim_get_current_buf(), 0, -1, false), "\n"):find("extern fn", 1, true))
state.close()
vim.fn.delete(directory, "rf")
print("Real C++ header → Plexus relationship reasoning → Oculus findings and archived Zig source passed")
