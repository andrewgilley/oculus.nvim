local M = {}

M.state = {
  buf = nil,
  win = nil,
  bundle = nil,
  line_targets = {},
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
  if is_valid_win(M.state.win) then
    vim.api.nvim_win_close(M.state.win, true)
  end

  if is_valid_buf(M.state.buf) then
    vim.api.nvim_buf_delete(M.state.buf, { force = true })
  end

  M.state.win = nil
  M.state.buf = nil
  M.state.bundle = nil
  M.state.line_targets = {}
end

function M.open(bundle, opts)
  opts = opts or {}
  M.close()
  local columns = vim.o.columns
  local lines = vim.o.lines - vim.o.cmdheight
  local width = dimension(opts.width or 0.88, columns, 40)
  local height = dimension(opts.height or 0.82, lines, 10)
  local row = math.max(0, math.floor((lines - height) / 2) - 1)
  local col = math.max(0, math.floor((columns - width) / 2))
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false

  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    width = width,
    height = height,
    row = row,
    col = col,
    style = "minimal",
    border = opts.border or "rounded",
    title = " Oculus Investigation · Deterministic Evidence ",
    title_pos = "center",
    footer = " <CR> jump to source | [q] close | [?] help ",
    footer_pos = "right",
  })

  vim.wo[win].cursorline = true
  vim.wo[win].wrap = false
  M.state.buf = buf
  M.state.win = win
  M.state.bundle = bundle
  M.state.line_targets = {}
  M.render(buf, bundle)
  M.map_keys(buf)
end

function M.render(buf, bundle)
  if not is_valid_buf(buf) then
    return
  end

  local lines = {}
  local highlights = {}
  local line_targets = {}

  local function add_line(text, hl_group)
    lines[#lines + 1] = text

    if hl_group then
      highlights[#highlights + 1] = { line = #lines - 1, group = hl_group }
    end

    return #lines
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
  add_line(string.format("  Repository: %s   %s   Engine: v%s", repo_name, target_desc, engine_ver), "Title")
  add_line(string.format("  Analyzed:   %s", analyzed), "Comment")
  add_line("", nil)
  -- Invariants
  local invariants = bundle.invariants or {}

  if #invariants > 0 then
    add_line("  VERIFIED INVARIANTS & INTEGRITY", "Special")

    for _, inv in ipairs(invariants) do
      local icon = inv.passed and "✓" or "✗"
      local hl = inv.passed and "DiagnosticOk" or "DiagnosticWarn"
      add_line(string.format("    %s %s: %s", icon, inv.invariant_name, inv.details), hl)
    end

    add_line("", nil)
  end

  -- Affected Entities
  local entities = bundle.entities or {}
  add_line(string.format("  AFFECTED SEMANTIC ENTITIES (%d)", #entities), "Special")

  if #entities == 0 then
    add_line("    No specific AST symbol modifications isolated in this change set.", "Comment")
  else
    for _, e in ipairs(entities) do
      local kind_badge = string.format("[%s]", e.kind:upper())
      local line_idx = add_line(string.format("    %s %s (%s:%d)", kind_badge, e.name, e.file_path, e.start_line), "Identifier")
      line_targets[line_idx] = { file = e.file_path, line = e.start_line }
    end
  end

  add_line("", nil)
  -- Structural Impact & Propagation Surface
  local impact = bundle.impact

  if impact then
    add_line(string.format("  STRUCTURAL IMPACT & PROPAGATION SURFACE (depth: %d)", impact.propagation_depth or 0), "Special")
    local callers = impact.direct_callers or {}
    local tests = impact.affected_tests or {}
    local affected_files = impact.affected_files or {}
    add_line(string.format("    Direct Callers (%d):", #callers), "DiagnosticInfo")

    if #callers == 0 then
      add_line("      None detected in local call graph", "Comment")
    else
      for _, c in ipairs(callers) do
        local line_idx = add_line(string.format("      • %s in %s:%d", c.name, c.file_path, c.start_line), nil)
        line_targets[line_idx] = { file = c.file_path, line = c.start_line }
      end
    end

    add_line(string.format("    Associated Tests (%d):", #tests), "DiagnosticOk")

    if #tests == 0 then
      add_line("      No direct test callers found", "Comment")
    else
      for _, t in ipairs(tests) do
        local line_idx = add_line(string.format("      • %s in %s:%d", t.name, t.file_path, t.start_line), nil)
        line_targets[line_idx] = { file = t.file_path, line = t.start_line }
      end
    end

    add_line(string.format("    Affected Source Files: %d", #affected_files), "Comment")
    add_line("", nil)
  end

  -- Change Coupling (Implicit Architecture)
  local co_changes = bundle.co_changes or {}

  if #co_changes > 0 then
    add_line(string.format("  CHANGE COUPLING · IMPLICIT ARCHITECTURE (%d pairs)", math.min(10, #co_changes)), "Special")

    for i = 1, math.min(8, #co_changes) do
      local cc = co_changes[i]
      local pct = math.floor(cc.confidence * 100)
      local line_idx = add_line(string.format("    • %s ↔ %s   [%d%% co-change | %d commits]", cc.entity_a, cc.entity_b, pct, cc.co_change_count), nil)
      line_targets[line_idx] = { file = cc.entity_a, line = 1 }
    end

    add_line("", nil)
  end

  -- Entity History & Lineage
  local histories = bundle.entity_histories or {}

  if #histories > 0 then
    add_line("  SEMANTIC ENTITY LINEAGE", "Special")

    for _, h in ipairs(histories) do
      local authors_str = table.concat(h.authors, ", ")

      if authors_str == "" then
        authors_str = "Unknown"
      end

      add_line(string.format("    • %s: %d commits, authors: %s", h.qualified_name, h.total_commits, authors_str), "Comment")
    end

    add_line("", nil)
  end

  M.state.line_targets = line_targets
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

function M.map_keys(buf)
  local function map(key, fn, desc)
    vim.keymap.set("n", key, fn, { buffer = buf, silent = true, nowait = true, desc = desc })
  end

  map("q", M.close, "Close investigation")
  map("<Esc>", M.close, "Close investigation")
  map("<C-c>", M.close, "Close investigation")

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
