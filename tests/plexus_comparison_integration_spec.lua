vim.opt.runtimepath:prepend(vim.fn.getcwd())
local root = vim.fn.fnamemodify(vim.fn.getcwd(), ":h")
local binary = vim.env.PLEXUS_BIN or root .. "/plexus/target/debug/plexus"
local worker = vim.env.PLEXUS_ZUG_WORKER or root .. "/zug/zig-out/bin/zug-plexus"
assert(vim.fn.executable(binary) == 1, "Build Plexus or set PLEXUS_BIN")
assert(vim.fn.executable(worker) == 1, "Build the Zug Plexus worker or set PLEXUS_ZUG_WORKER")
local directory = vim.fn.tempname()
local bridge = require("oculus.plexus")
local state

local function settled()
  assert(vim.wait(30000, function() return not state.busy end), "Plexus operation timed out")
  assert(not state.error, state.error)
end

local function unresolved()
  assert(state.view.composition_execution == "unresolved")
  assert(state.view.bindings[1].implementation_conformance == "unresolved")
end

local ok, failure = xpcall(function()
  local runs = {}

  for _, backend in ipairs({ "wasmtime", "zug" }) do
    state = bridge.open({ command = { binary }, store = directory, backend = backend, zug_command = worker },
      root .. "/plexus/fixtures/fixed-length-lists/adapter/hypothesis.json")
    settled()
    assert(state.view.analysis.subject.status == "declaration_reachable")
    assert(state.view.bindings[1].runtime.backend == backend)
    assert(state.view.bindings[1].mapping.kind == "fixed_u8_list")
    unresolved()
    local prepared = state.view.hypothesis_id
    local selected

    for row, binding in pairs(state.targets) do
      if binding.id == "checksum" then selected = row; break end
    end

    assert(selected, "Checksum binding must be selectable")
    vim.api.nvim_win_set_cursor(state.win, { selected, 0 })
    state.run()
    settled()
    assert(state.view.hypothesis_id ~= prepared, "Run evidence must be attached to a new immutable hypothesis")
    assert(#state.view.evidence == 1)
    assert(state.view.evidence[1].freshness == "current")
    assert(state.view.evidence[1].conclusion == "supported_for_cases")
    unresolved()
    runs[backend] = state.view.evidence[1].attachment.run
  end

  local investigation = vim.deepcopy(state.view)
  local lines = vim.api.nvim_buf_get_lines(state.buf, 0, -1, false)
  state.compare(runs.wasmtime, runs.zug)
  settled()
  local report = state.comparison
  assert(report.status == "agreement_for_cases")
  assert(report.left_run == runs.wasmtime and report.right_run == runs.zug)
  assert(report.left_runtime.backend == "wasmtime" and report.right_runtime.backend == "zug")
  assert(report.left_conclusion == "supported_for_cases" and report.right_conclusion == "supported_for_cases")
  assert(#report.cases == 6)

  for _, case in ipairs(report.cases) do
    assert(case.status == "agreement")
    assert(vim.deep_equal(case.left_values, case.expected) and vim.deep_equal(case.right_values, case.expected))
  end

  assert(vim.deep_equal(investigation, state.view), "Comparison must preserve the original investigation and evidence")
  assert(vim.deep_equal(lines, vim.api.nvim_buf_get_lines(state.buf, 0, -1, false)))
  unresolved()
  local rendered = table.concat(vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(state.raw_win), 0, -1, false), "\n")

  for _, expected in ipairs({ "agreement_for_cases", "LEFT: wasmtime", "RIGHT: zug", "binary-at-offset",
    "Expected: [384]", "Left: [384]", "Right: [384]", "end-of-page", "Left: [170]", "LIMITATIONS" }) do
    assert(rendered:find(expected, 1, true), "Missing real comparison detail: " .. expected)
  end
end, debug.traceback)

if state then state.close() end
vim.fn.delete(vim.fn.stdpath("state") .. "/oculus-plexus/" .. vim.fn.sha256(vim.fn.fnamemodify(directory, ":p")) .. ".json")
vim.fn.delete(directory, "rf")
assert(ok, failure)
print("Real fixed-length-list adapter → Wasmtime/Zug UI runs → attached evidence → runtime comparison passed")
