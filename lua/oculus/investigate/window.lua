local M = {}

M.state = {
  buf = nil,
  win = nil,
  ledger_buf = nil,
  ledger_win = nil,
  bundle = nil,
  line_targets = {},
  line_provenance = {},
}

local function is_valid_win(win)
  return win and vim.api.nvim_win_is_valid(win)
end

local function is_valid_buf(buf)
  return buf and vim.api.nvim_buf_is_valid(buf)
end

local function get_target_window_config(opts)
  opts = opts or {}
  local oculus_window = require("oculus.window")
  local oculus_config = require("oculus").config or {}

  local effective_opts = vim.tbl_deep_extend(
    "force",
    vim.deepcopy(oculus_config),
    oculus_window.state and oculus_window.state.opts or {},
    opts
  )

  -- If main oculus window is currently open, inherit its exact live dimensions and position
  if oculus_window.state and is_valid_win(oculus_window.state.win) then
    local pos = vim.api.nvim_win_get_position(oculus_window.state.win)
    local width = vim.api.nvim_win_get_width(oculus_window.state.win)
    local height = vim.api.nvim_win_get_height(oculus_window.state.win)
    local cfg = vim.api.nvim_win_get_config(oculus_window.state.win)

    return {
      width = width,
      height = height,
      row = pos[1],
      col = pos[2],
      border = cfg.border or effective_opts.border or "rounded",
    }
  end

  -- Otherwise compute via oculus_window.window_config
  return oculus_window.window_config(effective_opts)
end

M.window_config = get_target_window_config

function M.close()
  if is_valid_win(M.state.ledger_win) then
    pcall(vim.api.nvim_win_close, M.state.ledger_win, true)
  end

  if is_valid_buf(M.state.ledger_buf) then
    pcall(vim.api.nvim_buf_delete, M.state.ledger_buf, { force = true })
  end

  if is_valid_win(M.state.win) then
    pcall(vim.api.nvim_win_close, M.state.win, true)
  end

  if is_valid_buf(M.state.buf) then
    pcall(vim.api.nvim_buf_delete, M.state.buf, { force = true })
  end

  M.state.win = nil
  M.state.buf = nil
  M.state.ledger_win = nil
  M.state.ledger_buf = nil
  M.state.bundle = nil
  M.state.line_targets = {}
  M.state.line_provenance = {}
end

function M.open(bundle, opts)
  opts = opts or {}
  M.close()
  local main_cfg = get_target_window_config(opts)
  local width = main_cfg.width
  local height = main_cfg.height
  local row = main_cfg.row
  local col = main_cfg.col
  local border = main_cfg.border or opts.border or "rounded"
  local is_split = (opts.split ~= false) and (width >= 60)
  local left_width = width
  local right_width = 0

  if is_split then
    local available = math.max(20, width - 2)
    left_width = math.floor(available * 0.52)
    right_width = available - left_width
  end

  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false

  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    width = left_width,
    height = height,
    row = row,
    col = col,
    style = "minimal",
    border = border,
    footer = is_split and "  <CR> jump   Tab ledger   t test   r refactor   a agent   h inspect   q close  " or "  <CR> jump   t test   r refactor   a agent   h inspect   q close  ",
    footer_pos = "left",
  })

  vim.wo[win].cursorline = true
  vim.wo[win].wrap = false

  local winhl = table.concat({
    "Normal:OculusNormal",
    "NormalFloat:OculusNormal",
    "FloatBorder:OculusBorder",
    "FloatTitle:OculusBorder",
  }, ",")

  pcall(function() vim.wo[win].winhighlight = winhl end)
  local ledger_buf = nil
  local ledger_win = nil

  if is_split then
    ledger_buf = vim.api.nvim_create_buf(false, true)
    vim.bo[ledger_buf].buftype = "nofile"
    vim.bo[ledger_buf].bufhidden = "wipe"
    vim.bo[ledger_buf].swapfile = false

    ledger_win = vim.api.nvim_open_win(ledger_buf, false, {
      relative = "editor",
      width = right_width,
      height = height,
      row = row,
      col = col + left_width + 2,
      style = "minimal",
      border = border,
      footer = "  Tab tree   q close  ",
      footer_pos = "left",
    })

    vim.wo[ledger_win].cursorline = false
    vim.wo[ledger_win].wrap = true
    pcall(function() vim.wo[ledger_win].winhighlight = winhl end)
  end

  M.state.buf = buf
  M.state.win = win
  M.state.ledger_buf = ledger_buf
  M.state.ledger_win = ledger_win
  M.state.bundle = bundle
  M.state.line_targets = {}
  M.state.line_provenance = {}
  M.render(buf, bundle)

  if is_split and ledger_buf then
    M.render_ledger(ledger_buf, M.state.line_provenance[1] or { kind = "overview" })

    -- Cursor tracking in left tree to dynamically update right provenance ledger
    vim.api.nvim_create_autocmd("CursorMoved", {
      buffer = buf,
      callback = function()
        if is_valid_win(M.state.win) and is_valid_buf(M.state.ledger_buf) then
          local cursor = vim.api.nvim_win_get_cursor(M.state.win)
          local line = cursor[1]
          local prov = M.state.line_provenance[line] or { kind = "overview" }
          M.render_ledger(M.state.ledger_buf, prov)
        end
      end,
    })

    M.map_keys(ledger_buf)
  end

  M.map_keys(buf)
end

