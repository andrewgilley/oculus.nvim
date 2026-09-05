local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)
local oculus = require("oculus")
local engine = require("oculus.investigate.engine")
local window = require("oculus.investigate.window")
local navigation = require("oculus.navigation")

do
  -- Test 1: Navigation resolves investigate keys
  local nav = navigation.resolve()
  assert(nav.investigate == "i", "expected nav.investigate to be 'i'")
  assert(nav.investigate_id == "I", "expected nav.investigate_id to be 'I'")
  local nav_hjkl = navigation.resolve("hjkl")
  assert(nav_hjkl.investigate == "i")
  assert(nav_hjkl.investigate_id == "I")
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
  -- Test 9: Mandatory relationship provenance & split UI explorer
  assert(type(forge_bundle.relationships) == "table", "expected relationships table")
  assert(#forge_bundle.relationships > 0, "expected relationships with provenance")

  for _, rel in ipairs(forge_bundle.relationships) do
    assert(type(rel.provenance) == "table", "expected provenance on relationship")
    assert(type(rel.provenance.source_type) == "string", "expected provenance source_type")
    assert(type(rel.confidence) == "number" and rel.confidence > 0, "expected confidence score")
  end

  window.open(forge_bundle, { width = 120, height = 40 })
  assert(window.state.win ~= nil and vim.api.nvim_win_is_valid(window.state.win), "expected tree win")
  assert(window.state.ledger_win ~= nil and vim.api.nvim_win_is_valid(window.state.ledger_win), "expected ledger win in split layout")
  assert(window.state.ledger_buf ~= nil and vim.api.nvim_buf_is_valid(window.state.ledger_buf), "expected ledger buf")
  local ledger_lines = vim.api.nvim_buf_get_lines(window.state.ledger_buf, 0, -1, false)
  local ledger_text = table.concat(ledger_lines, "\n")
  assert(ledger_text:find("DETERMINISTIC PROVENANCE LEDGER", 1, true), "expected ledger header")
  -- Move cursor to a line that has a traceability link or entity and verify ledger updates
  local target_line = nil

  for l, prov in pairs(window.state.line_provenance) do
    if prov.kind == "traceability_link" or prov.kind == "entity" then
      target_line = l
      break
    end
  end

  if target_line then
    vim.api.nvim_win_set_cursor(window.state.win, { target_line, 0 })
    vim.cmd("doautocmd CursorMoved")
    local updated_ledger = table.concat(vim.api.nvim_buf_get_lines(window.state.ledger_buf, 0, -1, false), "\n")
    assert(updated_ledger:find("PROVENANCE", 1, true) or updated_ledger:find("CONFIDENCE", 1, true), "expected provenance details in ledger")
  end

  window.close()
  assert(window.state.win == nil and window.state.ledger_win == nil, "expected both windows closed")

  -- Test 10: Architectural Dynamics (Boundary Crossings, Subsystem Instability, Historical Precedents)
  local dynamics_bundle = {
    metadata = {
      repository_root = root,
      target = "HEAD",
      engine_version = "0.1.0",
      analyzed_at = "2026-09-04T00:00:00Z",
    },
    entities = {},
    relationships = {},
    invariants = {
      { invariant_name = "boundary_integrity", passed = true, details = "0 boundary violations" },
    },
    dynamics = {
      boundary_crossings = {
        {
          source_subsystem = "lua.investigate",
          target_subsystem = "crates.oculus_engine",
          source_entity = "engine.run",
          target_entity = "main",
          risk_level = "high",
          reason = "Crosses native bridge into engine binary",
        },
      },
      subsystem_instabilities = {
        {
          subsystem = "lua.investigate",
          instability_score = 0.82,
          churn_rate = 0.65,
          test_coverage_ratio = 0.15,
          bus_factor = 1,
          primary_maintainer = "octocat",
          risk_category = "HIGH_CHURN_UNTESTED",
        },
      },
      historical_precedents = {
        {
          commit_oid = "abcdef1234567890",
          author = "contributor",
          date = "2026-09-01",
          message = "feat: initial investigate stub",
          similarity_score = 0.75,
          shared_files = { "lua/oculus/investigate/init.lua" },
          outcome_summary = "Precedent change introduced new subsystem.",
        },
      },
    },
  }

  window.open(dynamics_bundle, { width = 120, height = 40 })
  assert(window.state.win ~= nil and vim.api.nvim_win_is_valid(window.state.win), "expected tree win for dynamics")
  assert(window.state.ledger_win ~= nil and vim.api.nvim_win_is_valid(window.state.ledger_win), "expected ledger win for dynamics")
  local dyn_tree_lines = vim.api.nvim_buf_get_lines(window.state.buf, 0, -1, false)
  local dyn_tree_text = table.concat(dyn_tree_lines, "\n")
  assert(dyn_tree_text:find("ARCHITECTURAL BOUNDARY CROSSINGS", 1, true), "expected boundary crossings header")
  assert(dyn_tree_text:find("SUBSYSTEM INSTABILITY & RISK ALERTS", 1, true), "expected subsystem instability header")
  assert(dyn_tree_text:find("HISTORICAL PRECEDENTS", 1, true), "expected historical precedents header")
  assert(dyn_tree_text:find("[HIGH RISK]", 1, true), "expected high risk tag")
  assert(dyn_tree_text:find("HIGH_CHURN_UNTESTED", 1, true), "expected risk category")
  -- Check cursor movement over boundary crossing
  local crossing_line = nil
  local inst_line = nil
  local prec_line = nil

  for l, prov in pairs(window.state.line_provenance) do
    if prov.kind == "boundary_crossing" then
      crossing_line = l
    elseif prov.kind == "subsystem_instability" then
      inst_line = l
    elseif prov.kind == "historical_precedent" then
      prec_line = l
    end
  end

  assert(crossing_line ~= nil, "expected boundary crossing line in tree")
  assert(inst_line ~= nil, "expected instability line in tree")
  assert(prec_line ~= nil, "expected precedent line in tree")
  vim.api.nvim_win_set_cursor(window.state.win, { crossing_line, 0 })
  vim.cmd("doautocmd CursorMoved")
  local bc_ledger = table.concat(vim.api.nvim_buf_get_lines(window.state.ledger_buf, 0, -1, false), "\n")
  assert(bc_ledger:find("Architectural Boundary Crossing", 1, true), "expected boundary crossing in ledger")
  assert(bc_ledger:find("CROSSES_BOUNDARY", 1, true), "expected CROSSES_BOUNDARY relation")
  vim.api.nvim_win_set_cursor(window.state.win, { inst_line, 0 })
  vim.cmd("doautocmd CursorMoved")
  local inst_ledger = table.concat(vim.api.nvim_buf_get_lines(window.state.ledger_buf, 0, -1, false), "\n")
  assert(inst_ledger:find("Subsystem Instability Metric", 1, true), "expected instability metric in ledger")
  assert(inst_ledger:find("HIGH_CHURN_UNTESTED", 1, true), "expected risk category in ledger")
  vim.api.nvim_win_set_cursor(window.state.win, { prec_line, 0 })
  vim.cmd("doautocmd CursorMoved")
  local prec_ledger = table.concat(vim.api.nvim_buf_get_lines(window.state.ledger_buf, 0, -1, false), "\n")
  assert(prec_ledger:find("Historical Precedent", 1, true), "expected historical precedent in ledger")
  assert(prec_ledger:find("abcdef1", 1, true), "expected commit oid in ledger")
  window.close()
  assert(window.state.win == nil and window.state.ledger_win == nil, "expected both windows closed after test 10")
  -- Test 11: Agent Hypotheses & Adversarial Reality Checking (Layers 25-26)
  local agent = require("oculus.investigate.agent")
  -- Projection test
  local projection = agent.build_projection(dynamics_bundle)
  assert(projection:find("FACT PROJECTION", 1, true), "expected FACT PROJECTION in agent projection")
  assert(projection:find("ARCHITECTURAL BOUNDARY CROSSINGS", 1, true), "expected boundary crossings in projection")
  -- Test scaffold generation
  local fake_entity = { name = "calculate_impact", file_path = "lua/oculus/investigate/engine.lua", start_line = 10 }
  local fake_callers = { { name = "open_window", file_path = "lua/oculus/investigate/window.lua", start_line = 40 } }
  local scaffold = agent.generate_test_scaffold(fake_entity, fake_callers)
  assert(scaffold:find("calculate_impact", 1, true), "expected calculate_impact in scaffold")
  assert(scaffold:find("open_window", 1, true), "expected open_window in scaffold")
  -- Refactor plan generation
  local fake_crossing = { source_subsystem = "lua.investigate", target_subsystem = "crates.oculus_engine", risk_level = "high", details = "Direct boundary crossing" }
  local plan = agent.generate_refactor_plan(fake_crossing)
  assert(plan:find("Refactor Plan", 1, true), "expected Refactor Plan in plan")
  assert(plan:find("lua.investigate", 1, true), "expected source subsystem in plan")
  -- Agent synthesis
  local agent_done = false
  local synthesized_derived = nil

  agent.synthesize(dynamics_bundle, {}, function(derived, _)
    synthesized_derived = derived
    agent_done = true
  end)

  assert(agent_done, "expected agent synthesis to complete")
  assert(synthesized_derived ~= nil, "expected synthesized derived")
  assert(#synthesized_derived.hypotheses > 0, "expected hypotheses")
  -- Window rendering of derived investigation
  dynamics_bundle.derived = synthesized_derived
  window.open(dynamics_bundle, { width = 120, height = 40 })
  local derived_tree = table.concat(vim.api.nvim_buf_get_lines(window.state.buf, 0, -1, false), "\n")
  assert(derived_tree:find("AGENT HYPOTHESES & ADVERSARIAL VERIFICATIONS", 1, true), "expected hypotheses header")
  assert(derived_tree:find("CONNECTED ACTIONS & EXPERIMENTS", 1, true), "expected connected actions header")
  assert(derived_tree:find("Claim", 1, true), "expected Claim in tree")
  -- Move cursor to hypothesis and claim to verify ledger rendering
  local hyp_line = nil
  local claim_line = nil

  for l, prov in pairs(window.state.line_provenance) do
    if prov.kind == "agent_hypothesis" then
      hyp_line = l
    elseif prov.kind == "claim_verification" then
      claim_line = l
    end
  end

  assert(hyp_line ~= nil, "expected hyp_line")
  assert(claim_line ~= nil, "expected claim_line")
  vim.api.nvim_win_set_cursor(window.state.win, { hyp_line, 0 })
  vim.cmd("doautocmd CursorMoved")
  local hyp_ledger = table.concat(vim.api.nvim_buf_get_lines(window.state.ledger_buf, 0, -1, false), "\n")
  assert(hyp_ledger:find("Agent Derived Hypothesis", 1, true), "expected hypothesis in ledger")
  vim.api.nvim_win_set_cursor(window.state.win, { claim_line, 0 })
  vim.cmd("doautocmd CursorMoved")
  local claim_ledger = table.concat(vim.api.nvim_buf_get_lines(window.state.ledger_buf, 0, -1, false), "\n")
  assert(claim_ledger:find("Adversarial Reality Check", 1, true), "expected adversarial check in ledger")
  assert(claim_ledger:find("ADVERSARIAL VERDICT", 1, true), "expected verdict in ledger")
  window.close()
  assert(window.state.win == nil and window.state.ledger_win == nil, "expected windows closed after test 11")
  print("ALL INVESTIGATE TESTS PASSED!")
end
