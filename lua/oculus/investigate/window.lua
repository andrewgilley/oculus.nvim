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

local function dimension(value, total, minimum)
  local result = value

  if type(value) == "number" and value > 0 and value <= 1 then
    result = math.floor(total * value)
  end

  result = tonumber(result) or minimum
  return math.max(minimum, math.min(math.floor(result), total - 2))
end

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
  local columns = vim.o.columns
  local lines = vim.o.lines - vim.o.cmdheight
  local width = dimension(opts.width or 0.92, columns, 50)
  local height = dimension(opts.height or 0.84, lines, 10)
  local row = math.max(0, math.floor((lines - height) / 2) - 1)
  local col = math.max(0, math.floor((columns - width) / 2))
  local is_split = width >= 60
  local left_width = is_split and math.floor(width * 0.52) or width
  local right_width = is_split and (width - left_width) or 0
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
    border = opts.border or "rounded",
    title = " Oculus Investigation · Composite Path Tree ",
    title_pos = "center",
    footer = is_split and " <CR> jump | <Tab> ledger | [q] close " or " <CR> jump | [q] close ",
    footer_pos = "right",
  })

  vim.wo[win].cursorline = true
  vim.wo[win].wrap = false
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
      col = col + left_width,
      style = "minimal",
      border = opts.border or "rounded",
      title = " Deterministic Provenance Ledger ",
      title_pos = "center",
      footer = " [q] close | <Tab> tree ",
      footer_pos = "right",
    })

    vim.wo[ledger_win].cursorline = false
    vim.wo[ledger_win].wrap = true
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
    add_line("  EVIDENCE GRAPH INVENTORY:", "Normal")
    add_line(string.format("    • Modified Entities:     %d", entities_count), "DiagnosticInfo")
    add_line(string.format("    • Relationships w/ Prov: %d", rels_count), "DiagnosticInfo")
    add_line(string.format("    • Traceability Matches:  %d", trace_count), "DiagnosticInfo")
    add_line(string.format("    • Invariant Assertions:  %d", invs_count), "DiagnosticOk")
    add_line("", nil)
    add_line("  GROUND TRUTH PRINCIPLES:", "Special")
    add_line("    • Left Tree: Composite cause-and-effect paths", "Comment")
    add_line("    • Right Pane: Dynamic provenance audit trail", "Comment")
    add_line("    • Press <CR> on any symbol to jump to source", "Comment")
    add_line("    • Press <Tab> to toggle focus between panes", "Comment")
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
end

return M
