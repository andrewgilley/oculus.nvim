vim.opt.runtimepath:prepend(vim.fn.getcwd())
local root = vim.fn.fnamemodify(vim.fn.getcwd(), ":h")
local binary = vim.env.PLEXUS_BIN or root .. "/plexus/target/debug/plexus"
assert(vim.fn.executable(binary) == 1, "Build Plexus or set PLEXUS_BIN")
local directory = vim.fn.tempname()

local state = require("oculus.plexus").open({ command = { binary }, store = directory,
  backend = vim.env.PLEXUS_BACKEND or "wasmtime", zug_command = vim.env.PLEXUS_ZUG_COMMAND },
  root .. "/plexus/fixtures/hypotheses/hypothesis.json")

local function key(lhs)
  for _, mapping in ipairs(vim.api.nvim_buf_get_keymap(state.buf, "n")) do
    if mapping.lhs == lhs then mapping.callback(); return end
  end

  error("Missing Plexus mapping: " .. lhs)
end

assert(vim.wait(10000, function() return not state.busy end))
assert(not state.error, state.error)
assert(state.view.analysis.subject.status == "declaration_reachable")
assert(state.view.analysis.hypothetical)
local first = state.view.hypothesis_id
for row in pairs(state.targets) do vim.api.nvim_win_set_cursor(state.win, { row, 0 }); break end
key("x")
assert(vim.wait(10000, function() return not state.busy end))
assert(not state.error, state.error)
assert(state.view.hypothesis_id ~= first)
assert(state.view.evidence[1].freshness == "current")
assert(state.view.evidence[1].conclusion == "supported_for_cases")
assert(state.view.composition_execution == "unresolved")
assert(state.view.bindings[1].implementation_conformance == "unresolved")
local attached = state.view.hypothesis_id
key("R")
assert(vim.wait(10000, function() return not state.busy end))
assert(not state.error, state.error)
assert(state.view.parent == attached)
assert(state.view.evidence[1].freshness == "current")
key("q")
vim.fn.delete(vim.fn.stdpath("state") .. "/oculus-plexus/" .. vim.fn.sha256(vim.fn.fnamemodify(directory, ":p")) .. ".json")
vim.fn.delete(directory, "rf")
print("Real Plexus prepare → run → attach → revise passed")
