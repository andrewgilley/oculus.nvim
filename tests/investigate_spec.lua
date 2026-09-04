local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)
local oculus = require("oculus")
local engine = require("oculus.investigate.engine")
local window = require("oculus.investigate.window")
local navigation = require("oculus.navigation")

do
  -- Test 1: Navigation resolves investigate keys
  local nav = navigation.resolve()
  assert(nav.investigate == "x", "expected nav.investigate to be 'x'")
  assert(nav.investigate_id == "X", "expected nav.investigate_id to be 'X'")
  local nav_hjkl = navigation.resolve("hjkl")
  assert(nav_hjkl.investigate == "x")
  assert(nav_hjkl.investigate_id == "X")
  -- Test 2: Engine binary discovery
  local binary = engine.find_engine_binary()
  assert(binary ~= nil and binary ~= "", "expected engine binary to be found")
  assert(vim.fn.filereadable(binary) == 1, "expected engine binary to be readable and exist")
  -- Test 3: Engine execution returns structured fact bundle
  local done = false
  local received_bundle = nil
  local received_err = nil

  engine.run({ repo_root = root }, function(bundle, err)
    received_bundle = bundle
    received_err = err
    done = true
  end)

  vim.wait(10000, function()
    return done
  end, 50)

  assert(done, "expected engine.run to complete within 10 seconds")
  assert(received_err == nil, "expected no error, got: " .. tostring(received_err))
  assert(received_bundle ~= nil, "expected non-nil fact bundle")
  assert(received_bundle.metadata ~= nil, "expected metadata in bundle")
  assert(type(received_bundle.metadata.repository_root) == "string", "expected repository_root string")
  assert(type(received_bundle.invariants) == "table", "expected invariants table")
  assert(#received_bundle.invariants >= 2, "expected at least 2 invariant checks")
  assert(type(received_bundle.co_changes) == "table", "expected co_changes table")
  -- Test 4: Window rendering
  window.open(received_bundle)
  assert(window.state.win ~= nil and vim.api.nvim_win_is_valid(window.state.win), "expected window to be open and valid")
  assert(window.state.buf ~= nil and vim.api.nvim_buf_is_valid(window.state.buf), "expected buffer to be open and valid")
  local lines = vim.api.nvim_buf_get_lines(window.state.buf, 0, -1, false)
  local text = table.concat(lines, "\n")
  assert(text:find("Oculus Investigation", 1, true) or text:find("VERIFIED INVARIANTS", 1, true), "expected header in rendered buffer")
  assert(text:find("AFFECTED SEMANTIC ENTITIES", 1, true), "expected entities section")
  assert(text:find("CHANGE COUPLING", 1, true), "expected change coupling section")
  -- Test 5: Window close
  window.close()
  assert(window.state.win == nil, "expected window state to be cleared after close")
  assert(window.state.buf == nil, "expected buf state to be cleared after close")
  -- Test 6: End-to-end oculus.investigate call
  local oculus_done = false
  local oculus_bundle = nil

  oculus.investigate(nil, {}, { cwd = root }, function(b, err)
    oculus_bundle = b
    oculus_done = true
  end)

  vim.wait(10000, function()
    return oculus_done
  end, 50)

  assert(oculus_done, "expected oculus.investigate to complete")
  assert(oculus_bundle ~= nil, "expected valid bundle from oculus.investigate")
  assert(window.state.win ~= nil and vim.api.nvim_win_is_valid(window.state.win), "expected window to open from oculus.investigate")
  window.close()
  print("ALL INVESTIGATE TESTS PASSED!")
end
