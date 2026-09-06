local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)
local oculus = require("oculus")
local engine = require("oculus.investigate.engine")
local window = require("oculus.investigate.window")
local navigation = require("oculus.navigation")

do
  -- Test 1: Navigation resolves investigate keys
  local nav = navigation.resolve()
  assert(nav.investigate == "g", "expected nav.investigate to be 'g'")
  assert(nav.investigate_id == "G", "expected nav.investigate_id to be 'G'")
  local nav_hjkl = navigation.resolve("hjkl")
  assert(nav_hjkl.investigate == "g")
  assert(nav_hjkl.investigate_id == "G")
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
  -- Test 4: Window rendering (single window by default)
  window.open(received_bundle)
  assert(window.state.win ~= nil and vim.api.nvim_win_is_valid(window.state.win), "expected window to be open and valid")
  assert(window.state.buf ~= nil and vim.api.nvim_buf_is_valid(window.state.buf), "expected buffer to be open and valid")
  assert(window.state.ledger_win == nil, "expected no adjacent ledger window by default")
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

  window.open(forge_bundle, { width = 120, height = 40, split = true })
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

  window.open(dynamics_bundle, { width = 120, height = 40, split = true })
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
  window.open(dynamics_bundle, { width = 120, height = 40, split = true })
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
  -- Test 12: Vertical Slice: Executive Brief, Worktree Harness & Candidate Patches
  local worktree = require("oculus.investigate.worktree")
  local branch_slug = worktree.get_suggested_branch(forge_bundle)
  assert(branch_slug:find("experiment-issue-42", 1, true), "expected suggested branch for issue 42")
  local wt_dir = worktree.get_worktree_dir(root, branch_slug)
  assert(wt_dir:find("experiment-issue-42", 1, true), "expected worktree path with branch slug")
  local test_cmd = worktree.detect_test_cmd(root)
  assert(type(test_cmd) == "table" and #test_cmd >= 2, "expected detected test command")
  -- Candidate patches matrix
  local patches = agent.generate_candidate_patches(forge_bundle)
  assert(patches:find("CANDIDATE PATCH A", 1, true), "expected Candidate Patch A in matrix")
  assert(patches:find("CANDIDATE PATCH B", 1, true), "expected Candidate Patch B in matrix")
  assert(patches:find("Blast Radius", 1, true), "expected blast radius comparison")
  -- Executive brief rendering in window
  window.open(forge_bundle)
  local rendered_eb = table.concat(vim.api.nvim_buf_get_lines(window.state.buf, 0, -1, false), "\n")
  assert(rendered_eb:find("EXECUTIVE BRIEF", 1, true), "expected Executive Brief in rendered window")
  assert(rendered_eb:find("Surface:", 1, true), "expected surface line in executive brief")
  assert(rendered_eb:find("Blast:", 1, true), "expected blast line in executive brief")
  -- Test 13: Dedicated Isolated Investigation Footer Structure & Isolation
  local oculus_win = require("oculus.window")
  -- Setup mock state for main oculus window
  local main_mock_buf = vim.api.nvim_create_buf(false, true)

  local main_mock_win = vim.api.nvim_open_win(main_mock_buf, false, {
    relative = "editor",
    row = 2,
    col = 4,
    width = 100,
    height = 30,
    border = "rounded",
  })

  oculus_win.state = oculus_win.state or {}
  oculus_win.state.win = main_mock_win
  oculus_win.state.buf = main_mock_buf
  oculus_win.render_activity_footer()
  assert(oculus_win.state.footer_win ~= nil and vim.api.nvim_win_is_valid(oculus_win.state.footer_win), "expected main footer window to be valid")
  local prev_main_footer_win = oculus_win.state.footer_win
  -- Open investigate window and verify main footer is closed
  window.open(forge_bundle)
  assert(oculus_win.state.footer_win == nil, "expected oculus_win.state.footer_win to be nil")
  assert(not vim.api.nvim_win_is_valid(prev_main_footer_win), "expected previous main footer window to be closed and invalid")
  -- Check investigate window config has NO border footer
  local inv_win_cfg = vim.api.nvim_win_get_config(window.state.win)
  assert(inv_win_cfg.footer == nil or #inv_win_cfg.footer == 0 or inv_win_cfg.footer[1][1] == "", "expected NO command footer on border of investigate window")
  -- Check dedicated footer window exists and is valid
  assert(window.state.footer_win ~= nil and vim.api.nvim_win_is_valid(window.state.footer_win), "expected investigate footer window to be valid")
  assert(window.state.footer_buf ~= nil and vim.api.nvim_buf_is_valid(window.state.footer_buf), "expected investigate footer buf to be valid")
  -- Check dedicated footer window structure & positioning
  local f_cfg = vim.api.nvim_win_get_config(window.state.footer_win)
  assert(f_cfg.relative == "editor", "expected relative='editor' for footer window")
  assert(f_cfg.height == 2, "expected footer height == 2")
  assert(f_cfg.width == inv_win_cfg.width, "expected footer width == investigate win width")
  assert(f_cfg.row == inv_win_cfg.row + inv_win_cfg.height - 1, "expected footer row == row + height - 1")
  assert(f_cfg.col == inv_win_cfg.col + 1, "expected footer col == col + 1")
  assert(f_cfg.zindex == 65, "expected footer zindex == 65")
  -- Check footer content in tree view
  local f_lines = vim.api.nvim_buf_get_lines(window.state.footer_buf, 0, -1, false)
  assert(#f_lines == 2, "expected 2 lines in footer buffer")
  assert(f_lines[1]:find("─", 1, true), "expected top separator line with ─ in line 1")
  assert(f_lines[2]:find("<CR> jump", 1, true), "expected <CR> jump in tree view footer")
  assert(not f_lines[2]:find("Tab ledger", 1, true), "must not contain Tab ledger in tree view footer")
  assert(not f_lines[2]:find("Tab tree", 1, true), "must not contain Tab tree in tree view footer")
  assert(f_lines[2]:find("e experiment", 1, true), "expected e experiment in tree view footer")
  assert(f_lines[2]:find("p patches", 1, true), "expected p patches in tree view footer")
  assert(f_lines[2]:find("t test", 1, true), "expected t test in tree view footer")
  assert(f_lines[2]:find("r refactor", 1, true), "expected r refactor in tree view footer")
  assert(f_lines[2]:find("a agent", 1, true), "expected a agent in tree view footer")
  assert(f_lines[2]:find("h inspect", 1, true) or f_lines[2]:find("inspect", 1, true), "expected inspect in tree view footer")
  assert(f_lines[2]:find("q close", 1, true), "expected q close in tree view footer")
  -- Must NOT contain main window commands
  assert(not f_lines[2]:find("browser", 1, true), "must not contain main window browser command")
  assert(not f_lines[2]:find("filters", 1, true), "must not contain main window filters command")
  -- Verify Tab is not mapped for jumping in default single-window view
  local tab_map = vim.tbl_filter(function(k) return k.lhs == "<Tab>" end, vim.api.nvim_buf_get_keymap(window.state.buf, "n"))[1]
  assert(tab_map == nil, "expected <Tab> NOT to be mapped in single-window investigate view")
  -- Close investigate window and verify main window footer is restored
  window.close()
  assert(window.state.footer_win == nil, "expected investigate footer_win to be cleared on close")
  assert(window.state.footer_buf == nil, "expected investigate footer_buf to be cleared on close")
  assert(oculus_win.state.footer_win ~= nil and vim.api.nvim_win_is_valid(oculus_win.state.footer_win), "expected main footer window to be restored on investigate close")
  -- Test 14: Target Repository Resolution and Target Header Formatting
  local inv_mod = require("oculus.investigate")
  -- 14a. Target repository info resolution from various sources
  local issue_url = "https://github.com/neovim/neovim/issues/40184"
  local info_url = inv_mod.resolve_target_repository_info(issue_url, {})
  assert(info_url ~= nil, "expected info from issue url")
  assert(info_url.owner == "neovim", "expected owner neovim")
  assert(info_url.repo == "neovim", "expected repo neovim")
  assert(info_url.repository == "neovim/neovim", "expected repository neovim/neovim")
  assert(info_url.forge == "github", "expected forge github")
  local pr_url = "https://github.com/neovim/neovim/pull/1234"
  local info_pr = inv_mod.resolve_target_repository_info(pr_url, {})
  assert(info_pr ~= nil and info_pr.repository == "neovim/neovim")
  local repo_url = "https://github.com/neovim/neovim"
  local info_repo = inv_mod.resolve_target_repository_info(repo_url, {})
  assert(info_repo ~= nil and info_repo.repository == "neovim/neovim")

  local info_ctx = inv_mod.resolve_target_repository_info("#40184", {
    project = { repository = "neovim/neovim", provider = "github" },
  })

  assert(info_ctx ~= nil and info_ctx.repository == "neovim/neovim")
  local info_local = inv_mod.resolve_target_repository_info(nil, { cwd = root })
  assert(info_local == nil, "expected nil info for local investigation")
  -- 14b. Target repository root resolution
  -- Explicit repo_root override in context
  local done_r1 = false

  inv_mod.resolve_repository_root(info_url, {}, { repo_root = root }, function(p, err)
    assert(p == root, "expected explicit repo_root override")
    assert(err == nil)
    done_r1 = true
  end)

  assert(done_r1, "expected done_r1")
  -- Configured project path in opts.projects
  local done_r2 = false

  inv_mod.resolve_repository_root(info_url, {
    projects = { { repository = "neovim/neovim", path = root } },
  }, {}, function(p, err)
    assert(p == root, "expected root from opts.projects")
    assert(err == nil)
    done_r2 = true
  end)

  assert(done_r2, "expected done_r2")
  -- Configured inspect_repositories
  local done_r3 = false

  inv_mod.resolve_repository_root(info_url, {
    inspect_repositories = { ["neovim/neovim"] = { path = root } },
  }, {}, function(p, err)
    assert(p == root, "expected root from opts.inspect_repositories")
    assert(err == nil)
    done_r3 = true
  end)

  assert(done_r3, "expected done_r3")
  -- Fallback to context.cwd when info is nil
  local done_r4 = false

  inv_mod.resolve_repository_root(nil, {}, { cwd = root }, function(p, err)
    assert(p == root, "expected cwd fallback")
    assert(err == nil)
    done_r4 = true
  end)

  assert(done_r4, "expected done_r4")
  -- 14c. Target description formatting in window
  window.open(forge_bundle)
  local forge_lines = vim.api.nvim_buf_get_lines(window.state.buf, 0, -1, false)
  local header_line = forge_lines[1] or ""

  assert(header_line:find("Target: Issue #42 · \"Refactor AstParser and ChangeCouplingMiner\"", 1, true),
    "expected formatted target description with issue title, got: " .. header_line)

  window.close()
  local pr_bundle = vim.deepcopy(forge_bundle)
  pr_bundle.forge_artifact.kind = "pull_request"
  pr_bundle.forge_artifact.id = "100"
  pr_bundle.forge_artifact.title = "Enhance TreeSitter parsing"
  window.open(pr_bundle)
  local pr_lines = vim.api.nvim_buf_get_lines(window.state.buf, 0, -1, false)
  local pr_header_line = pr_lines[1] or ""

  assert(pr_header_line:find("Target: PR #100 · \"Enhance TreeSitter parsing\"", 1, true),
    "expected formatted PR target description, got: " .. pr_header_line)

  window.close()
  -- Test 15: Loading Spinner on Activity List Items during Investigation
  local activity_mock_buf = vim.api.nvim_create_buf(false, true)

  local activity_mock_win = vim.api.nvim_open_win(activity_mock_buf, false, {
    relative = "editor",
    row = 2,
    col = 4,
    width = 100,
    height = 20,
  })

  local orig_item_text = "    #32812 treesitter: high CPU usage when editing lua files                  2 hours ago"

  vim.api.nvim_buf_set_lines(activity_mock_buf, 0, -1, false, {
    "  ISSUES",
    "  neovim/neovim",
    "",
    orig_item_text,
  })

  oculus_win.state = oculus_win.state or {}
  oculus_win.state.buf = activity_mock_buf
  oculus_win.state.win = activity_mock_win
  oculus_win.state.view = "activity"
  oculus_win.state.activity_title_lines = { [4] = 4 }
  oculus_win.state.line_targets = { [4] = "https://github.com/neovim/neovim/issues/32812" }
  -- Start investigate spinner on line 4
  oculus_win.start_activity_investigate_spinner(4, "https://github.com/neovim/neovim/issues/32812")
  assert(oculus_win.state.investigate_loading_line == 4, "expected loading line to be 4")
  assert(oculus_win.state.investigate_loading_line_text == orig_item_text, "expected saved original line text")
  assert(oculus_win.state.investigate_loading_buf == activity_mock_buf, "expected saved loading buffer")
  local spinning_text = vim.api.nvim_buf_get_lines(activity_mock_buf, 3, 4, false)[1]
  assert(spinning_text:find("⠋", 1, true), "expected initial spinner frame ⠋ on activity item line")
  assert(spinning_text:find("#32812", 1, true), "expected issue number to be preserved")
  assert(spinning_text:find("2 hours ago", 1, true), "expected timestamp to be preserved")
  -- Check highlight in investigate_loading_ns
  local inv_ns = vim.api.nvim_get_namespaces().oculus_investigate_activity_loading
  assert(inv_ns ~= nil, "expected oculus_investigate_activity_loading namespace to exist")
  local marks = vim.api.nvim_buf_get_extmarks(activity_mock_buf, inv_ns, 0, -1, { details = true })
  assert(#marks > 0, "expected extmark highlight for spinner frame")
  -- Advance spinner frame
  oculus_win.state.investigate_loading_frame = 2
  oculus_win._draw_activity_investigate_spinner()
  local frame2_text = vim.api.nvim_buf_get_lines(activity_mock_buf, 3, 4, false)[1]
  assert(frame2_text:find("⠙", 1, true), "expected second spinner frame ⠙ on activity item line")
  -- Stop investigate spinner
  oculus_win.stop_activity_investigate_spinner()
  assert(oculus_win.state.investigate_loading_timer == nil, "expected timer to be nil")
  assert(oculus_win.state.investigate_loading_line == nil, "expected loading line to be cleared")
  local restored_text = vim.api.nvim_buf_get_lines(activity_mock_buf, 3, 4, false)[1]
  assert(restored_text == orig_item_text, "expected line text to be restored exactly to original")
  local marks_after = vim.api.nvim_buf_get_extmarks(activity_mock_buf, inv_ns, 0, -1, {})
  -- Integration: trigger via key mapping or investigate_current with cursor on line 4
  vim.api.nvim_win_set_cursor(activity_mock_win, { 4, 0 })
  local inv_called = false
  local orig_investigate = oculus.investigate

  oculus.investigate = function(target, opts, context, callback)
    inv_called = true
    assert(oculus_win.state.investigate_loading_line == 4, "expected spinner to be active during investigate call")
    local line_during_inv = vim.api.nvim_buf_get_lines(activity_mock_buf, 3, 4, false)[1]
    assert(line_during_inv:find("⠋", 1, true), "expected spinner frame in line during investigation")

    if callback then
      callback(nil, "mock finished")
    end
  end

  oculus_win._investigate_current()
  assert(inv_called, "expected oculus.investigate to be invoked")
  assert(oculus_win.state.investigate_loading_line == nil, "expected spinner stopped after investigate completes")
  local line_after_inv = vim.api.nvim_buf_get_lines(activity_mock_buf, 3, 4, false)[1]
  assert(line_after_inv == orig_item_text, "expected line restored after investigate completion")
  oculus.investigate = orig_investigate
  -- Clean up activity mock window
  pcall(vim.api.nvim_win_close, activity_mock_win, true)
  pcall(vim.api.nvim_buf_delete, activity_mock_buf, { force = true })
  -- Clean up mock main window
  oculus_win.close_activity_footer()
  pcall(vim.api.nvim_win_close, main_mock_win, true)
  pcall(vim.api.nvim_buf_delete, main_mock_buf, { force = true })
  oculus_win.state.win = nil
  oculus_win.state.buf = nil
  -- Test 24: Fact bundle with null/userdata fields (vim.NIL) from vim.json.decode
  local raw_json = '{"metadata":{"repository_root":"."},"entities":[],"relationships":[],"impact":null,"co_changes":[],"entity_histories":[],"invariants":[],"forge_artifact":null,"traceability_links":[],"dynamics":null,"derived":{"hypotheses":[],"unanswered_questions":[],"candidate_patches":[],"adversarial_verdict":"INCONCLUSIVE"}}'
  local decoded_bundle = vim.json.decode(raw_json)
  assert(decoded_bundle.impact == vim.NIL, "expected impact to be vim.NIL prior to window handling")
  window.open(decoded_bundle)
  assert(window.state.win ~= nil and vim.api.nvim_win_is_valid(window.state.win), "expected window open with vim.NIL fields to succeed")
  assert(vim.api.nvim_get_current_win() == window.state.win, "expected investigation window to be focused initially upon load")
  local decoded_lines = vim.api.nvim_buf_get_lines(window.state.buf, 0, -1, false)
  local decoded_text = table.concat(decoded_lines, "\n")
  assert(decoded_text:find("EXECUTIVE BRIEF", 1, true), "expected executive brief in rendered text")
  window.close()
  -- Test 25: "i" is handled as navigation key and not as a custom command in investigate window
  local test_bundle = vim.deepcopy(decoded_bundle)
  window.open(test_bundle)
  assert(window.state.win ~= nil and vim.api.nvim_win_is_valid(window.state.win), "expected window open")
  local inv_buf = window.state.buf
  local keymaps = vim.api.nvim_buf_get_keymap(inv_buf, "n")
  local keymap_by_lhs = {}

  for _, km in ipairs(keymaps) do
    keymap_by_lhs[km.lhs] = km
  end

  -- Verify "i" is mapped to navigation (move up), not inspect or a custom action
  assert(keymap_by_lhs["i"] ~= nil, "expected 'i' to be mapped in investigate window")

  assert(keymap_by_lhs["i"].desc == "Move up in investigation",
    "expected 'i' description to be 'Move up in investigation', got: " .. tostring(keymap_by_lhs["i"].desc))

  assert(keymap_by_lhs["i"].desc ~= "Pivot to Oculus Inspect", "expected 'i' NOT to be mapped to Pivot to Oculus Inspect")
  -- Verify footer does NOT contain "i inspect"
  assert(window.state.footer_buf ~= nil, "expected footer_buf to be valid")
  local footer_lines = vim.api.nvim_buf_get_lines(window.state.footer_buf, 0, -1, false)
  local footer_text = table.concat(footer_lines, "\n")
  assert(not footer_text:find("i inspect", 1, true), "expected footer NOT to have 'i inspect'")
  assert(footer_text:find("h inspect", 1, true), "expected footer to have 'h inspect' for default navigation")
  -- Test cursor movement with navigation keys:
  vim.api.nvim_win_set_cursor(window.state.win, { 5, 0 })
  assert(vim.api.nvim_win_get_cursor(window.state.win)[1] == 5)
  keymap_by_lhs["i"].callback()
  assert(vim.api.nvim_win_get_cursor(window.state.win)[1] == 4, "expected 'i' callback to move cursor up to line 4")
  assert(keymap_by_lhs["k"] ~= nil, "expected 'k' to be mapped in investigate window")
  keymap_by_lhs["k"].callback()
  assert(vim.api.nvim_win_get_cursor(window.state.win)[1] == 5, "expected 'k' callback to move cursor down to line 5")
  window.close()
  -- Test 26: With navigation = "hjkl", "i" is still a navigation key (up) and inspect is "H" (not "i")
  window.open(test_bundle, { navigation = "hjkl" })
  local hjkl_buf = window.state.buf
  local hjkl_maps = vim.api.nvim_buf_get_keymap(hjkl_buf, "n")
  local hjkl_by_lhs = {}

  for _, km in ipairs(hjkl_maps) do
    hjkl_by_lhs[km.lhs] = km
  end

  assert(hjkl_by_lhs["i"] ~= nil, "expected 'i' to be mapped in investigate window under hjkl")
  assert(hjkl_by_lhs["i"].desc == "Move up in investigation", "expected 'i' to remain navigation key under hjkl")
  assert(hjkl_by_lhs["H"] ~= nil, "expected 'H' to be mapped for inspect under hjkl")
  assert(hjkl_by_lhs["H"].desc == "Pivot to Oculus Inspect", "expected 'H' to be Pivot to Oculus Inspect")
  local hjkl_footer_lines = vim.api.nvim_buf_get_lines(window.state.footer_buf, 0, -1, false)
  local hjkl_footer_text = table.concat(hjkl_footer_lines, "\n")
  assert(not hjkl_footer_text:find("i inspect", 1, true), "expected footer NOT to contain 'i inspect' under hjkl")
  assert(hjkl_footer_text:find("H inspect", 1, true), "expected footer to contain 'H inspect' under hjkl")
  window.close()
  -- Test 27: Sub-windows opened from investigate window close investigate window, match main window dimensions, auto-focus, and restore on close
  local oculus_window = require("oculus.window")
  oculus_window.open()
  local main_cfg = oculus_window.window_config()
  local main_win = oculus_window.state.win

  local subwin_bundle = {
    metadata = {
      repository_root = root,
      target = "subwin-target",
    },
    invariants = {
      { rule = "inv1", status = "satisfied" },
    },
    entities = {
      { name = "subwin_fn", file_path = "lua/oculus/init.lua", kind = "function", start_line = 10 },
    },
    impact = {
      direct_callers = { { name = "caller_fn", file_path = "lua/oculus/window.lua", start_line = 20 } },
    },
    dynamics = {
      boundary_crossings = {
        { source_subsystem = "engine", target_subsystem = "ui", details = "subsystem crossing" },
      },
    },
  }

  window.open(subwin_bundle)
  assert(window.state.win ~= nil, "expected investigate window open")
  assert(vim.api.nvim_get_current_win() == window.state.win, "expected investigate window focused")
  local inv_win_id = window.state.win
  -- 'p': Candidate patches
  local curr_buf = window.state.buf
  local p_km = vim.tbl_filter(function(k) return k.lhs == "p" end, vim.api.nvim_buf_get_keymap(curr_buf, "n"))[1]
  assert(p_km ~= nil, "expected 'p' mapped")
  p_km.callback()
  assert(window.state.win == nil, "expected investigate window closed on 'p'")
  assert(not vim.api.nvim_win_is_valid(inv_win_id), "expected orig investigate window closed on 'p'")
  assert(window.state.sub_win ~= nil and vim.api.nvim_win_is_valid(window.state.sub_win), "expected candidate patches window valid")
  assert(vim.api.nvim_get_current_win() == window.state.sub_win, "expected candidate patches window focused")
  local p_win_cfg = vim.api.nvim_win_get_config(window.state.sub_win)
  assert(p_win_cfg.width == main_cfg.width, "expected candidate patches width to match main window")
  assert(p_win_cfg.height == main_cfg.height, "expected candidate patches height to match main window")
  assert(p_win_cfg.row == main_cfg.row, "expected candidate patches row to match main window")
  assert(p_win_cfg.col == main_cfg.col, "expected candidate patches col to match main window")
  assert(p_win_cfg.title == nil or #p_win_cfg.title == 0 or p_win_cfg.title[1][1] == "", "expected NO title on border of candidate patches window")
  assert(p_win_cfg.footer == nil or #p_win_cfg.footer == 0 or p_win_cfg.footer[1][1] == "", "expected NO footer on border of candidate patches window")
  assert(window.state.sub_footer_win ~= nil and vim.api.nvim_win_is_valid(window.state.sub_footer_win), "expected candidate patches bottom footer window")
  local p_f_cfg = vim.api.nvim_win_get_config(window.state.sub_footer_win)
  assert(p_f_cfg.height == 2, "expected bottom footer height to be 2")
  local p_sub_buf = window.state.sub_buf
  local p_close_km = vim.tbl_filter(function(k) return k.lhs == "q" end, vim.api.nvim_buf_get_keymap(p_sub_buf, "n"))[1]
  assert(p_close_km ~= nil, "expected 'q' mapped on candidate patches")
  p_close_km.callback()
  assert(window.state.sub_win == nil, "expected sub_win cleared on 'q'")
  assert(window.state.sub_footer_win == nil, "expected sub_footer_win cleared on 'q'")
  assert(window.state.win ~= nil and vim.api.nvim_win_is_valid(window.state.win), "expected investigate window restored on 'q'")
  assert(vim.api.nvim_get_current_win() == window.state.win, "expected restored investigate window focused")
  -- 't': Invariant test scaffold
  curr_buf = window.state.buf
  inv_win_id = window.state.win
  local t_km = vim.tbl_filter(function(k) return k.lhs == "t" end, vim.api.nvim_buf_get_keymap(curr_buf, "n"))[1]
  assert(t_km ~= nil, "expected 't' mapped")
  t_km.callback()
  assert(window.state.win == nil, "expected investigate window closed on 't'")
  assert(not vim.api.nvim_win_is_valid(inv_win_id), "expected orig investigate window closed on 't'")
  assert(window.state.sub_win ~= nil and vim.api.nvim_win_is_valid(window.state.sub_win), "expected test scaffold window valid")
  assert(vim.api.nvim_get_current_win() == window.state.sub_win, "expected test scaffold window focused")
  local t_win_cfg = vim.api.nvim_win_get_config(window.state.sub_win)
  assert(t_win_cfg.width == main_cfg.width, "expected test scaffold width to match main window")
  assert(t_win_cfg.height == main_cfg.height, "expected test scaffold height to match main window")
  assert(t_win_cfg.title == nil or #t_win_cfg.title == 0 or t_win_cfg.title[1][1] == "", "expected NO title on border of test scaffold window")
  assert(t_win_cfg.footer == nil or #t_win_cfg.footer == 0 or t_win_cfg.footer[1][1] == "", "expected NO footer on border of test scaffold window")
  assert(window.state.sub_footer_win ~= nil and vim.api.nvim_win_is_valid(window.state.sub_footer_win), "expected test scaffold bottom footer window")
  local t_sub_buf = window.state.sub_buf
  local t_close_km = vim.tbl_filter(function(k) return k.lhs == "q" end, vim.api.nvim_buf_get_keymap(t_sub_buf, "n"))[1]
  t_close_km.callback()
  assert(window.state.sub_win == nil)
  assert(window.state.sub_footer_win == nil)
  assert(window.state.win ~= nil and vim.api.nvim_win_is_valid(window.state.win))
  assert(vim.api.nvim_get_current_win() == window.state.win)
  -- 'r': Decoupling refactor plan
  curr_buf = window.state.buf
  inv_win_id = window.state.win
  local r_km = vim.tbl_filter(function(k) return k.lhs == "r" end, vim.api.nvim_buf_get_keymap(curr_buf, "n"))[1]
  assert(r_km ~= nil, "expected 'r' mapped")
  r_km.callback()
  assert(window.state.win == nil, "expected investigate window closed on 'r'")
  assert(not vim.api.nvim_win_is_valid(inv_win_id), "expected orig investigate window closed on 'r'")
  assert(window.state.sub_win ~= nil and vim.api.nvim_win_is_valid(window.state.sub_win), "expected refactor plan window valid")
  assert(vim.api.nvim_get_current_win() == window.state.sub_win, "expected refactor plan window focused")
  local r_win_cfg = vim.api.nvim_win_get_config(window.state.sub_win)
  assert(r_win_cfg.width == main_cfg.width, "expected refactor plan width to match main window")
  assert(r_win_cfg.height == main_cfg.height, "expected refactor plan height to match main window")
  assert(r_win_cfg.title == nil or #r_win_cfg.title == 0 or r_win_cfg.title[1][1] == "", "expected NO title on border of refactor plan window")
  assert(r_win_cfg.footer == nil or #r_win_cfg.footer == 0 or r_win_cfg.footer[1][1] == "", "expected NO footer on border of refactor plan window")
  assert(window.state.sub_footer_win ~= nil and vim.api.nvim_win_is_valid(window.state.sub_footer_win), "expected refactor plan bottom footer window")
  local r_sub_buf = window.state.sub_buf
  local r_close_km = vim.tbl_filter(function(k) return k.lhs == "q" end, vim.api.nvim_buf_get_keymap(r_sub_buf, "n"))[1]
  r_close_km.callback()
  assert(window.state.sub_win == nil)
  assert(window.state.sub_footer_win == nil)
  assert(window.state.win ~= nil and vim.api.nvim_win_is_valid(window.state.win))
  assert(vim.api.nvim_get_current_win() == window.state.win)
  -- 'e': Experiment UI
  curr_buf = window.state.buf
  inv_win_id = window.state.win
  local e_km = vim.tbl_filter(function(k) return k.lhs == "e" end, vim.api.nvim_buf_get_keymap(curr_buf, "n"))[1]
  assert(e_km ~= nil, "expected 'e' mapped")
  e_km.callback()
  assert(window.state.win == nil, "expected investigate window closed on 'e'")
  assert(not vim.api.nvim_win_is_valid(inv_win_id), "expected orig investigate window closed on 'e'")
  assert(window.state.sub_win ~= nil and vim.api.nvim_win_is_valid(window.state.sub_win), "expected experiment UI valid")
  assert(vim.api.nvim_get_current_win() == window.state.sub_win, "expected experiment UI focused")
  local e_win_cfg = vim.api.nvim_win_get_config(window.state.sub_win)
  assert(e_win_cfg.width == main_cfg.width, "expected experiment UI width to match main window")
  assert(e_win_cfg.height == main_cfg.height, "expected experiment UI height to match main window")
  assert(e_win_cfg.row == main_cfg.row, "expected experiment UI row to match main window")
  assert(e_win_cfg.col == main_cfg.col, "expected experiment UI col to match main window")
  assert(e_win_cfg.title == nil or #e_win_cfg.title == 0 or e_win_cfg.title[1][1] == "", "expected NO title on border of experiment UI window")
  assert(e_win_cfg.footer == nil or #e_win_cfg.footer == 0 or e_win_cfg.footer[1][1] == "", "expected NO footer on border of experiment UI window")
  assert(window.state.sub_footer_win ~= nil and vim.api.nvim_win_is_valid(window.state.sub_footer_win), "expected experiment UI bottom footer window")
  -- Press 'p' from within experiment UI
  local exp_ui_win = window.state.sub_win
  local exp_ui_buf = window.state.sub_buf
  local exp_p_km = vim.tbl_filter(function(k) return k.lhs == "p" end, vim.api.nvim_buf_get_keymap(exp_ui_buf, "n"))[1]
  assert(exp_p_km ~= nil, "expected 'p' mapped in experiment UI")
  exp_p_km.callback()
  local exp_p_win = vim.api.nvim_get_current_win()
  assert(exp_p_win ~= exp_ui_win, "expected separate window for candidate patches from exp UI")
  local exp_p_cfg = vim.api.nvim_win_get_config(exp_p_win)
  assert(exp_p_cfg.width == main_cfg.width, "expected exp UI candidate patches width to match main window")
  assert(exp_p_cfg.height == main_cfg.height, "expected exp UI candidate patches height to match main window")
  assert(exp_p_cfg.title == nil or #exp_p_cfg.title == 0 or exp_p_cfg.title[1][1] == "", "expected NO title on border of exp UI candidate patches window")
  assert(exp_p_cfg.footer == nil or #exp_p_cfg.footer == 0 or exp_p_cfg.footer[1][1] == "", "expected NO footer on border of exp UI candidate patches window")
  local exp_p_buf = vim.api.nvim_win_get_buf(exp_p_win)
  local exp_p_close_km = vim.tbl_filter(function(k) return k.lhs == "q" end, vim.api.nvim_buf_get_keymap(exp_p_buf, "n"))[1]
  exp_p_close_km.callback()
  assert(not vim.api.nvim_win_is_valid(exp_p_win), "expected exp UI candidate patches closed")
  assert(vim.api.nvim_get_current_win() == exp_ui_win, "expected focus back to experiment UI")
  -- Close experiment UI
  local exp_ui_close_km = vim.tbl_filter(function(k) return k.lhs == "q" end, vim.api.nvim_buf_get_keymap(exp_ui_buf, "n"))[1]
  exp_ui_close_km.callback()
  assert(window.state.sub_win == nil)
  assert(window.state.sub_footer_win == nil)
  assert(window.state.win ~= nil and vim.api.nvim_win_is_valid(window.state.win))
  assert(vim.api.nvim_get_current_win() == window.state.win)
  -- Close investigate window
  window.close()
  assert(window.state.win == nil)
  assert(vim.api.nvim_get_current_win() == main_win, "expected main Oculus window focused")
  -- Clean up main Oculus window
  oculus_window.close()
  assert(oculus_window.state.win == nil)
  -- Test 28: Provenance ledger is part of main investigate window at bottom of page
  window.open(forge_bundle)
  assert(window.state.win ~= nil and vim.api.nvim_win_is_valid(window.state.win), "expected window open")
  assert(window.state.ledger_win == nil, "expected no separate ledger window in default investigate view")
  assert(window.state.ledger_start_line ~= nil and window.state.ledger_start_line > 10, "expected ledger_start_line recorded")
  local all_lines = vim.api.nvim_buf_get_lines(window.state.buf, 0, -1, false)
  local all_text = table.concat(all_lines, "\n")
  assert(all_text:find("DETERMINISTIC PROVENANCE LEDGER & AUDIT TRAIL", 1, true), "expected provenance ledger header in main buffer")
  assert(all_text:find("EVIDENCE GRAPH INVENTORY & REPOSITORY STATE", 1, true), "expected inventory in main buffer")
  assert(all_text:find("VERIFIED GROUND-TRUTH INVARIANTS", 1, true), "expected verified invariants in main buffer")
  -- Tab key is NOT mapped for jumping
  local orig_buf = window.state.buf
  local tab_km = vim.tbl_filter(function(k) return k.lhs == "<Tab>" end, vim.api.nvim_buf_get_keymap(orig_buf, "n"))[1]
  assert(tab_km == nil, "expected no <Tab> mapping on main buffer for ledger jump")
  -- Footer commands remain constant without Tab jump prompts
  local f_lines = vim.api.nvim_buf_get_lines(window.state.footer_buf, 0, -1, false)
  assert(not f_lines[2]:find("Tab ledger", 1, true), "must not contain Tab ledger in footer")
  assert(not f_lines[2]:find("Tab tree", 1, true), "must not contain Tab tree in footer")
  assert(f_lines[2]:find("e experiment", 1, true), "expected e experiment in footer")
  assert(f_lines[2]:find("p patches", 1, true), "expected p patches in footer")
  window.close()
  assert(window.state.win == nil and window.state.footer_win == nil, "expected clean close")
  -- Test 29: Collapsible / foldable sections in investigate window with l, j, and <CR>
  window.open(forge_bundle)
  assert(window.state.win ~= nil and vim.api.nvim_win_is_valid(window.state.win))
  local test_buf = window.state.buf
  local buf_lines = vim.api.nvim_buf_get_lines(test_buf, 0, -1, false)
  -- Verify initial open arrows are downward (▾)
  local found_down_arrow = false

  for _, line in ipairs(buf_lines) do
    if line:find("▾", 1, true) then
      found_down_arrow = true
      break
    end
  end

  assert(found_down_arrow, "expected downward arrows ▾ for open sections by default")
  -- Find the header line for AFFECTED SEMANTIC ENTITIES
  local entities_header_line = nil

  for idx, line in ipairs(buf_lines) do
    if line:find("AFFECTED SEMANTIC ENTITIES", 1, true) then
      entities_header_line = idx
      assert(line:find("▾", 1, true), "expected entities header to have ▾ when open")
      break
    end
  end

  assert(entities_header_line ~= nil, "expected to find entities header line")
  -- Extract keymaps
  local buf_keymaps = vim.api.nvim_buf_get_keymap(test_buf, "n")
  local cr_km = vim.tbl_filter(function(k) return k.lhs == "<CR>" end, buf_keymaps)[1]
  local l_km = vim.tbl_filter(function(k) return k.lhs == "l" end, buf_keymaps)[1]
  local j_km = vim.tbl_filter(function(k) return k.lhs == "j" end, buf_keymaps)[1]
  assert(cr_km ~= nil, "expected <CR> mapped")
  assert(l_km ~= nil, "expected l mapped")
  assert(j_km ~= nil, "expected j mapped")
  -- 1. On section header: press <CR> to close section
  vim.api.nvim_win_set_cursor(window.state.win, { entities_header_line, 0 })
  cr_km.callback()
  -- After closing: header must face right (▸) and content lines must be hidden
  local lines_after_close = vim.api.nvim_buf_get_lines(test_buf, 0, -1, false)
  local closed_header = lines_after_close[entities_header_line]
  assert(closed_header:find("▸", 1, true), "expected header arrow to face right ▸ when closed: " .. tostring(closed_header))
  assert(not closed_header:find("▾", 1, true), "header must not have ▾ when closed")
  assert(window.state.collapsed_sections["entities"] == true, "expected entities marked collapsed in state")
  -- Check that content lines are collapsed (e.g. entity line not present right below header)
  local next_line = lines_after_close[entities_header_line + 1] or ""
  assert(not next_line:find("├─ [", 1, true), "expected content lines hidden when collapsed")
  -- 2. On closed section header: press 'l' to open section
  vim.api.nvim_win_set_cursor(window.state.win, { entities_header_line, 0 })
  l_km.callback()
  local lines_after_open = vim.api.nvim_buf_get_lines(test_buf, 0, -1, false)
  local opened_header = lines_after_open[entities_header_line]
  assert(opened_header:find("▾", 1, true), "expected header arrow to face down ▾ when opened via 'l'")
  assert(window.state.collapsed_sections["entities"] == nil, "expected entities not collapsed in state")
  local opened_next_line = lines_after_open[entities_header_line + 1] or ""
  assert(opened_next_line:find("├─ [", 1, true), "expected content lines restored when opened via 'l'")
  -- 3. On open section header: press 'j' to close section
  vim.api.nvim_win_set_cursor(window.state.win, { entities_header_line, 0 })
  j_km.callback()
  local lines_after_j_close = vim.api.nvim_buf_get_lines(test_buf, 0, -1, false)
  local j_closed_header = lines_after_j_close[entities_header_line]
  assert(j_closed_header:find("▸", 1, true), "expected header arrow to face right ▸ when closed via 'j'")
  assert(window.state.collapsed_sections["entities"] == true)
  -- 4. On closed section header: press <CR> to open section
  vim.api.nvim_win_set_cursor(window.state.win, { entities_header_line, 0 })
  cr_km.callback()
  local lines_after_cr_open = vim.api.nvim_buf_get_lines(test_buf, 0, -1, false)
  local cr_opened_header = lines_after_cr_open[entities_header_line]
  assert(cr_opened_header:find("▾", 1, true), "expected header arrow to face down ▾ when opened via <CR>")
  -- 5. On a content line of the section: press 'j' to close the section
  local content_line_idx = entities_header_line + 1
  vim.api.nvim_win_set_cursor(window.state.win, { content_line_idx, 0 })
  j_km.callback()
  local lines_after_child_j = vim.api.nvim_buf_get_lines(test_buf, 0, -1, false)
  local child_j_header = lines_after_child_j[entities_header_line]
  assert(child_j_header:find("▸", 1, true), "expected section closed when pressing 'j' on content line")
  local cursor_pos = vim.api.nvim_win_get_cursor(window.state.win)
  assert(cursor_pos[1] == entities_header_line, "expected cursor positioned on section header after content collapse")
  -- 6. Open it back with 'l', then navigate to a non-jumpable content line in executive brief and close with <CR>
  l_km.callback() -- open entities back
  local exec_header_idx = nil

  for idx, line in ipairs(vim.api.nvim_buf_get_lines(test_buf, 0, -1, false)) do
    if line:find("EXECUTIVE BRIEF", 1, true) then
      exec_header_idx = idx
      break
    end
  end

  assert(exec_header_idx ~= nil)
  -- Move cursor to a child content line in executive brief (e.g. Surface or Blast line)
  local exec_child_line = exec_header_idx + 1
  vim.api.nvim_win_set_cursor(window.state.win, { exec_child_line, 0 })
  cr_km.callback()
  local lines_after_exec_child_cr = vim.api.nvim_buf_get_lines(test_buf, 0, -1, false)
  local exec_closed_header = lines_after_exec_child_cr[exec_header_idx]
  assert(exec_closed_header:find("▸", 1, true), "expected executive brief closed when pressing <CR> on content line")
  assert(window.state.collapsed_sections["executive_brief"] == true)
  local exec_cursor = vim.api.nvim_win_get_cursor(window.state.win)
  assert(exec_cursor[1] == exec_header_idx, "expected cursor on executive brief header after collapse")
  -- 7. Close window and check clean reset
  window.close()
  assert(window.state.win == nil)
  assert(vim.tbl_isempty(window.state.collapsed_sections or {}), "expected collapsed_sections reset on full close")
  -- Test: Co-change and implicit architecture sections limit display to 10 items initially
  local many_co_changes = {}

  for i = 1, 20 do
    table.insert(many_co_changes, {
      entity_a = string.format("entity_a_%d.lua", i),
      entity_b = string.format("entity_b_%d.lua", i),
      confidence = 0.85,
      co_change_count = i,
      sample_commits = { "abc1234" },
    })
  end

  local bundle_with_many_co_changes = {
    metadata = { repository_root = root, target = "test" },
    entities = {},
    relationships = {},
    invariants = {},
    co_changes = many_co_changes,
  }

  window.open(bundle_with_many_co_changes)
  assert(window.state.win ~= nil, "expected window open")
  local rendered_lines = vim.api.nvim_buf_get_lines(window.state.buf, 0, -1, false)
  local tree_cc_count = 0
  local ledger_cc_count = 0
  local in_ledger_cc = false

  for _, line in ipairs(rendered_lines) do
    if line:find("CHANGE COUPLING · IMPLICIT ARCHITECTURE", 1, true) then
      -- tree section
    elseif line:find("IMPLICIT ARCHITECTURE & CO-CHANGE PROVENANCE:", 1, true) then
      in_ledger_cc = true
    elseif in_ledger_cc and line:find("^[ ]*$", 1) then
      in_ledger_cc = false
    elseif not in_ledger_cc and line:find("├─ entity_a_", 1, true) then
      tree_cc_count = tree_cc_count + 1
    elseif in_ledger_cc and line:find("• entity_a_", 1, true) then
      ledger_cc_count = ledger_cc_count + 1
    end
  end

  assert(tree_cc_count == 10, string.format("expected 10 tree co-change items, got %d", tree_cc_count))
  assert(ledger_cc_count == 10, string.format("expected 10 ledger co-change items, got %d", ledger_cc_count))
  window.close()
  print("ALL INVESTIGATE TESTS PASSED!")
end
