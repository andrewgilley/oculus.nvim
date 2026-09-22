local M = {}
local client = require("oculus.plexus.client")
local model = require("oculus.investigations.model")
local render = require("oculus.investigations.render")
local ns = vim.api.nvim_create_namespace("oculus_investigations")
local text = model.text

-- Colorschemes can restyle every group; each links to a standard one by default.
local highlights = {
  OculusInvestigationTitle = "Title",
  OculusInvestigationHeading = "Keyword",
  OculusInvestigationMuted = "Comment",
  OculusInvestigationLocation = "Directory",
  OculusInvestigationKey = "Special",
  OculusInvestigationPositive = "DiagnosticOk",
  OculusInvestigationInfo = "DiagnosticInfo",
  OculusInvestigationHint = "DiagnosticHint",
  OculusInvestigationWarning = "DiagnosticWarn",
  OculusInvestigationNegative = "DiagnosticError",
  OculusInvestigationSeparator = "FloatBorder",
}

local function list(value)
  return type(value) == "table" and value or {}
end

local function set_lines(buf, lines)
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
end

local function paint(buf, page)
  if not vim.api.nvim_buf_is_valid(buf) then return end
  set_lines(buf, page.lines)
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)

  for _, mark in ipairs(page.marks) do
    pcall(vim.api.nvim_buf_set_extmark, buf, ns, mark[1] - 1, mark[2], { end_col = mark[3], hl_group = mark[4] })
  end
end

local function scratch()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype, vim.bo[buf].bufhidden = "nofile", "wipe"
  vim.bo[buf].swapfile, vim.bo[buf].filetype = false, "oculus-investigations"
  return buf
end

local function valid_view(value)
  assert(type(value) == "table" and value.schema_version == 1 and value.kind == "selected_change", "Invalid investigation")
  assert(type(value.investigation_id) == "string" and type(value.observation) == "table", "Missing investigation identity")
  assert(vim.tbl_contains({ "completed", "unsupported", "failed" }, value.status), "Invalid investigation status")

  for _, key in ipairs({ "reports", "limitations", "experiments", "evidence" }) do
    assert(type(value[key]) == "table" and vim.islist(value[key]), "Missing investigation " .. key)
  end

  if value.preparations ~= nil and value.preparations ~= vim.NIL then
    assert(type(value.preparations) == "table" and vim.islist(value.preparations), "Invalid investigation preparations")
  end

  if value.reasoning ~= nil and value.reasoning ~= vim.NIL then
    assert(type(value.reasoning) == "table" and value.reasoning.schema_version == 1, "Invalid investigation reasoning")

    for _, key in ipairs({ "claims", "relations", "obligations" }) do
      assert(type(value.reasoning[key]) == "table" and vim.islist(value.reasoning[key]), "Missing reasoning " .. key)
    end
  end
end

-- The float covers the main Oculus window's footprint. Inside it a header,
-- the list and detail panes (side by side, or stacked when narrow), and the
-- footer, each its own window over a frame that draws the rules between them.
local function layout(config)
  local frame = require("oculus.window").full_window_config(config)
  frame.focusable, frame.zindex = false, 50
  local width, height = frame.width, frame.height
  local top, body = 2, math.max(4, height - 4)
  local panes = { footer = { row = height - 2, col = 0, width = width, height = 2 } }

  if width >= 100 then
    local list_width = math.max(38, math.floor((width - 4) * 0.45))
    panes.list = { row = top, col = 1, width = list_width, height = body }
    panes.rule = { col = list_width + 2 }
    panes.detail = { row = top, col = list_width + 4, width = width - list_width - 5, height = body }
  else
    local list_height = math.max(3, math.floor(body * 0.4))
    panes.list = { row = top, col = 1, width = width - 2, height = list_height }
    panes.rule = { row = top + list_height }
    panes.detail = { row = top + list_height + 1, col = 1, width = width - 2, height = math.max(1, body - list_height - 1) }
  end

  return frame, panes
end

local function pane_config(frame_win, pane, focusable, zindex)
  return { relative = "win", win = frame_win, row = pane.row, col = pane.col, width = pane.width, height = pane.height,
    style = "minimal", focusable = focusable, zindex = zindex }
end

local function pretty(value)
  local ok, encoded = pcall(vim.json.encode, value, { indent = "  " })
  return ok and encoded or vim.json.encode(value)
end