function M.render(buf, bundle)
  if not is_valid_buf(buf) then
    return
  end

  local lines = {}
  local highlights = {}
  local line_targets = {}
  local line_provenance = {}

  local function add_line(text, hl_group, target, prov)
    lines[#lines + 1] = text
    local line_idx = #lines

    if hl_group then
      highlights[#highlights + 1] = { line = line_idx - 1, group = hl_group }
    end

    if target then
      line_targets[line_idx] = target
    end

    if prov then
      line_provenance[line_idx] = prov
    end

    return line_idx
  end

  local meta = bundle.metadata or {}
  local repo_root = type(meta.repository_root) == "string" and meta.repository_root or ""
  local repo_name = vim.fs.basename(repo_root)

  if repo_name == "" then
    repo_name = repo_root ~= "" and repo_root or "Repository"
  end

  local target_desc = (type(meta.target) == "string" and meta.target ~= "")
      and ("Target: " .. meta.target)
    or "Target: Working tree / HEAD"

  local engine_ver = type(meta.engine_version) == "string" and meta.engine_version or "0.1.0"
  local analyzed = type(meta.analyzed_at) == "string" and meta.analyzed_at or os.date("!%Y-%m-%dT%H:%M:%SZ")
  -- 1. Investigation Target Header & Overview Root
  add_line(string.format("  ▾ %s", target_desc), "Title", nil, { kind = "overview" })
  add_line(string.format("    Repository: %s · Engine: v%s", repo_name, engine_ver), "Comment", nil, { kind = "overview" })
  add_line(string.format("    Analyzed:   %s", analyzed), "Comment", nil, { kind = "overview" })
  add_line("", nil)
  -- 2. Invariants & Reality Check Integrity
  local invariants = bundle.invariants or {}

  if #invariants > 0 then
    add_line("  ▾ VERIFIED INVARIANTS & INTEGRITY", "Special", nil, { kind = "overview" })

    for _, inv in ipairs(invariants) do
      local icon = inv.passed and "✓" or "✗"
      local hl = inv.passed and "DiagnosticOk" or "DiagnosticWarn"

      add_line(string.format("    %s %s: %s", icon, inv.invariant_name, inv.details), hl, nil, {
        kind = "invariant",
        invariant = inv,
      })
    end

    add_line("", nil)
  end

  -- 3. Forge Artifact Context
  local forge_art = bundle.forge_artifact

  if type(forge_art) == "table" and type(forge_art.id) == "string" then
    local kind_label = forge_art.kind == "pull_request" and "Pull Request"
      or (forge_art.kind:sub(1, 1):upper() .. forge_art.kind:sub(2))

    local title_str = type(forge_art.title) == "string" and forge_art.title or "Untitled"
    local author_str = type(forge_art.author) == "string" and (" by @" .. forge_art.author) or ""
    local state_badge = type(forge_art.state) == "string" and string.format("[%s]", forge_art.state:upper()) or ""

    add_line(string.format("  ▾ FORGE CONTEXT: %s #%s %s%s", kind_label, forge_art.id, state_badge, author_str), "Title", nil, {
      kind = "forge_artifact",
      artifact = forge_art,
    })

    add_line(string.format("      Title: \"%s\"", title_str), "Normal", nil, {
      kind = "forge_artifact",
      artifact = forge_art,
    })

    if type(forge_art.url) == "string" and forge_art.url ~= "" then
      add_line(string.format("      URL:   %s", forge_art.url), "Comment", nil, {
        kind = "forge_artifact",
        artifact = forge_art,
      })
    end

    add_line("", nil)
  end

  -- 4. Forge-to-Code Traceability Candidates
  local trace_links = bundle.traceability_links or {}

  if #trace_links > 0 then
    add_line(string.format("  ▾ FORGE-TO-CODE TRACEABILITY LINKS (%d candidates)", #trace_links), "Special", nil, { kind = "overview" })

    for _, link in ipairs(trace_links) do
      local pct = math.floor((link.confidence or 0.8) * 100)
      local target_e = link.target_entity or {}
      local badge = string.format("[%d%% MATCH]", pct)
      local disp = string.format("    ├─ %s %s (%s:%d)", badge, target_e.qualified_name or target_e.name or "unknown", target_e.file_path or "", target_e.start_line or 1)

      add_line(disp, "DiagnosticInfo", { file = target_e.file_path, line = target_e.start_line }, {
        kind = "traceability_link",
        link = link,
      })
    end

    add_line("", nil)
  end

  -- Index histories by entity id
  local history_lookup = {}

  for _, h in ipairs(bundle.entity_histories or {}) do
    history_lookup[h.entity_id] = h
  end

  -- 5. Affected Semantic Entities & Composite Paths (Entity -> Callers -> Tests -> Lineage)
  local entities = bundle.entities or {}
  add_line(string.format("  ▾ AFFECTED SEMANTIC ENTITIES (%d)", #entities), "Special", nil, { kind = "overview" })

  if #entities == 0 then
    add_line("    No specific AST symbol modifications isolated in this change set.", "Comment", nil, { kind = "overview" })
  else
    local impact = bundle.impact
    local callers = impact and impact.direct_callers or {}
    local tests = impact and impact.affected_tests or {}

    for _, e in ipairs(entities) do
      local kind_badge = string.format("[%s]", e.kind:upper())
      local entity_line = string.format("    ├─ %s %s (%s:%d)", kind_badge, e.name, e.file_path, e.start_line)

      add_line(entity_line, "Identifier", { file = e.file_path, line = e.start_line }, {
        kind = "entity",
        entity = e,
        history = history_lookup[e.id],
      })

      -- Nested Callers under Entity
      if #callers > 0 then
        for _, c in ipairs(callers) do
          local caller_line = string.format("    │  ├─ Caller: %s (%s:%d)", c.name, c.file_path, c.start_line)

          add_line(caller_line, "DiagnosticInfo", { file = c.file_path, line = c.start_line }, {
            kind = "caller",
            caller = c,
            target = e,
          })
        end
      end

      -- Nested Tests under Entity
      if #tests > 0 then
        for _, t in ipairs(tests) do
          local test_line = string.format("    │  ├─ Test: %s (%s:%d)", t.name, t.file_path, t.start_line)

          add_line(test_line, "DiagnosticOk", { file = t.file_path, line = t.start_line }, {
            kind = "test",
            test = t,
            target = e,
          })
        end
      end

      -- Nested Lineage under Entity
      local h = history_lookup[e.id]

      if h then
        local authors_str = table.concat(h.authors, ", ")
        local lineage_line = string.format("    │  └─ Lineage: %d commits · authors: %s", h.total_commits, authors_str ~= "" and authors_str or "Unknown")

        add_line(lineage_line, "Comment", { file = e.file_path, line = e.start_line }, {
          kind = "entity",
          entity = e,
          history = h,
        })
      end
    end
  end

  add_line("", nil)
  -- 6. Change Coupling & Implicit Architecture
  local co_changes = bundle.co_changes or {}

  if #co_changes > 0 then
    add_line(string.format("  ▾ CHANGE COUPLING · IMPLICIT ARCHITECTURE (%d pairs)", math.min(10, #co_changes)), "Special", nil, { kind = "overview" })

    for i = 1, math.min(8, #co_changes) do
      local cc = co_changes[i]
      local pct = math.floor(cc.confidence * 100)
      local line_text = string.format("    ├─ %s ↔ %s [%d%% co-change | %d commits]", cc.entity_a, cc.entity_b, pct, cc.co_change_count)

      add_line(line_text, "DiagnosticWarn", { file = cc.entity_a, line = 1 }, {
        kind = "co_change",
        co_change = cc,
      })
    end

    add_line("", nil)
  end

  -- 7. Architectural Dynamics (Boundary Crossings, Subsystem Instability, Historical Precedents)
  local dynamics = bundle.dynamics

  if dynamics then
    local crossings = dynamics.boundary_crossings or {}

    if #crossings > 0 then
      add_line(string.format("  ▾ ARCHITECTURAL BOUNDARY CROSSINGS (%d)", #crossings), "Special", nil, { kind = "overview" })

      for _, bc in ipairs(crossings) do
        local risk_tag = string.format("[%s RISK]", (bc.risk_level or "low"):upper())
        local hl = (bc.risk_level == "high") and "DiagnosticError" or ((bc.risk_level == "medium") and "DiagnosticWarn" or "DiagnosticInfo")
        local line_text = string.format("    ├─ %s %s ➔ %s (%s ➔ %s)", risk_tag, bc.source_subsystem, bc.target_subsystem, bc.source_entity, bc.target_entity)

        add_line(line_text, hl, nil, {
          kind = "boundary_crossing",
          crossing = bc,
        })
      end

      add_line("", nil)
    end

    local instabilities = dynamics.subsystem_instabilities or {}

    if #instabilities > 0 then
      add_line(string.format("  ▾ SUBSYSTEM INSTABILITY & RISK ALERTS (%d)", #instabilities), "Special", nil, { kind = "overview" })

      for _, inst in ipairs(instabilities) do
        local hl = (inst.risk_category == "HIGH_CHURN_UNTESTED" or inst.risk_category == "COUPLING_HUB") and "DiagnosticError"
          or (inst.risk_category == "SINGLE_MAINTAINER_BOTTLENECK" and "DiagnosticWarn" or "DiagnosticOk")

        local maintainer = inst.primary_maintainer and (" · @" .. inst.primary_maintainer) or ""
        local line_text = string.format("    ├─ [%s] %s (instability: %.2f%s)", inst.risk_category, inst.subsystem, inst.instability_score, maintainer)

        add_line(line_text, hl, nil, {
          kind = "subsystem_instability",
          instability = inst,
        })
      end

      add_line("", nil)
    end

    local precedents = dynamics.historical_precedents or {}

    if #precedents > 0 then
      add_line(string.format("  ▾ HISTORICAL PRECEDENTS (%d similar changes)", #precedents), "Special", nil, { kind = "overview" })

      for _, p in ipairs(precedents) do
        local short_oid = p.commit_oid:sub(1, 7)
        local author_str = p.author ~= "" and (" by " .. p.author) or ""
        local line_text = string.format("    ├─ commit:%s%s · \"%s\"", short_oid, author_str, p.message)

        add_line(line_text, "Comment", nil, {
          kind = "historical_precedent",
          precedent = p,
        })
      end

      add_line("", nil)
    end
  end

  -- 8. Agent Hypotheses & Adversarial Verifications (Layers 25-26)
  local derived = bundle.derived

  if derived then
    local hypotheses = derived.hypotheses or {}

    if #hypotheses > 0 then
      local verdict_badge = derived.adversarial_verdict and string.format("[%s]", derived.adversarial_verdict) or ""
      add_line(string.format("  ▾ AGENT HYPOTHESES & ADVERSARIAL VERIFICATIONS (Layers 25-26) %s", verdict_badge), "Title", nil, { kind = "overview" })

      for _, hyp in ipairs(hypotheses) do
        local has_refuted = false
        local all_confirmed = true

        for _, v in ipairs(hyp.verifications or {}) do
          if v.status == "REFUTED" then
            has_refuted = true
          elseif v.status ~= "CONFIRMED" then
            all_confirmed = false
          end
        end

        local status_badge = has_refuted and "[REFUTED ✗]" or (all_confirmed and "[VERIFIED ✓]" or "[HYPOTHESIS ?]")
        local hl = has_refuted and "DiagnosticError" or (all_confirmed and "DiagnosticOk" or "DiagnosticWarn")

        add_line(string.format("    ├─ %s %s", status_badge, hyp.title), hl, nil, {
          kind = "agent_hypothesis",
          hypothesis = hyp,
        })

        for _, claim in ipairs(hyp.claims or {}) do
          local v = nil

          for _, ver in ipairs(hyp.verifications or {}) do
            if ver.claim_id == claim.claim_id then
              v = ver
              break
            end
          end

          local claim_badge = v and string.format("[%s]", v.status) or "[UNVERIFIED]"
          local claim_hl = v and (v.status == "CONFIRMED" and "DiagnosticOk" or (v.status == "REFUTED" and "DiagnosticError" or "DiagnosticWarn")) or "Comment"

          add_line(string.format("    │  ├─ Claim %s: \"%s\"", claim_badge, claim.assertion), claim_hl, nil, {
            kind = "claim_verification",
            claim = claim,
            verification = v,
            hypothesis = hyp,
          })
        end

        for _, act in ipairs(hyp.suggested_actions or {}) do
          add_line(string.format("    │  └─ Action: %s (%s)", act.label, act.description), "Special", nil, {
            kind = "connected_action",
            action = act,
            hypothesis = hyp,
          })
        end
      end

      add_line("", nil)
    end
  end

  -- 9. Connected Actions & Experiments Toolbar
  add_line("  ▾ CONNECTED ACTIONS & EXPERIMENTS", "Special", nil, { kind = "overview" })
  add_line("    ├─ [t] Generate Invariant Test Scaffold (protect callers & prevent regressions)", "Identifier", nil, { kind = "action_hint", action = "test_scaffold" })
  add_line("    ├─ [r] Plan Subsystem Decoupling Refactor (isolate boundary crossings)", "Identifier", nil, { kind = "action_hint", action = "refactor_plan" })
  add_line("    ├─ [a] Synthesize / Re-verify Agent Hypotheses against Ground Truth", "Identifier", nil, { kind = "action_hint", action = "agent_synthesize" })
  add_line("    └─ [i] Pivot to Oculus Inspect (interactive diff & hunk review)", "Identifier", nil, { kind = "action_hint", action = "inspect_pivot" })
  add_line("", nil)
  M.state.line_targets = line_targets
  M.state.line_provenance = line_provenance
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].readonly = true
  -- Apply syntax highlights
  local ns = vim.api.nvim_create_namespace("oculus_investigate_hl")
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)

  for _, hl in ipairs(highlights) do
    vim.api.nvim_buf_add_highlight(buf, ns, hl.group, hl.line, 0, -1)
  end
end

function M.render_ledger(buf, item)
  if not is_valid_buf(buf) then
    return
  end

  item = item or { kind = "overview" }
  local lines = {}
  local highlights = {}

  local function add_line(text, hl_group)
    lines[#lines + 1] = text

    if hl_group then
      highlights[#highlights + 1] = { line = #lines - 1, group = hl_group }
    end
  end

  add_line("  DETERMINISTIC PROVENANCE LEDGER", "Title")
  add_line("  " .. string.rep("═", 48), "Comment")
  add_line("", nil)

  if item.kind == "traceability_link" then
    local link = item.link or {}
    local pct = math.floor((link.confidence or 0.8) * 100)
    local target_e = link.target_entity or {}
    add_line("  NODE: Forge Traceability Edge", "Special")
    add_line(string.format("  CONFIDENCE: [%d%% MATCH] DETERMINISTIC EVIDENCE", pct), "DiagnosticOk")
    add_line("", nil)
    add_line("  EDGE SPECIFICATION:", "Normal")
    add_line(string.format("    Source:   %s", link.forge_item or "forge:artifact"), "Comment")
    add_line(string.format("    Target:   %s", target_e.id or target_e.name or "unknown"), "Identifier")
    add_line("    Relation: REFERENCES (Candidate Implementation)", "Special")
    add_line("", nil)
    add_line("  PROVENANCE & CITATIONS:", "Normal")
    add_line("    Source:     Open Forge Lexical & Semantic Parser", "Comment")
    add_line(string.format("    Confidence: %.2f", link.confidence or 0.8), "Comment")

    if link.match_reason then
      add_line(string.format("    Reason:     %s", link.match_reason), "Comment")
    end

    add_line("", nil)
    local ev_list = link.evidence or {}

    if #ev_list > 0 then
      add_line("  EVIDENCE WITNESS TRAIL:", "Special")

      for _, ev in ipairs(ev_list) do
        add_line(string.format("    • %s", ev), "DiagnosticInfo")
      end

      add_line("", nil)
    end

    add_line("  TARGET ENTITY LOCATION:", "Normal")
    add_line(string.format("    Symbol:   %s", target_e.qualified_name or target_e.name or ""), "Identifier")
    add_line(string.format("    File:     %s:%d-%d", target_e.file_path or "", target_e.start_line or 1, target_e.end_line or 1), "Comment")
  elseif item.kind == "entity" then
    local e = item.entity or {}
    local h = item.history
    add_line(string.format("  NODE: Semantic Entity [%s]", (e.kind or "entity"):upper()), "Special")
    add_line("  STATUS: AST EXTRACTED DETERMINISTIC FACT", "DiagnosticOk")
    add_line("", nil)
    add_line("  SYMBOL SPECIFICATION:", "Normal")
    add_line(string.format("    Name:      %s", e.name or ""), "Identifier")
    add_line(string.format("    Qualified: %s", e.qualified_name or ""), "Comment")
    add_line(string.format("    File:      %s", e.file_path or ""), "Comment")
    add_line(string.format("    Lines:     %d to %d (cols %d-%d)", e.start_line or 1, e.end_line or 1, e.start_col or 1, e.end_col or 1), "Comment")
    add_line("", nil)
    add_line("  PROVENANCE & REPOSITORY STATE:", "Normal")
    add_line("    Parser:    Tree-sitter AST Polyglot Engine", "Comment")
    add_line(string.format("    Git State: %s", e.git_oid or "HEAD (Working Tree)"), "Comment")
    add_line("    Confidence: 1.00 (Exact compiler-level AST range)", "DiagnosticOk")
    add_line("", nil)

    if h then
      add_line("  ARCHITECTURAL LINEAGE & HISTORY:", "Special")
      add_line(string.format("    Total Commits: %d", h.total_commits or 0), "Comment")

      if h.introduction_commit then
        add_line(string.format("    Introduced:    commit:%s", h.introduction_commit), "Comment")
      end

      local authors = table.concat(h.authors or {}, ", ")

      if authors ~= "" then
        add_line(string.format("    Contributors:  %s", authors), "Comment")
      end

      add_line("", nil)
    end
  elseif item.kind == "caller" then
    local c = item.caller or {}
    local target = item.target or {}
    add_line("  NODE: Direct Caller Relationship", "Special")
    add_line("  CONFIDENCE: [95% CONFIDENCE] SYNTACTIC AST GRAPH", "DiagnosticInfo")
    add_line("", nil)
    add_line("  EDGE SPECIFICATION:", "Normal")
    add_line(string.format("    Caller:   %s in %s:%d", c.name or "", c.file_path or "", c.start_line or 1), "Identifier")
    add_line(string.format("    Callee:   %s", target.name or target.qualified_name or ""), "Comment")
    add_line("    Relation: CALLS", "Special")
    add_line("", nil)
    add_line("  PROVENANCE:", "Normal")
    add_line("    Source:   Tree-sitter Call Expression Matcher", "Comment")
    add_line(string.format("    Site:     %s:%d", c.file_path or "", c.start_line or 1), "Comment")
    add_line("    Validity: Verified syntactic invocation node", "DiagnosticOk")
  elseif item.kind == "test" then
    local t = item.test or {}
    local target = item.target or {}
    add_line("  NODE: Associated Test Relationship", "Special")
    add_line("  CONFIDENCE: [90% CONFIDENCE] TEST SUITE COVERAGE", "DiagnosticOk")
    add_line("", nil)
    add_line("  EDGE SPECIFICATION:", "Normal")
    add_line(string.format("    Test:     %s in %s:%d", t.name or "", t.file_path or "", t.start_line or 1), "Identifier")
    add_line(string.format("    Tested:   %s", target.name or target.qualified_name or ""), "Comment")
    add_line("    Relation: TESTED_BY", "Special")
    add_line("", nil)
    add_line("  PROVENANCE:", "Normal")
    add_line("    Source:   ImpactAnalyzer & Test File Detector", "Comment")
    add_line(string.format("    Location: %s:%d", t.file_path or "", t.start_line or 1), "Comment")
  elseif item.kind == "co_change" then
    local co = item.co_change or {}
    local pct = math.floor((co.confidence or 0.5) * 100)
    add_line("  NODE: Implicit Architecture Co-Change", "Special")
    add_line(string.format("  CONFIDENCE: [%d%% STATISTICAL CONFIDENCE] (Jaccard)", pct), "DiagnosticWarn")
    add_line("", nil)
    add_line("  EDGE SPECIFICATION:", "Normal")
    add_line(string.format("    Entity A: %s", co.entity_a or ""), "Identifier")
    add_line(string.format("    Entity B: %s", co.entity_b or ""), "Identifier")
    add_line("    Relation: CO_CHANGES_WITH", "Special")
    add_line("", nil)
    add_line("  PROVENANCE & WITNESS COMMITS:", "Normal")
    add_line("    Source:     Git Commit History Miner", "Comment")
    add_line(string.format("    Frequency:  %d co-changes in history", co.co_change_count or 0), "Comment")
    local commits = co.sample_commits or {}

    for _, c in ipairs(commits) do
      add_line(string.format("    • commit:%s", c), "Comment")
    end
  elseif item.kind == "invariant" then
    local inv = item.invariant or {}
    local icon = inv.passed and "✓ PASSED" or "✗ FAILED"
    local hl = inv.passed and "DiagnosticOk" or "DiagnosticWarn"
    add_line("  NODE: Verified Invariant", "Special")
    add_line(string.format("  INTEGRITY STATUS: %s", icon), hl)
    add_line("", nil)
    add_line(string.format("  RULE:    %s", inv.invariant_name or ""), "Special")
    add_line(string.format("  DETAILS: %s", inv.details or ""), "Normal")
    add_line("", nil)
    add_line("  PROVENANCE:", "Normal")
    add_line("    Source:   Deterministic Fact Checker", "Comment")
    add_line("    Assurance: Ground-truth reality check against DB state", "Comment")
  elseif item.kind == "forge_artifact" then
    local art = item.artifact or {}
    add_line("  NODE: Open Forge Artifact Context", "Special")
    add_line(string.format("  FORGE:    %s", (art.forge or "github"):upper()), "Title")
    add_line(string.format("  KIND:     %s #%s", (art.kind or "item"):upper(), art.id or ""), "Identifier")

    if art.state then
      add_line(string.format("  STATE:    [%s]", art.state:upper()), "DiagnosticOk")
    end

    if art.author then
      add_line(string.format("  AUTHOR:   @%s", art.author), "Comment")
    end

    if art.url then
      add_line(string.format("  URL:      %s", art.url), "Comment")
    end

    add_line("", nil)

    if art.body and art.body ~= "" then
      add_line("  DESCRIPTION SNIPPET:", "Normal")
      local lines_body = vim.split(art.body, "\n")

      for i = 1, math.min(6, #lines_body) do
        add_line("    " .. lines_body[i], "Comment")
      end
    end
  elseif item.kind == "boundary_crossing" then
    local bc = item.crossing or {}
    local hl = (bc.risk_level == "high") and "DiagnosticError" or ((bc.risk_level == "medium") and "DiagnosticWarn" or "DiagnosticInfo")
    add_line("  NODE: Architectural Boundary Crossing", "Special")
    add_line(string.format("  RISK LEVEL: [%s RISK] ARCHITECTURAL ISOLATION", (bc.risk_level or "low"):upper()), hl)
    add_line("", nil)
    add_line("  BOUNDARY TRANSITION:", "Normal")
    add_line(string.format("    Source Subsystem: %s", bc.source_subsystem or "unknown"), "Identifier")
    add_line(string.format("    Target Subsystem: %s", bc.target_subsystem or "unknown"), "Identifier")
    add_line(string.format("    Source Symbol:    %s", bc.source_entity or ""), "Comment")
    add_line(string.format("    Target Symbol:    %s", bc.target_entity or ""), "Comment")
    add_line("    Relation:         CROSSES_BOUNDARY", "Special")
    add_line("", nil)
    add_line("  ANALYSIS & DIAGNOSTICS:", "Normal")
    add_line("    Source:     Subsystem Boundary & Dependency Analyzer", "Comment")
    add_line(string.format("    Diagnosis:  %s", bc.reason or "Cross-subsystem call detected"), "Comment")
    add_line("", nil)
    add_line("  ARCHITECTURAL GUIDANCE:", "Special")

    if bc.risk_level == "high" then
      add_line("    • High risk: Core engine / platform integrity affected.", "DiagnosticError")
      add_line("    • Ensure changes pass interface contracts and integration tests.", "Comment")
    elseif bc.risk_level == "medium" then
      add_line("    • Medium risk: Subsystem boundary leak.", "DiagnosticWarn")
      add_line("    • Consider introducing an abstraction or decoupled event channel.", "Comment")
    else
      add_line("    • Standard cross-module dependency; verify test coverage.", "DiagnosticOk")
    end
  elseif item.kind == "subsystem_instability" then
    local inst = item.instability or {}

    local hl = (inst.risk_category == "HIGH_CHURN_UNTESTED" or inst.risk_category == "COUPLING_HUB") and "DiagnosticError"
      or (inst.risk_category == "SINGLE_MAINTAINER_BOTTLENECK" and "DiagnosticWarn" or "DiagnosticOk")

    add_line("  NODE: Subsystem Instability Metric", "Special")
    add_line(string.format("  RISK CATEGORY: [%s]", inst.risk_category or "UNKNOWN"), hl)
    add_line("", nil)
    add_line("  SUBSYSTEM SPECIFICATION:", "Normal")
    add_line(string.format("    Subsystem:         %s", inst.subsystem or "root"), "Identifier")
    add_line(string.format("    Instability Score: %.2f (0.0=stable, 1.0=volatile)", inst.instability_score or 0), "Special")
    add_line(string.format("    Relative Churn:    %.2f", inst.churn_rate or 0), "Comment")
    add_line(string.format("    Test Coverage:     %.1f%%", (inst.test_coverage_ratio or 0) * 100), "Comment")
    add_line(string.format("    Bus Factor:        %d active contributor(s)", inst.bus_factor or 1), "Comment")

    if inst.primary_maintainer then
      add_line(string.format("    Primary Maintainer: @%s", inst.primary_maintainer), "Comment")
    end

    add_line("", nil)
    add_line("  DIAGNOSTIC RECOMMENDATION:", "Special")

    if inst.risk_category == "HIGH_CHURN_UNTESTED" then
      add_line("    • CRITICAL: Rapidly changing subsystem with zero/low test coverage.", "DiagnosticError")
      add_line("    • Add unit and regression tests before landing cross-cutting modifications.", "Comment")
    elseif inst.risk_category == "SINGLE_MAINTAINER_BOTTLENECK" then
      add_line("    • WARNING: Single maintainer dependency (low bus factor).", "DiagnosticWarn")
      add_line("    • Request review from code owner to avoid knowledge siloing.", "Comment")
    elseif inst.risk_category == "COUPLING_HUB" then
      add_line("    • ATTENTION: Highly coupled central hub. Edits impact multiple dependents.", "DiagnosticWarn")
      add_line("    • Verify callers and downstream contracts carefully.", "Comment")
    else
      add_line("    • Subsystem metrics within normal operating parameters.", "DiagnosticOk")
    end
  elseif item.kind == "historical_precedent" then
    local p = item.precedent or {}
    local pct = math.floor((p.similarity_score or 0) * 100)
    add_line("  NODE: Historical Precedent", "Special")
    add_line(string.format("  SIMILARITY: [%d%% OVERLAP] HISTORICAL CHANGE GRAPH", pct), "DiagnosticOk")
    add_line("", nil)
    add_line("  COMMIT SPECIFICATION:", "Normal")
    add_line(string.format("    Commit:  %s", p.commit_oid or ""), "Identifier")
    add_line(string.format("    Author:  %s", p.author or "Unknown"), "Comment")
    add_line(string.format("    Date:    %s", p.date or ""), "Comment")
    add_line(string.format("    Message: %s", p.message or ""), "Special")
    add_line("", nil)
    local files = p.shared_files or {}

    if #files > 0 then
      add_line(string.format("  SHARED FILES (%d):", #files), "Normal")

      for _, f in ipairs(files) do
        add_line(string.format("    • %s", f), "Comment")
      end

      add_line("", nil)
    end

    if p.outcome_summary then
      add_line("  OUTCOME & PRECEDENT ANALYSIS:", "Special")
      add_line(string.format("    %s", p.outcome_summary), "Comment")
    end
  elseif item.kind == "agent_hypothesis" then
    local hyp = item.hypothesis or {}
    add_line("  NODE: Agent Derived Hypothesis (Layer 25)", "Special")
    add_line(string.format("  CONFIDENCE: [%d%% AGENT CONFIDENCE] (Strictly Grounded)", math.floor((hyp.confidence or 0.8) * 100)), "DiagnosticInfo")
    add_line("", nil)
    add_line(string.format("  HYPOTHESIS: %s", hyp.title or ""), "Title")
    add_line("", nil)
    add_line("  MOTIVATION & RATIONALE:", "Normal")
    add_line(string.format("    %s", hyp.rationale or "Derived from observable repository facts."), "Comment")
    add_line("", nil)
    local claims = hyp.claims or {}

    if #claims > 0 then
      add_line(string.format("  VERIFIABLE CLAIMS (%d):", #claims), "Special")

      for _, cl in ipairs(claims) do
        add_line(string.format("    • [%s] \"%s\"", cl.claim_type, cl.assertion), "Comment")
      end

      add_line("", nil)
    end

    local actions = hyp.suggested_actions or {}

    if #actions > 0 then
      add_line("  SUGGESTED CONNECTED ACTIONS:", "Normal")

      for _, a in ipairs(actions) do
        add_line(string.format("    • %s: %s", a.label, a.description), "Special")
      end
    end
  elseif item.kind == "claim_verification" then
    local cl = item.claim or {}
    local ver = item.verification or {}
    local is_confirmed = ver.status == "CONFIRMED"
    local hl = is_confirmed and "DiagnosticOk" or (ver.status == "REFUTED" and "DiagnosticError" or "DiagnosticWarn")
    add_line("  NODE: Adversarial Reality Check (Layer 26)", "Special")
    add_line(string.format("  ADVERSARIAL VERDICT: [%s]", ver.status or "UNVERIFIED"), hl)
    add_line("", nil)
    add_line("  CLAIM SPECIFICATION:", "Normal")
    add_line(string.format("    Type:      %s", cl.claim_type or ver.claim_type or "unknown"), "Comment")
    add_line(string.format("    Subject:   %s", cl.subject or ""), "Identifier")
    add_line(string.format("    Assertion: \"%s\"", cl.assertion or ver.assertion or ""), "Special")
    add_line("", nil)
    add_line("  DETERMINISTIC VERIFICATION DETAILS:", "Normal")
    add_line(string.format("    Confidence: %.2f (Deterministic AST/Git search)", ver.confidence or 1.0), "Comment")
    add_line(string.format("    Verdict:    %s", ver.details or ""), hl)
    add_line("", nil)
    local ev = ver.deterministic_evidence or {}

    if #ev > 0 then
      add_line("  WITNESS CITATIONS & EVIDENCE:", "Special")

      for _, e in ipairs(ev) do
        add_line(string.format("    • %s", e), "Comment")
      end
    end
  elseif item.kind == "connected_action" or item.kind == "action_hint" then
    local act = item.action or {}
    local label = type(act) == "string" and act or (act.label or act.action_type)
    add_line("  NODE: Connected Investigation Action", "Special")
    add_line("  CAPABILITY: INTERACTIVE AGENTIC WORKFLOW", "DiagnosticOk")
    add_line("", nil)

    if type(act) == "table" then
      add_line(string.format("  ACTION:      %s", act.label or ""), "Title")
      add_line(string.format("  TYPE:        %s", act.action_type or ""), "Identifier")
      add_line(string.format("  DESCRIPTION: %s", act.description or ""), "Normal")

      if act.target then
        add_line(string.format("  TARGET:      %s", act.target), "Comment")
      end

      if act.command_hint then
        add_line(string.format("  COMMAND:     %s", act.command_hint), "Special")
      end
    else
      add_line(string.format("  ACTION: %s", label), "Title")
    end

    add_line("", nil)
    add_line("  EXECUTION INSTRUCTIONS:", "Normal")
    add_line("    • Press [t] to generate Invariant Test Scaffold", "Comment")
    add_line("    • Press [r] to plan Subsystem Decoupling Refactor", "Comment")
    add_line("    • Press [a] to synthesize hypotheses with agent", "Comment")
    add_line("    • Press [h] to pivot to Oculus Inspect diff view", "Comment")
  else -- overview
    local meta = (M.state.bundle and M.state.bundle.metadata) or {}
    local repo_root = meta.repository_root or vim.fn.getcwd()
    add_line("  INVESTIGATION OVERVIEW", "Special")
    add_line(string.format("  Repository: %s", vim.fs.basename(repo_root)), "Identifier")
    add_line(string.format("  Path:       %s", repo_root), "Comment")

    if meta.target then
      add_line(string.format("  Target:     %s", meta.target), "Comment")
    end

    add_line(string.format("  Engine:     v%s", meta.engine_version or "0.1.0"), "Comment")
    add_line(string.format("  Analyzed:   %s", meta.analyzed_at or ""), "Comment")
    add_line("", nil)
    local bundle = M.state.bundle or {}
    local entities_count = #(bundle.entities or {})
    local rels_count = #(bundle.relationships or {})
    local invs_count = #(bundle.invariants or {})
    local trace_count = #(bundle.traceability_links or {})
    local dynamics = bundle.dynamics or {}
    local crossings_count = #(dynamics.boundary_crossings or {})
    local alerts_count = #(dynamics.subsystem_instabilities or {})
    local precs_count = #(dynamics.historical_precedents or {})
    local derived = bundle.derived or {}
    local hyp_count = #(derived.hypotheses or {})
    add_line("  EVIDENCE GRAPH INVENTORY:", "Normal")
    add_line(string.format("    • Modified Entities:     %d", entities_count), "DiagnosticInfo")
    add_line(string.format("    • Relationships w/ Prov: %d", rels_count), "DiagnosticInfo")
    add_line(string.format("    • Traceability Matches:  %d", trace_count), "DiagnosticInfo")
    add_line(string.format("    • Boundary Crossings:    %d", crossings_count), "DiagnosticInfo")
    add_line(string.format("    • Subsystem Risk Alerts: %d", alerts_count), "DiagnosticInfo")
    add_line(string.format("    • Historical Precedents: %d", precs_count), "DiagnosticInfo")
    add_line(string.format("    • Derived Hypotheses:    %d", hyp_count), "DiagnosticInfo")
    add_line(string.format("    • Invariant Assertions:  %d", invs_count), "DiagnosticOk")
    add_line("", nil)
    add_line("  GROUND TRUTH PRINCIPLES:", "Special")
    add_line("    • Left Tree: Composite cause-and-effect paths", "Comment")
    add_line("    • Right Pane: Dynamic provenance audit trail", "Comment")
    add_line("    • Press <CR> on any symbol to jump to source", "Comment")
    add_line("    • Press <Tab> to toggle focus between panes", "Comment")
    add_line("    • Press [t]est scaffold | [r]efactor plan | [a]gent | [h] inspect", "Comment")
  end

  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].readonly = true
  local ns = vim.api.nvim_create_namespace("oculus_investigate_ledger_hl")
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)

  for _, hl in ipairs(highlights) do
    vim.api.nvim_buf_add_highlight(buf, ns, hl.group, hl.line, 0, -1)
  end
end

function M.map_keys(buf)
  local function map(key, fn, desc)
    vim.keymap.set("n", key, fn, { buffer = buf, silent = true, nowait = true, desc = desc })
  end

  map("q", M.close, "Close investigation")
  map("<Esc>", M.close, "Close investigation")
  map("<C-c>", M.close, "Close investigation")

  map("<Tab>", function()
    if is_valid_win(M.state.ledger_win) and is_valid_win(M.state.win) then
      local current = vim.api.nvim_get_current_win()

      if current == M.state.win then
        vim.api.nvim_set_current_win(M.state.ledger_win)
      else
        vim.api.nvim_set_current_win(M.state.win)
      end
    end
  end, "Toggle between tree and provenance ledger")

  map("<CR>", function()
    local win = M.state.win

    if not is_valid_win(win) then
      return
    end

    local cursor = vim.api.nvim_win_get_cursor(win)
    local target = M.state.line_targets[cursor[1]]

    if target and target.file then
      M.close()
      vim.cmd("edit " .. vim.fn.fnameescape(target.file))

      if target.line and target.line > 0 then
        pcall(vim.api.nvim_win_set_cursor, 0, { target.line, 0 })
      end
    end
  end, "Jump to entity source location")

  map("t", function()
    local bundle = M.state.bundle

    if not bundle then
      return
    end

    local agent = require("oculus.investigate.agent")
    local entity = (bundle.entities and bundle.entities[1]) or { name = "target_function", file_path = "src/main.rs" }
    local callers = (bundle.impact and bundle.impact.direct_callers) or {}
    local scaffold = agent.generate_test_scaffold(entity, callers)
    local s_buf = vim.api.nvim_create_buf(false, true)
    local ext = vim.fn.fnamemodify(entity.file_path or "lua", ":e")
    vim.bo[s_buf].filetype = ext == "rs" and "rust" or (ext == "lua" and "lua" or "text")
    vim.api.nvim_buf_set_lines(s_buf, 0, -1, false, vim.split(scaffold, "\n"))

    local s_win = vim.api.nvim_open_win(s_buf, true, {
      relative = "editor",
      width = math.floor(vim.o.columns * 0.7),
      height = math.min(25, vim.o.lines - 8),
      row = math.floor(vim.o.lines * 0.15),
      col = math.floor(vim.o.columns * 0.15),
      border = "rounded",
      title = " Invariant Test Scaffold (Press q to close) ",
      title_pos = "center",
    })

    vim.keymap.set("n", "q", function()
      pcall(vim.api.nvim_win_close, s_win, true)
    end, { buffer = s_buf, silent = true })

    vim.keymap.set("n", "<Esc>", function()
      pcall(vim.api.nvim_win_close, s_win, true)
    end, { buffer = s_buf, silent = true })
  end, "Generate invariant test scaffold")

  map("r", function()
    local bundle = M.state.bundle

    if not bundle then
      return
    end

    local agent = require("oculus.investigate.agent")

    local crossing = (bundle.dynamics and bundle.dynamics.boundary_crossings and bundle.dynamics.boundary_crossings[1])
      or { source_subsystem = "core", target_subsystem = "ui", details = "Direct cross-subsystem call" }

    local plan = agent.generate_refactor_plan(crossing)
    local r_buf = vim.api.nvim_create_buf(false, true)
    vim.bo[r_buf].filetype = "markdown"
    vim.api.nvim_buf_set_lines(r_buf, 0, -1, false, vim.split(plan, "\n"))

    local r_win = vim.api.nvim_open_win(r_buf, true, {
      relative = "editor",
      width = math.floor(vim.o.columns * 0.7),
      height = math.min(25, vim.o.lines - 8),
      row = math.floor(vim.o.lines * 0.15),
      col = math.floor(vim.o.columns * 0.15),
      border = "rounded",
      title = " Decoupling Refactor Plan (Press q to close) ",
      title_pos = "center",
    })

    vim.keymap.set("n", "q", function()
      pcall(vim.api.nvim_win_close, r_win, true)
    end, { buffer = r_buf, silent = true })

    vim.keymap.set("n", "<Esc>", function()
      pcall(vim.api.nvim_win_close, r_win, true)
    end, { buffer = r_buf, silent = true })
  end, "Plan subsystem decoupling refactor")

  map("a", function()
    local bundle = M.state.bundle

    if not bundle then
      return
    end

    local agent = require("oculus.investigate.agent")
    vim.notify("Oculus: Synthesizing and verifying agent hypotheses...", vim.log.levels.INFO)

    agent.synthesize(bundle, {}, function(derived, _)
      if derived then
        bundle.derived = derived

        if is_valid_buf(M.state.buf) then
          M.render(M.state.buf, bundle)
        end

        vim.notify("Oculus: Agent hypotheses verified against ground truth.", vim.log.levels.INFO)
      end
    end)
  end, "Synthesize agent hypotheses")

  local function pivot_to_inspect()
    local bundle = M.state.bundle
    local target = bundle and bundle.metadata and bundle.metadata.target
    M.close()
    local ok, oculus = pcall(require, "oculus")

    if ok and type(oculus.inspect) == "function" then
      oculus.inspect(target)
    end
  end

  map("h", pivot_to_inspect, "Pivot to Oculus Inspect")
  map("i", pivot_to_inspect, "Pivot to Oculus Inspect")
end

return M
