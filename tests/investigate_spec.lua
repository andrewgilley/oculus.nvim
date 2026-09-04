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
  -- Test 7: Forge artifact ingestion and traceability linking
  local forge_done = false
  local forge_bundle = nil

  local fake_issue = {
    forge = "github",
    kind = "issue",
    id = "42",
    title = "Refactor AstParser and ChangeCouplingMiner",
    body = "We should update `AstParser` to support more tree-sitter grammars and optimize `ChangeCouplingMiner`.",
    author = "octocat",
    state = "open",
    url = "https://github.com/example/oculus/issues/42",
    labels = { "enhancement" },
    comments = {
      { author = "reviewer", body = "Also consider `GitReader` performance in `git.rs`." },
    },
  }

  engine.run({ repo_root = root, forge_artifact = fake_issue }, function(bundle, err)
    forge_bundle = bundle
    forge_done = true
  end)

  vim.wait(10000, function()
    return forge_done
  end, 50)

  assert(forge_done, "expected engine.run with forge_artifact to complete")
  assert(forge_bundle ~= nil, "expected valid bundle with forge data")
  assert(forge_bundle.forge_artifact ~= nil, "expected forge_artifact in bundle")
  assert(forge_bundle.forge_artifact.id == "42", "expected id 42")
  assert(type(forge_bundle.traceability_links) == "table", "expected traceability_links table")
  assert(#forge_bundle.traceability_links > 0, "expected traceability links to be discovered")
  -- Check window renders forge context and traceability links
  window.open(forge_bundle)
  local rendered = table.concat(vim.api.nvim_buf_get_lines(window.state.buf, 0, -1, false), "\n")
  assert(rendered:find("FORGE CONTEXT", 1, true), "expected FORGE CONTEXT in window")
  assert(rendered:find("FORGE-TO-CODE TRACEABILITY LINKS", 1, true), "expected traceability links in window")
  assert(rendered:find("AstParser", 1, true), "expected AstParser in traceability links")
  window.close()
  -- Test 8: oculus.investigate with context.event extraction
  local event_done = false
  local event_bundle = nil

  local mock_event = {
    type = "IssuesEvent",
    payload = {
      issue = {
        number = 99,
        title = "Fix AstParser line mapping",
        body = "Investigate `AstParser` and `GitSemanticMapper`.",
        html_url = "https://github.com/example/oculus/issues/99",
      },
    },
  }

  oculus.investigate(nil, {}, { cwd = root, event = mock_event }, function(b, err)
    event_bundle = b
    event_done = true
  end)

  vim.wait(10000, function()
    return event_done
  end, 50)

  assert(event_done, "expected event investigation to complete")
  assert(event_bundle ~= nil, "expected event bundle")
  assert(event_bundle.forge_artifact ~= nil and event_bundle.forge_artifact.id == "99")
  assert(#event_bundle.traceability_links > 0, "expected traceability links from event")
  window.close()
  print("ALL INVESTIGATE TESTS PASSED!")
end