-- Both the catalog and details are projections of durable engine records.
function M.open(config, nexus_config, id, submission)
  if M.state and not M.state.closed then M.state.close() end
  config = vim.deepcopy(config or {})
  config.store = vim.fn.fnamemodify(config.store or vim.fn.stdpath("data") .. "/oculus/plexus", ":p")
  for name, link in pairs(highlights) do vim.api.nvim_set_hl(0, name, { link = link, default = true }) end

  local state = { config = config, generation = 0, targets = {}, detail_targets = {}, decisions = {}, previews = {},
    source_win = vim.api.nvim_get_current_win(), mode = "loading", message = "Ready" }

  M.state = state
  state.frame_buf, state.buf, state.detail_buf, state.footer_buf = scratch(), scratch(), scratch(), scratch()
  state.frame_config, state.panes = layout(config)
  state.frame_win = vim.api.nvim_open_win(state.frame_buf, false, state.frame_config)
  state.win = vim.api.nvim_open_win(state.buf, true, pane_config(state.frame_win, state.panes.list, true, 51))
  state.detail_win = vim.api.nvim_open_win(state.detail_buf, false, pane_config(state.frame_win, state.panes.detail, true, 51))
  state.footer_win = vim.api.nvim_open_win(state.footer_buf, false, pane_config(state.frame_win, state.panes.footer, false, 52))

  for _, win in ipairs({ state.frame_win, state.win, state.detail_win, state.footer_win }) do
    vim.wo[win].wrap, vim.wo[win].number, vim.wo[win].relativenumber = false, false, false
    vim.wo[win].signcolumn, vim.wo[win].foldcolumn, vim.wo[win].list = "no", "0", false
    vim.wo[win].cursorline = win == state.win
  end

  -- Every part of the float takes the Normal background of the code beneath
  -- it, as the main Oculus window does, rather than the float background.
  local function paint_background()
    for _, win in ipairs({ state.frame_win, state.win, state.detail_win, state.footer_win }) do
      if vim.api.nvim_win_is_valid(win) then require("oculus.window").apply_overview_highlights(win, state.source_win) end
    end
  end

  paint_background()

  local function focused_detail()
    return not state.closed and vim.api.nvim_get_current_win() == state.detail_win
  end

  local function current_target()
    if state.closed then return nil end

    if focused_detail() then
      return state.detail_targets[vim.api.nvim_win_get_cursor(state.detail_win)[1]]
    end

    return vim.api.nvim_win_is_valid(state.win) and state.targets[vim.api.nvim_win_get_cursor(state.win)[1]] or nil
  end

  -- The finding an action applies to: the one a target names, else the one the
  -- detail pane shows while it has focus, else the one under the list cursor.
  local function selected_finding(target)
    if type(target) == "table" then return target.finding end
    if focused_detail() then return state.detail_finding end
    local current = current_target()
    return current and current.finding
  end

  local function paint_frame()
    if state.closed or not vim.api.nvim_buf_is_valid(state.frame_buf) then return end
    local frame, panes = state.frame_config, state.panes
    local title = " INVESTIGATIONS"
    local message = render.fit(text(state.message), math.max(0, frame.width - vim.fn.strdisplaywidth(title) - 3))
    local gap = math.max(1, frame.width - vim.fn.strdisplaywidth(title) - vim.fn.strdisplaywidth(message) - 1)
    local lines = { title .. string.rep(" ", gap) .. message, " " .. string.rep("─", math.max(1, frame.width - 2)) }
    for row = 3, frame.height do lines[row] = "" end

    if panes.rule.col then
      for row = panes.list.row + 1, panes.list.row + panes.list.height do lines[row] = string.rep(" ", panes.rule.col) .. "│" end
    else
      lines[panes.rule.row + 1] = " " .. string.rep("─", math.max(1, frame.width - 2))
    end

    set_lines(state.frame_buf, lines)
    vim.api.nvim_buf_clear_namespace(state.frame_buf, ns, 0, -1)
    vim.api.nvim_buf_set_extmark(state.frame_buf, ns, 0, 0, { end_col = #title, hl_group = "OculusInvestigationTitle" })
    local level = state.message_level == "error" and "OculusInvestigationWarning" or "OculusInvestigationMuted"
    vim.api.nvim_buf_set_extmark(state.frame_buf, ns, 0, #title + gap, { end_col = #lines[1], hl_group = level })

    for row = 2, #lines do
      local first = lines[row]:find("[│─]")

      if first then
        vim.api.nvim_buf_set_extmark(state.frame_buf, ns, row - 1, first - 1, { end_col = #lines[row], hl_group = "OculusInvestigationSeparator" })
      end
    end
  end

  -- The keys that do something for what the cursor is on. The third field is
  -- a priority: a narrow footer drops the highest numbers first.
  local function footer_keys()
    if state.mode == "catalog" then
      return { { "⏎", "open", 1 }, { "⇥", "detail", 3 }, { "r", "reload", 2 }, { "c", "stop", 3 }, { "q", "close", 1 } }
    end

    if state.mode ~= "investigation" then return { { "c", "stop waiting", 1 }, { "g", "catalog", 2 }, { "q", "close", 1 } } end
    local keys, target = {}, current_target()

    if focused_detail() then
      if target and (target.source or target.action or target.kind == "related") then keys[#keys + 1] = { "⏎", "open", 1 } end
      keys[#keys + 1] = { "⇥", "list", 2 }
    else
      if target and target.source then keys[#keys + 1] = { "⏎", "source", 1 } end
      keys[#keys + 1] = { "⇥", "detail", 2 }
      keys[#keys + 1] = { "]] [[", "findings", 4 }
      keys[#keys + 1] = { "^d ^u", "scroll", 5 }
    end

    local finding = selected_finding()

    if finding then
      if finding.experiment then keys[#keys + 1] = { "n", "queue", 1 } end
      local preparation = finding.preparation
      if preparation and #list(preparation.blockers) == 0 then keys[#keys + 1] = { "p", "prepare", 1 } end
      keys[#keys + 1] = { "h s d x", "decide", 3 }
      keys[#keys + 1] = { "J", state.raw and "analysis" or "raw", 5 }
    end

    vim.list_extend(keys, { { "r", "reload", 4 }, { "g", "catalog", 2 }, { "q", "close", 1 } })
    return keys
  end

  local function paint_footer()
    if state.closed or not vim.api.nvim_buf_is_valid(state.footer_buf) then return end
    local width = state.panes.footer.width
    local keys = footer_keys()

    local function length()
      local total = 2
      for _, key in ipairs(keys) do total = total + vim.fn.strdisplaywidth(key[1] .. " " .. key[2]) + 3 end
      return total
    end

    while #keys > 1 and length() > width do
      local drop = 1
      for index, key in ipairs(keys) do if key[3] >= keys[drop][3] then drop = index end end
      table.remove(keys, drop)
    end

    local line, marks = "  ", {}

    for _, key in ipairs(keys) do
      marks[#marks + 1] = { #line, #line + #key[1] }
      line = line .. key[1] .. " " .. key[2] .. "   "
    end

    set_lines(state.footer_buf, { "  " .. string.rep("─", math.max(1, width - 4)), line })
    vim.api.nvim_buf_clear_namespace(state.footer_buf, ns, 0, -1)
    vim.api.nvim_buf_set_extmark(state.footer_buf, ns, 0, 2, { end_col = 2 + #string.rep("─", math.max(1, width - 4)), hl_group = "OculusInvestigationSeparator" })

    for _, mark in ipairs(marks) do
      vim.api.nvim_buf_set_extmark(state.footer_buf, ns, 1, mark[1], { end_col = mark[2], hl_group = "OculusInvestigationKey" })
    end
  end

  local function status(message, level)
    if state.closed then return end
    state.message, state.message_level = message, level
    paint_frame()
  end

  local function failure(message)
    state.error = tostring(message)
    status("Error: " .. state.error, "error")
    vim.notify("Oculus investigations: " .. state.error, vim.log.levels.WARN)
  end

  local function stop_prefetch()
    local pending = state.prefetching
    state.prefetching = nil
    if pending and pending.handle then pending.handle.cancel() end
  end

  function state.cancel()
    state.generation = state.generation + 1
    if state.pending then state.pending.cancel() end
    stop_prefetch()
    state.pending, state.busy = nil, false
    status("Stopped waiting; previously stored investigations remain in the catalog.")
  end

  function state.close()
    if state.closed then return end
    state.cancel()
    state.closed = true
    pcall(vim.api.nvim_del_augroup_by_id, state.group)

    for _, win in ipairs({ state.footer_win, state.detail_win, state.win, state.frame_win }) do
      if vim.api.nvim_win_is_valid(win) and not pcall(vim.api.nvim_win_close, win, true) then
        vim.api.nvim_win_set_buf(win, vim.api.nvim_create_buf(true, false))
      end
    end
  end

  local function request(arguments, callback)
    if state.closed then return end
    if state.busy then status("An operation is running; c stops waiting."); return end
    state.busy, state.error = true, nil
    state.generation = state.generation + 1
    local generation = state.generation
    status(arguments[1] == "investigate" and "Capturing committed sources and analysing changes…" or "Loading…")

    local handle = client.request(config, arguments, function(value, err)
      if state.closed or generation ~= state.generation then return end
      state.pending, state.busy = nil, false
      if err then failure(err); return end
      local ok, reason = pcall(callback, value)
      if not ok then failure("Invalid engine response: " .. tostring(reason)) end
    end)

    if state.busy and generation == state.generation then state.pending = handle end
  end

  local function decisions_file(investigation_id)
    if not investigation_id or type(investigation_id) ~= "string" then return nil end
    local base = config.decisions_dir or (config.store and (config.store .. "/decisions")) or (vim.fn.stdpath("state") .. "/oculus-decisions")
    pcall(vim.fn.mkdir, base, "p")
    local safe_id = investigation_id:gsub("[^%w_-]", "_")
    return base .. "/" .. safe_id .. ".json"
  end

  -- A developer's decisions are their own attributed records, kept beside the
  -- store; they never edit what Plexus claims.
  function state.load_decisions(investigation_id, view)
    state.decisions = {}
    if not investigation_id then return end
    local file = decisions_file(investigation_id)

    if file and vim.fn.filereadable(file) == 1 then
      local ok, lines = pcall(vim.fn.readfile, file)

      if ok and lines and #lines > 0 then
        local ok_json, data = pcall(vim.json.decode, table.concat(lines, "\n"))
        if ok_json and type(data) == "table" then for k, v in pairs(data) do state.decisions[k] = v end end
      end
    end

    if type(config.investigation_decisions) == "table" and type(config.investigation_decisions[investigation_id]) == "table" then
      for k, v in pairs(config.investigation_decisions[investigation_id]) do state.decisions[k] = state.decisions[k] or v end
    end

    for _, item in ipairs(list(view and view.evidence)) do
      if item.kind == "developer_decision" and item.opportunity_id then
        state.decisions[item.opportunity_id] = state.decisions[item.opportunity_id] or {
          status = item.status or item.decision,
          decision = item.decision or item.status,
          actor = item.actor or item.validation_id,
          diagnostic = item.diagnostic or item.rationale,
          rationale = item.rationale or item.diagnostic,
          created_unix_nanos = item.created_unix_nanos,
        }
      end
    end
  end

  function state.save_decisions()
    if not state.view or not state.view.investigation_id then return end
    local file = decisions_file(state.view.investigation_id)
    if file then pcall(vim.fn.writefile, { vim.json.encode(state.decisions) }, file) end

    if type(config.investigation_decisions) == "table" then
      config.investigation_decisions[state.view.investigation_id] = vim.deepcopy(state.decisions)
      if config.state_file then pcall(require("oculus.storage").save, config.state_file, config) end
    end
  end

  local function target_key(target)
    if type(target) ~= "table" then return nil end
    if state.mode == "catalog" then return "entry:" .. text(target.investigation_id) end
    if target.kind == "finding" then return "finding:" .. text(target.finding.id) end
    if target.kind == "group" then return "group:" .. target.group.effect.id end
    return target.kind
  end

  local function row_of(key)
    for row, target in pairs(state.targets) do
      if target_key(target) == key then
        local earlier = row
        -- A multi-line entry is found by its first line.
        while earlier > 1 and target_key(state.targets[earlier - 1]) == key do earlier = earlier - 1 end
        return earlier
      end
    end
  end

  local function raw_page(finding, width)
    local b = render.page(width)
    b.add({ { " RAW RECORDS", "OculusInvestigationHeading" }, { " · J returns to the analysis", "OculusInvestigationMuted" } })
    b.blank()

    local records = { opportunity = finding.opportunity, claims = finding.claims, obligations = finding.obligations,
      relation = finding.relation, capability = finding.capability, requirement = finding.requirement,
      hypothesis = finding.hypothesis, runs = finding.runs, experiment = finding.experiment, preparation = finding.preparation }

    for _, line in ipairs(vim.split(pretty(records), "\n", { plain = true })) do b.add({ { line } }) end
    return b
  end

  -- The detail pane follows the list's cursor.
  function state.show_detail(force)
    if state.closed or not vim.api.nvim_win_is_valid(state.win) then return end
    local target = state.targets[vim.api.nvim_win_get_cursor(state.win)[1]]
    local key = target_key(target) or state.detail_key
    if not target and state.detail_target then target = state.detail_target end

    if force or key ~= state.detail_key then
      local width, page = state.panes.detail.width, nil
      state.detail_key, state.detail_target, state.detail_finding = key, target, nil

      if state.mode == "catalog" then
        page = target and render.catalog_detail(model.entry(target), state.previews[target.investigation_id], width) or render.page(width)
      elseif state.mode == "investigation" then
        state.detail_finding = target and target.kind == "finding" and target.finding or nil
        page = state.raw and state.detail_finding and raw_page(state.detail_finding, width) or render.detail(state.model, target, width)
      else
        page = render.page(width)
      end

      paint(state.detail_buf, page)
      state.detail_targets = page.targets
      if vim.api.nvim_win_is_valid(state.detail_win) then pcall(vim.api.nvim_win_set_cursor, state.detail_win, { 1, 0 }) end
    end

    paint_footer()
  end

  local function place(key, fallback)
    local row = (key and row_of(key)) or fallback or 1
    local count = vim.api.nvim_buf_line_count(state.buf)
    pcall(vim.api.nvim_win_set_cursor, state.win, { math.max(1, math.min(row, count)), 0 })
    state.show_detail(true)
  end

  local function first_finding_row()
    local first

    for row, target in pairs(state.targets) do
      if target.kind == "finding" and (not first or row < first) then first = row end
    end

    return first
  end

  local function render_investigation(focus)
    state.model = model.build(state.view, state.decisions)
    state.previews[state.view.investigation_id] = { model = state.model }
    local page = render.list(state.model, state.panes.list.width)
    paint(state.buf, page)
    state.targets = page.targets
    place(focus, first_finding_row())
  end

  local function show(value)
    valid_view(value)
    local same = state.view and state.view.investigation_id == value.investigation_id and state.mode == "investigation"
    local focus = same and state.detail_key or nil
    -- A blank row keeps the last detail, but never one from another view.
    if not same then state.detail_target = nil end
    state.load_decisions(value.investigation_id, value)
    state.view, state.mode, state.raw = value, "investigation", false
    render_investigation(focus)
    status("Ready")
  end

  local function render_catalog(focus)
    local entries = vim.tbl_map(model.entry, state.catalog_value.investigations)
    local page = render.catalog(entries, state.previews, state.panes.list.width)
    paint(state.buf, page)
    state.targets = page.targets
    place(focus, 3)
  end

  -- The catalog lists cheap summaries; findings are derived per investigation,
  -- so they load one at a time behind the list rather than before it.
  function state.prefetch()
    if config.catalog_preview == false or state.closed or state.prefetching or state.mode ~= "catalog" then return end
    local item

    for _, candidate in ipairs(state.catalog_value.investigations) do
      if candidate.status == "completed" and not state.previews[candidate.investigation_id] then item = candidate; break end
    end

    if not item then return end
    local investigation_id, token = item.investigation_id, {}
    state.previews[investigation_id], state.prefetching = { loading = true }, token

    token.handle = client.request(config, { "investigation", investigation_id, config.store }, function(value, err)
      if state.prefetching ~= token then return end
      state.prefetching = nil

      if err then
        state.previews[investigation_id] = { error = err }
      else
        local ok, built = pcall(function() valid_view(value); return model.build(value) end)
        state.previews[investigation_id] = ok and { model = built } or { error = built }
      end

      if not state.closed and state.mode == "catalog" then render_catalog(state.detail_key) end
      vim.schedule(state.prefetch)
    end)
  end

  function state.load(investigation_id)
    request({ "investigation", investigation_id, config.store }, show)
  end

  function state.catalog()
    local focus = state.mode == "catalog" and state.detail_key
      or (state.view and ("entry:" .. state.view.investigation_id)) or nil

    request({ "investigations", config.store }, function(value)
      assert(type(value.investigations) == "table" and vim.islist(value.investigations), "Missing investigation catalog")

      for _, item in ipairs(value.investigations) do
        assert(type(item.investigation_id) == "string" and type(item.observation) == "table", "Invalid catalog entry")
      end

      if state.mode ~= "catalog" then state.detail_target = nil end
      state.catalog_value, state.mode, state.raw = value, "catalog", false
      render_catalog(focus)
      status("Ready")
      state.prefetch()
    end)
  end

  function state.refresh()
    if state.mode == "investigation" then
      state.load(state.view.investigation_id)
    else
      state.previews = {}
      state.catalog()
    end
  end

  -- A source location always lands in an ordinary window: the investigations
  -- float cannot be split and would cover whatever opened behind it.
  local function source_window()
    local function ordinary(win)
      return type(win) == "number" and vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_config(win).relative == ""
    end

    if ordinary(state.source_win) and not vim.bo[vim.api.nvim_win_get_buf(state.source_win)].modified then
      return state.source_win
    end

    local anchor

    for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
      if ordinary(win) then anchor = win break end
    end

    if anchor then vim.api.nvim_set_current_win(anchor) end
    vim.cmd(anchor and "leftabove vnew" or "noautocmd tabnew")
    state.source_win = vim.api.nvim_get_current_win()
    return state.source_win
  end

  -- The list keeps focus while the detail pane scrolls.
  function state.scroll_detail(keys)
    if state.closed or not vim.api.nvim_win_is_valid(state.detail_win) then return end
    vim.api.nvim_win_call(state.detail_win, function() vim.cmd("normal! " .. vim.keycode(keys)) end)
  end

  function state.focus(pane)
    if state.closed then return end
    local win = pane == "detail" and state.detail_win or state.win
    if vim.api.nvim_win_is_valid(win) then vim.api.nvim_set_current_win(win) end
  end

  function state.focus_finding(finding_id)
    if state.mode ~= "investigation" then return end
    state.focus("list")
    place("finding:" .. finding_id)
  end

  -- ]] and [[: the next or previous finding (or catalog entry).
  function state.jump(step)
    if state.closed then return end
    state.focus("list")
    local row, count = vim.api.nvim_win_get_cursor(state.win)[1], vim.api.nvim_buf_line_count(state.buf)
    local here = target_key(state.targets[row])
    local target_row = row + step

    while target_row >= 1 and target_row <= count do
      local target = state.targets[target_row]
      local key = target_key(target)

      if key and key ~= here and (state.mode == "catalog" or target.kind == "finding") then
        place(key)
        return
      end

      target_row = target_row + step
    end
  end

  function state.navigate(target)
    target = target or current_target()
    if not target then status("Place the cursor on an investigation or finding."); return end
    if state.mode == "catalog" then state.load(target.investigation_id); return end
    if target.kind == "related" then state.focus_finding(target.finding.id); return end

    if target.kind == "action" then
      if target.action == "queue" then state.queue(target) else state.compose(target) end
      return
    end

    local location = target.source
    if location == nil then state.focus("detail"); return end

    if type(location) ~= "table" or type(location.path) ~= "string" or type(location.digest) ~= "string"
      or not location.digest:match("^sha256:%x+$") or type(location.line) ~= "number" or location.line < 1
      or location.line % 1 ~= 0 or type(location.column) ~= "number" or location.column < 1
      or location.column % 1 ~= 0 then failure("Invalid source location."); return end

    local function display(buf, message)
      local win = source_window()
      vim.api.nvim_win_set_buf(win, buf)
      local row = math.min(location.line, vim.api.nvim_buf_line_count(buf))
      local line = vim.api.nvim_buf_get_lines(buf, row - 1, row, false)[1] or ""
      vim.api.nvim_win_set_cursor(win, { row, math.min(location.column - 1, #line) })
      -- Hand the screen to the source; the catalog reopens with the same command.
      state.close()
      vim.api.nvim_set_current_win(win)
      vim.notify("Oculus investigations: " .. text(message), vim.log.levels.INFO)
    end

    local loaded = vim.fn.bufnr(location.path)
    local file = location.path:sub(1, 1) == "/" and io.open(location.path, "rb") or nil
    local bytes
    if file then bytes = file:read("*a"); file:close() end

    if bytes and "sha256:" .. vim.fn.sha256(bytes) == location.digest and not (loaded >= 0 and vim.bo[loaded].modified) then
      local buf = vim.fn.bufadd(location.path)
      vim.fn.bufload(buf)
      vim.api.nvim_buf_call(buf, function() vim.cmd("checktime") end)
      display(buf, "Showing digest-verified local source.")
      return
    end

    if type(location.artifact) ~= "string" then failure("Archived source is unavailable."); return end

    request({ "investigation-source", location.artifact, config.store }, function(value)
      assert(type(value.content) == "string" and "sha256:" .. vim.fn.sha256(value.content) == location.digest, "Archived source digest mismatch")
      local buf = vim.api.nvim_create_buf(false, true)
      vim.bo[buf].bufhidden, vim.bo[buf].swapfile = "wipe", false
      vim.bo[buf].filetype = vim.filetype.match({ filename = location.path }) or ""
      set_lines(buf, vim.split(value.content, "\n", { plain = true }))
      vim.bo[buf].readonly = true
      vim.b[buf].oculus_archived_source = location.artifact
      display(buf, "Showing archived source; local file is missing, changed, or modified.")
    end)
  end

  function state.queue(target)
    local finding = state.mode == "investigation" and selected_finding(target) or nil

    if not finding or not finding.experiment then
      status("The selected finding has no supported experiment.")
      return
    end

    require("oculus.nexus").open(nexus_config, config, {
      kind = "discovery_validation", investigation_id = state.view.investigation_id,
      opportunity_id = finding.id, artifact_store = config.store,
    })
  end

  function state.compose(target, path)
    local finding = state.mode == "investigation" and selected_finding(target) or nil
    if not finding then status("Select a finding to prepare a plan for it."); return end
    -- Plexus lists what it will prepare for each finding, and why not when blocked.
    local preparation = finding.preparation
    if not preparation then status("Plexus offers no preparation for this finding."); return end

    if #list(preparation.blockers) > 0 then
      status("Preparation unavailable: " .. table.concat(preparation.blockers, "; "), "error")
      return
    end

    local rust = preparation.kind == "rust_call_site_adaptation"

    local options = { native = true, kind = rust and "rust" or "c_zig",
      investigation_id = state.view.investigation_id, opportunity_id = finding.id }

    local function open(manifest)
      if state.closed or type(manifest) ~= "string" or vim.trim(manifest) == "" then return end
      state.close()
      require("oculus.compositions").open(config, nexus_config, manifest, options)
    end

    if path then open(path)
    elseif rust then
      -- The developer names the tests; Plexus derives the patch and trees itself.
      vim.ui.input({ prompt = "Consumer tests to keep passing (exact names, space-separated): " }, function(value)
        if state.closed or type(value) ~= "string" or vim.trim(value) == "" then return end

        local body = vim.json.encode({ schema_version = 1, investigation_id = options.investigation_id,
          opportunity_id = options.opportunity_id, tests = vim.split(vim.trim(value), "%s+") })

        local file = vim.fn.stdpath("state") .. "/oculus-adaptations/" .. vim.fn.sha256(body) .. ".json"
        vim.fn.mkdir(vim.fn.fnamemodify(file, ":h"), "p")
        if vim.fn.writefile({ body }, file) ~= 0 then status("Could not write the adaptation request."); return end
        open(file)
      end)
    else vim.ui.input({ prompt = "C/Zig composition request (sources and cases): ", completion = "file" }, open) end
  end

  local function record_decision(target, decision_name, rationale)
    local finding = state.mode == "investigation" and selected_finding(target) or nil

    if not finding then
      status("Place the cursor on an opportunity to steer it.")
      return false
    end

    local actor = (vim.env.USER and vim.env.USER ~= "") and vim.env.USER or "developer"
    local note = (type(rationale) == "string" and vim.trim(rationale) ~= "") and vim.trim(rationale) or nil

    state.decisions[finding.id] = {
      kind = "developer_decision",
      opportunity_id = finding.id,
      status = decision_name,
      decision = decision_name,
      validation_id = "developer:" .. actor,
      actor = actor,
      diagnostic = note,
      rationale = note,
      created_unix_nanos = tostring(os.time()) .. "000000000",
    }

    state.save_decisions()
    render_investigation("finding:" .. finding.id)
    return true
  end

  local function steer(decision_name, prompt, done)
    return function(target, note)
      local finding = state.mode == "investigation" and selected_finding(target) or nil
      if not finding then status("Place the cursor on an opportunity to steer it."); return end
      target = { kind = "finding", finding = finding }

      if note ~= nil then
        if record_decision(target, decision_name, note) then status(done) end
        return
      end

      vim.ui.input({ prompt = prompt }, function(input)
        if state.closed or input == nil then return end
        if record_decision(target, decision_name, input) then status(done) end
      end)
    end
  end

  state.promote = steer("promoted", "Promote to hypothesis (optional note): ", "Opportunity promoted to hypothesis.")
  state.select_opportunity = steer("selected", "Selection rationale (optional note): ", "Opportunity selected for active investigation.")
  state.defer = steer("deferred", "Reason for deferral (optional note): ", "Opportunity deferred.")
  state.dismiss = steer("dismissed", "Reason for dismissal (optional note): ", "Opportunity dismissed.")

  function state.clear_decision(target)
    local finding = state.mode == "investigation" and selected_finding(target) or nil
    if not finding then status("Place the cursor on an opportunity to steer it."); return end
    if not state.decisions[finding.id] then status("No decision recorded for this opportunity."); return end
    state.decisions[finding.id] = nil
    state.save_decisions()
    render_investigation("finding:" .. finding.id)
    status("Developer decision cleared.")
  end

  function state.toggle_raw()
    if state.mode ~= "investigation" or not selected_finding() then return end
    state.raw = not state.raw
    state.show_detail(true)
  end

  function state.relayout()
    if state.closed or not vim.api.nvim_win_is_valid(state.frame_win) then return end
    state.frame_config, state.panes = layout(config)
    vim.api.nvim_win_set_config(state.frame_win, state.frame_config)
    vim.api.nvim_win_set_config(state.win, pane_config(state.frame_win, state.panes.list, true, 51))
    vim.api.nvim_win_set_config(state.detail_win, pane_config(state.frame_win, state.panes.detail, true, 51))
    vim.api.nvim_win_set_config(state.footer_win, pane_config(state.frame_win, state.panes.footer, false, 52))
    paint_frame()

    if state.mode == "investigation" then render_investigation(state.detail_key)
    elseif state.mode == "catalog" then render_catalog(state.detail_key) end
  end

  state.group = vim.api.nvim_create_augroup("OculusInvestigations" .. state.buf, { clear = true })

  for _, win in ipairs({ state.frame_win, state.win, state.detail_win }) do
    vim.api.nvim_create_autocmd("WinClosed", { group = state.group, pattern = tostring(win), once = true, callback = state.close })
  end

  vim.api.nvim_create_autocmd("BufWipeout", { group = state.group, buffer = state.buf, once = true, callback = state.close })
  vim.api.nvim_create_autocmd("CursorMoved", { group = state.group, buffer = state.buf, callback = function() state.show_detail() end })
  vim.api.nvim_create_autocmd("CursorMoved", { group = state.group, buffer = state.detail_buf, callback = paint_footer })
  vim.api.nvim_create_autocmd("VimResized", { group = state.group, callback = function() state.relayout() end })

  vim.api.nvim_create_autocmd("ColorScheme", { group = state.group, callback = function()
    if state.closed then return end
    for name, link in pairs(highlights) do vim.api.nvim_set_hl(0, name, { link = link, default = true }) end
    paint_background()
  end })

  vim.api.nvim_create_autocmd("WinEnter", { group = state.group, callback = function()
    if state.closed then return end
    if vim.api.nvim_win_is_valid(state.detail_win) then vim.wo[state.detail_win].cursorline = focused_detail() end
    paint_footer()
  end })

  local maps = {
    ["<CR>"] = function() state.navigate() end,
    ["<Tab>"] = function() state.focus(focused_detail() and "list" or "detail") end,
    ["]]"] = function() state.jump(1) end,
    ["[["] = function() state.jump(-1) end,
    n = function() state.queue() end,
    p = function() state.compose() end,
    h = function() state.promote() end,
    s = function() state.select_opportunity() end,
    d = function() state.defer() end,
    x = function() state.dismiss() end,
    u = function() state.clear_decision() end,
    J = state.toggle_raw,
    r = state.refresh,
    g = state.catalog,
    c = state.cancel,
    ["<C-c>"] = state.cancel,
    q = state.close,
    ["<Esc>"] = state.close,
  }

  for _, buf in ipairs({ state.buf, state.detail_buf }) do
    for key, callback in pairs(maps) do vim.keymap.set("n", key, callback, { buffer = buf, silent = true, nowait = true }) end
  end

  for _, key in ipairs({ "<C-d>", "<C-u>" }) do
    vim.keymap.set("n", key, function() state.scroll_detail(key) end, { buffer = state.buf, silent = true, nowait = true })
  end

  paint_frame()
  set_lines(state.buf, { "", " Loading…" })
  paint_footer()

  if submission then request({ "investigate", vim.json.encode(submission), config.store }, show)
  elseif id then state.load(id)
  else state.catalog() end

  return state
end

-- Oculus only collects intent. Git identity, captures, inference and experiment
-- eligibility belong to Plexus; all requests cross an argv/JSON boundary.
function M.prompt(config, context)
  context = context or {}

  if context.analysis ~= nil and context.analysis ~= "rust" and context.analysis ~= "c_zig" then
    vim.notify("Oculus: choose rust or c-zig investigation analysis.", vim.log.levels.WARN)
    return
  end

  local c_zig = context.analysis == "c_zig"

  local request = { schema_version = 1, repository = context.repository, base = context.base, head = context.head,
    consumer_revision = "HEAD" }

  if c_zig then request.analysis = "c_zig"
  else request.producer_manifest, request.consumer_manifest = "Cargo.toml", "Cargo.toml" end

  local include_dirs

  local function ask(key, prompt, default, next_step, completion)
    vim.ui.input({ prompt = prompt, default = request[key] or default, completion = completion }, function(value)
      if not value or vim.trim(value) == "" then return end
      request[key] = vim.trim(value)
      next_step()
    end)
  end

  local function submit()
    request.repository = vim.fn.fnamemodify(vim.fn.expand(request.repository), ":p"):gsub("/$", "")
    request.consumer_repository = vim.fn.fnamemodify(vim.fn.expand(request.consumer_repository), ":p"):gsub("/$", "")
    local window = require("oculus.window")
    if window.state.win and vim.api.nvim_win_is_valid(window.state.win) then window.close() end
    M.open(config.plexus, config.nexus, nil, request)
  end

  local function intent() ask("intent", "Investigation intent: ", "What does this change enable for the consumer?", submit) end

  local function consumer_input()
    if c_zig then ask("consumer_source", "Consumer Zig source (relative to repository): ", "src/main.zig", intent)
    else ask("consumer_manifest", "Consumer Cargo manifest (relative to repository): ", "Cargo.toml", intent) end
  end

  local function consumer_revision() ask("consumer_revision", "Consumer committed revision (working edits excluded): ", "HEAD", consumer_input) end
  local function consumer_path() ask("consumer_repository", "Consumer local repository: ", vim.fn.getcwd(), consumer_revision, "dir") end

  local function consumer()
    local workspace = require("oculus.workspace")
    local active_ws = workspace.get_active(config)
    local prompt_title = active_ws and ("Consumer project (" .. active_ws.name .. "):") or "Consumer project:"
    local choices, projects, index = {}, workspace.filter_projects(config, config.projects), 0

    local function next_project()
      index = index + 1
      local project = projects[index]

      if project then
        require("oculus.local_activity").find_repository(project, config, function(path)
          if path then choices[#choices + 1] = { label = (project.name or project.repository) .. " · " .. path, path = path } end
          next_project()
        end)
      elseif #choices == 0 then consumer_path()
      else
        choices[#choices + 1] = { label = "Choose another local repository…" }

        vim.ui.select(choices, { prompt = prompt_title, format_item = function(item) return item.label end }, function(choice)
          if not choice then return end
          if choice.path then request.consumer_repository = choice.path; consumer_revision() else consumer_path() end
        end)
      end
    end

    next_project()
  end

  -- Repository-relative directories searched for angled includes, in order.
  -- Empty is a real answer: the repository root and the header's own directory
  -- are always searched, so a self-contained header needs nothing here.
  function include_dirs()
    vim.ui.input({ prompt = "Producer include directories, comma separated (optional): ", default = "include", completion = "dir" }, function(value)
      if value == nil then return end
      local directories = {}

      for part in tostring(value):gmatch("[^,]+") do
        local trimmed = vim.trim(part)
        if trimmed ~= "" then directories[#directories + 1] = trimmed end
      end

      -- An empty list would encode as a JSON object, so the field is omitted.
      request.producer_include_dirs = #directories > 0 and directories or nil
      consumer()
    end)
  end

  local function header_language()
    ask("header_language", "Header language (c or c++): ", "c", function()
      if request.header_language ~= "c" and request.header_language ~= "c++" then
        vim.notify("Oculus: header language must be c or c++.", vim.log.levels.WARN)
        return
      end

      include_dirs()
    end)
  end

  local function producer_input()
    if c_zig then ask("producer_header", "Producer header (relative to repository): ", "include/api.h", header_language)
    else ask("producer_manifest", "Producer Cargo manifest (relative to repository): ", "Cargo.toml", consumer) end
  end

  local function base() ask("base", "Base committed revision: ", (request.head or "HEAD") .. "^", producer_input) end
  local function head() ask("head", "Head committed revision (working edits excluded): ", "HEAD", base) end
  ask("repository", "Producer local repository: ", vim.fn.getcwd(), head, "dir")
end

function M.from_activity(config, event, url)
  if type(event) ~= "table" or not event.oculus_local then
    vim.notify("Oculus: select a local commit, or use :OculusInvestigate for a revision pair.", vim.log.levels.INFO)
    return
  end

  local parsed = type(url) == "string" and require("oculus.inspect.patch").parse_target_url(url) or nil
  local head = parsed and parsed.kind == "commit" and parsed.sha or (event.payload or {}).head

  if type(head) ~= "string" or not head:match("^%x+$") then
    vim.notify("Oculus: select an individual local commit.", vim.log.levels.WARN)
    return
  end

  local project = { repository = (event.repo or {}).name, provider = event.oculus_local.forge }

  require("oculus.local_activity").find_repository(project, config, function(path)
    if not path then vim.notify("Oculus: no local clone found for this activity.", vim.log.levels.WARN); return end
    M.prompt(config, { repository = path, base = head .. "^", head = head })
  end)
end

return M
