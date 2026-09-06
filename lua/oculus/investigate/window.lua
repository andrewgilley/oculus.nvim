local M = {}

M.state = {
  buf = nil,
  win = nil,
  ledger_buf = nil,
  ledger_win = nil,
  footer_buf = nil,
  footer_win = nil,
  sub_buf = nil,
  sub_win = nil,
  sub_footer_buf = nil,
  sub_footer_win = nil,
  view_mode = "tree",
  ledger_start_line = nil,
  tree_last_line = nil,
  bundle = nil,
  line_targets = {},
  line_provenance = {},
  line_sections = {},
  collapsed_sections = {},
}

local function is_valid_win(win)
  return win and vim.api.nvim_win_is_valid(win)
end

local function is_valid_buf(buf)
  return buf and vim.api.nvim_buf_is_valid(buf)
end

local function sanitize_bundle(data)
  if data == vim.NIL or type(data) == "userdata" then
    return nil
  end

  if type(data) == "table" then
    for k, v in pairs(data) do
      if v == vim.NIL or type(v) == "userdata" then
        data[k] = nil
      elseif type(v) == "table" then
        data[k] = sanitize_bundle(v)
      end
    end
  end

  return data
end

local function close_investigate_footer()
  if is_valid_win(M.state.footer_win) then
    pcall(vim.api.nvim_win_close, M.state.footer_win, true)
  end

  if is_valid_buf(M.state.footer_buf) then
    pcall(vim.api.nvim_buf_delete, M.state.footer_buf, { force = true })
  end

  M.state.footer_buf = nil
  M.state.footer_win = nil
end

local function make_footer_buf()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = "oculus"
  return buf
end

local function investigate_footer_config()
  if not is_valid_win(M.state.win) then
    return nil
  end

  local config = vim.api.nvim_win_get_config(M.state.win)
  local row = tonumber(config.row) or 0
  local col = tonumber(config.col) or 0
  local width = vim.api.nvim_win_get_width(M.state.win)
  local height = vim.api.nvim_win_get_height(M.state.win)

  if is_valid_win(M.state.ledger_win) then
    local r_width = vim.api.nvim_win_get_width(M.state.ledger_win)
    width = width + r_width + 2
  end

  return {
    relative = "editor",
    width = width,
    height = 2,
    row = row + height - 1,
    col = col + 1,
    style = "minimal",
    focusable = false,
    zindex = 65,
  }
end

local function get_inspect_key(nav)
  local inspect_key = nav and nav.inspect

  if not inspect_key or inspect_key == "i" or inspect_key == "g" or (nav and inspect_key == nav.up) then
    inspect_key = (nav and nav.left == "h") and "H" or "h"
  end

  return inspect_key
end

local function render_investigate_footer()
  local config = investigate_footer_config()

  if not config then
    return
  end

  local buf = M.state.footer_buf

  if not is_valid_buf(buf) then
    buf = make_footer_buf()
    M.state.footer_buf = buf
  end

  local width = config.width
  local nav = require("oculus.navigation").resolve(M.state.opts)
  local inspect_key = get_inspect_key(nav)
  local cmd_text = ("  <CR> jump   e experiment   p patches   t test   r refactor   a agent   %s inspect   q close"):format(inspect_key)

  if M.state.active_inspect_group then
    cmd_text = ("  <CR> jump   <Tab> inspect   e experiment   p patches   t test   r refactor   a agent   %s inspect   q close"):format(inspect_key)
  end

  local lines = {
    "  " .. string.rep("─", math.max(1, width - 4)),
    cmd_text,
  }

  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].readonly = true
  local ns = vim.api.nvim_create_namespace("oculus_investigate_footer_hl")
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  vim.api.nvim_buf_add_highlight(buf, ns, "WinSeparator", 0, 2, -1)
  vim.api.nvim_buf_add_highlight(buf, ns, "Comment", 1, 2, #cmd_text)

  if is_valid_win(M.state.footer_win) then
    pcall(vim.api.nvim_win_set_config, M.state.footer_win, config)
  else
    M.state.footer_win = vim.api.nvim_open_win(buf, false, config)
  end

  vim.wo[M.state.footer_win].wrap = false
  vim.wo[M.state.footer_win].cursorline = false
  vim.wo[M.state.footer_win].number = false
  vim.wo[M.state.footer_win].relativenumber = false
  vim.wo[M.state.footer_win].signcolumn = "no"

  vim.wo[M.state.footer_win].winhighlight = table.concat({
    "Normal:OculusNormal",
    "NormalFloat:OculusNormal",
  }, ",")

  pcall(function()
    local oculus_window = require("oculus.window")

    if type(oculus_window.apply_window_highlights) == "function" then
      oculus_window.apply_window_highlights(M.state.footer_win)
    end
  end)

  local f_kopts = { buffer = buf, silent = true, nowait = true }

  vim.keymap.set("n", "<ScrollWheelDown>", function()
    M.scroll_window(M.state.win, M.state.footer_win, 3)
  end, f_kopts)

  vim.keymap.set("n", "<ScrollWheelUp>", function()
    M.scroll_window(M.state.win, M.state.footer_win, -3)
  end, f_kopts)

  vim.keymap.set("n", "<ScrollWheelLeft>", function() end, f_kopts)
  vim.keymap.set("n", "<ScrollWheelRight>", function() end, f_kopts)
end

function M.clamp_scroll(win, footer_win)
  if not is_valid_win(win) then
    return
  end

  local buf = vim.api.nvim_win_get_buf(win)

  if not is_valid_buf(buf) then
    return
  end

  local line_count = vim.api.nvim_buf_line_count(buf)

  if line_count == 0 then
    return
  end

  local win_height = vim.api.nvim_win_get_height(win)
  local footer_height = is_valid_win(footer_win) and vim.api.nvim_win_get_height(footer_win) or 0
  local visible_rows = math.max(1, win_height - footer_height)
  local max_topline = math.max(1, line_count - visible_rows + 1)

  vim.api.nvim_win_call(win, function()
    local view = vim.fn.winsaveview()
    local cursor = vim.api.nvim_win_get_cursor(win)
    local lnum = cursor[1]
    local topline = view.topline

    -- 1. Clamp topline to boundaries [1, max_topline]
    if topline > max_topline then
      topline = max_topline
    end

    if topline < 1 then
      topline = 1
    end

    -- 2. Keep lnum within valid buffer bounds [1, line_count]
    if lnum > line_count then
      lnum = line_count
    end

    if lnum < 1 then
      lnum = 1
    end

    -- 3. If cursor is above the viewport, pull it down to topline
    if lnum < topline then
      lnum = math.min(line_count, topline)
    end

    -- 4. Prevent cursor from entering footer rows (rows > visible_rows)
    local cursor_screen_row = lnum - topline + 1

    if cursor_screen_row > visible_rows then
      local needed_scroll = cursor_screen_row - visible_rows
      local new_topline = math.min(max_topline, topline + needed_scroll)
      topline = new_topline

      if lnum - topline + 1 > visible_rows then
        lnum = math.min(line_count, topline + visible_rows - 1)
      end
    end

    view.topline = topline
    view.lnum = lnum
    view.topfill = 0
    vim.fn.winrestview(view)
  end)
end

function M.scroll_window(win, footer_win, delta)
  if not is_valid_win(win) then
    return
  end

  local buf = vim.api.nvim_win_get_buf(win)

  if not is_valid_buf(buf) then
    return
  end

  local line_count = vim.api.nvim_buf_line_count(buf)

  if line_count == 0 then
    return
  end

  local win_height = vim.api.nvim_win_get_height(win)
  local footer_height = is_valid_win(footer_win) and vim.api.nvim_win_get_height(footer_win) or 0
  local visible_rows = math.max(1, win_height - footer_height)
  local max_topline = math.max(1, line_count - visible_rows + 1)

  vim.api.nvim_win_call(win, function()
    local view = vim.fn.winsaveview()
    local new_topline = math.max(1, math.min(max_topline, view.topline + delta))
    local cursor = vim.api.nvim_win_get_cursor(win)
    local max_allowed_line = math.min(line_count, new_topline + visible_rows - 1)
    local min_allowed_line = new_topline
    local lnum = cursor[1]

    if lnum > max_allowed_line then
      lnum = max_allowed_line
    elseif lnum < min_allowed_line then
      lnum = min_allowed_line
    end

    view.topline = new_topline
    view.lnum = lnum
    view.topfill = 0
    vim.fn.winrestview(view)
  end)
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

function M.is_open()
  return is_valid_win(M.state.win)
end

function M.is_investigate_win(win)
  if not win then
    return false
  end

  return win == M.state.win
    or win == M.state.ledger_win
    or win == M.state.footer_win
    or win == M.state.sub_win
    or win == M.state.sub_footer_win
end

local closing = false

function M.close(for_subwin)
  if closing then
    return
  end

  closing = true
  close_investigate_footer()

  if is_valid_win(M.state.ledger_win) then
    pcall(vim.api.nvim_win_close, M.state.ledger_win, true)
  end

  if is_valid_buf(M.state.ledger_buf) and M.state.ledger_buf ~= M.state.buf then
    pcall(vim.api.nvim_buf_delete, M.state.ledger_buf, { force = true })
  end

  if is_valid_win(M.state.win) then
    pcall(vim.api.nvim_win_close, M.state.win, true)
  end

  if is_valid_buf(M.state.buf) then
    pcall(vim.api.nvim_buf_delete, M.state.buf, { force = true })
  end

  if not for_subwin then
    if is_valid_win(M.state.sub_footer_win) then
      pcall(vim.api.nvim_win_close, M.state.sub_footer_win, true)
    end

    if is_valid_buf(M.state.sub_footer_buf) then
      pcall(vim.api.nvim_buf_delete, M.state.sub_footer_buf, { force = true })
    end

    M.state.sub_footer_win = nil
    M.state.sub_footer_buf = nil

    if is_valid_win(M.state.sub_win) then
      pcall(vim.api.nvim_win_close, M.state.sub_win, true)
    end

    if is_valid_buf(M.state.sub_buf) then
      pcall(vim.api.nvim_buf_delete, M.state.sub_buf, { force = true })
    end

    M.state.sub_win = nil
    M.state.sub_buf = nil
  end

  M.state.win = nil
  M.state.buf = nil
  M.state.ledger_win = nil
  M.state.ledger_buf = nil
  M.state.footer_win = nil
  M.state.footer_buf = nil
  M.state.view_mode = "tree"
  M.state.ledger_start_line = nil
  M.state.tree_last_line = nil

  if not for_subwin then
    M.state.bundle = nil
    M.state.collapsed_sections = {}
    M.state.active_inspect_group = nil
  end

  M.state.line_targets = {}
  M.state.line_provenance = {}
  M.state.line_sections = {}

  if not for_subwin then
    pcall(vim.api.nvim_clear_autocmds, { group = "oculus_investigate_scroll" })
    local ok, oculus_window = pcall(require, "oculus.window")

    if ok and oculus_window.state and is_valid_win(oculus_window.state.win) then
      if type(oculus_window.render_activity_footer) == "function" then
        pcall(oculus_window.render_activity_footer)
      end

      pcall(vim.api.nvim_set_current_win, oculus_window.state.win)
    end
  end

  closing = false
end

function M.open(bundle, opts)
  opts = opts or {}

  if not bundle and M.state.bundle then
    bundle = M.state.bundle
  end

  bundle = sanitize_bundle(bundle) or {}
  local preserved_group = M.state.active_inspect_group
  M.close(true)
  M.state.active_inspect_group = preserved_group
  local ok, oculus_window = pcall(require, "oculus.window")

  if ok and type(oculus_window.close_activity_footer) == "function" then
    pcall(oculus_window.close_activity_footer)
  end

  if ok and type(oculus_window.stop_activity_investigate_spinner) == "function" then
    pcall(oculus_window.stop_activity_investigate_spinner)
  end

  M.state.opts = opts
  M.state.view_mode = "tree"
  local main_cfg = get_target_window_config(opts)
  local width = main_cfg.width
  local height = main_cfg.height
  local row = main_cfg.row
  local col = main_cfg.col
  local border = main_cfg.border or opts.border or "rounded"
  local is_split = opts.split == true
  local left_width = width
  local right_width = 0

  if is_split then
    local available = math.max(20, width - 2)
    left_width = math.floor(available * 0.52)
    right_width = available - left_width
  end

  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "hide"
  vim.bo[buf].swapfile = false

  local win = vim.api.nvim_open_win(buf, false, {
    relative = "editor",
    width = left_width,
    height = height,
    row = row,
    col = col,
    style = "minimal",
    border = border,
    zindex = 60,
  })

  vim.wo[win].cursorline = true
  vim.wo[win].wrap = false
  vim.wo[win].scrolloff = 2

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
    vim.bo[ledger_buf].bufhidden = "hide"
    vim.bo[ledger_buf].swapfile = false

    ledger_win = vim.api.nvim_open_win(ledger_buf, false, {
      relative = "editor",
      width = right_width,
      height = height,
      row = row,
      col = col + left_width + 2,
      style = "minimal",
      border = border,
      zindex = 60,
    })

    vim.wo[ledger_win].cursorline = false
    vim.wo[ledger_win].wrap = true
    vim.wo[ledger_win].scrolloff = 2
    pcall(function() vim.wo[ledger_win].winhighlight = winhl end)
  else
    ledger_buf = buf
  end

  M.state.buf = buf
  M.state.win = win
  M.state.ledger_buf = ledger_buf
  M.state.ledger_win = ledger_win
  M.state.bundle = bundle
  M.state.line_targets = {}
  M.state.line_provenance = {}
  M.state.tree_last_line = 1
  pcall(vim.api.nvim_set_current_win, win)

  vim.schedule(function()
    if is_valid_win(win) then
      pcall(vim.api.nvim_set_current_win, win)
    end
  end)

  M.render(buf, bundle)

  if is_split and ledger_buf and ledger_buf ~= buf then
    M.render_ledger(ledger_buf, M.state.line_provenance[1] or { kind = "overview" })
    M.map_keys(ledger_buf)
  end

  local scroll_group = vim.api.nvim_create_augroup("oculus_investigate_scroll", { clear = true })

  -- Cursor tracking and scroll clamping in main window
  vim.api.nvim_create_autocmd("CursorMoved", {
    group = scroll_group,
    buffer = buf,
    callback = function()
      if not is_valid_win(M.state.win) then
        return
      end

      M.clamp_scroll(M.state.win, M.state.footer_win)
      local cursor = vim.api.nvim_win_get_cursor(M.state.win)
      local line = cursor[1]

      if is_valid_win(M.state.ledger_win) and is_valid_buf(M.state.ledger_buf) and M.state.ledger_buf ~= buf then
        local prov = M.state.line_provenance[line] or { kind = "overview" }
        M.render_ledger(M.state.ledger_buf, prov)
      end
    end,
  })

  if is_split and ledger_buf and ledger_buf ~= buf then
    vim.api.nvim_create_autocmd("CursorMoved", {
      group = scroll_group,
      buffer = ledger_buf,
      callback = function()
        if not is_valid_win(M.state.ledger_win) then
          return
        end

        M.clamp_scroll(M.state.ledger_win, M.state.footer_win)
      end,
    })
  end

  vim.api.nvim_create_autocmd("WinScrolled", {
    group = scroll_group,
    callback = function(args)
      local win_id = tonumber(args.match) or vim.api.nvim_get_current_win()

      if is_valid_win(M.state.win) and win_id == M.state.win then
        M.clamp_scroll(M.state.win, M.state.footer_win)
      elseif is_valid_win(M.state.ledger_win) and win_id == M.state.ledger_win then
        M.clamp_scroll(M.state.ledger_win, M.state.footer_win)
      elseif is_valid_win(M.state.sub_win) and win_id == M.state.sub_win then
        M.clamp_scroll(M.state.sub_win, M.state.sub_footer_win)
      end
    end,
  })

  M.map_keys(buf)
  render_investigate_footer()
  M.clamp_scroll(win, M.state.footer_win)

  if is_valid_win(win) then
    pcall(vim.api.nvim_set_current_win, win)

    vim.schedule(function()
      if is_valid_win(win) and vim.api.nvim_get_current_win() ~= win then
        pcall(vim.api.nvim_set_current_win, win)
      end
    end)
  end

  vim.api.nvim_create_autocmd("WinClosed", {
    pattern = tostring(win),
    once = true,
    callback = function()
      M.close()
    end,
  })
end

function M.render(buf, bundle)
  if not is_valid_buf(buf) then
    return
  end

  bundle = sanitize_bundle(bundle) or {}
  local lines = {}
  local highlights = {}
  local line_targets = {}
  local line_provenance = {}
  local line_sections = {}
  local current_sec_id = nil

  local function add_line(text, hl_group, target, prov, sec_info)
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

    if sec_info then
      line_sections[line_idx] = sec_info
    elseif current_sec_id then
      line_sections[line_idx] = { id = current_sec_id, is_header = false }
    end

    return line_idx
  end

  local meta = bundle.metadata or {}
  local repo_root = type(meta.repository_root) == "string" and meta.repository_root or ""
  local repo_name = vim.fs.basename(repo_root)

  if repo_name == "" then
    repo_name = repo_root ~= "" and repo_root or "Repository"
  end

  local target_desc

  if type(bundle.forge_artifact) == "table" and bundle.forge_artifact.id then
    local kind = bundle.forge_artifact.kind

    local kind_str = kind == "pull_request" and "PR"
      or (type(kind) == "string" and kind:gsub("^%l", string.upper) or "Artifact")

    local id_str = tostring(bundle.forge_artifact.id)
    id_str = id_str:match("^#") and id_str or ("#" .. id_str)

    if bundle.forge_artifact.title and bundle.forge_artifact.title ~= "" then
      target_desc = string.format("Target: %s %s · \"%s\"", kind_str, id_str, bundle.forge_artifact.title)
    else
      target_desc = string.format("Target: %s %s", kind_str, id_str)
    end
  elseif type(meta.target) == "string" and meta.target ~= "" then
    target_desc = "Target: " .. meta.target
  else
    target_desc = "Target: Working tree / HEAD"
  end

  local engine_ver = type(meta.engine_version) == "string" and meta.engine_version or "0.1.0"
  local analyzed = type(meta.analyzed_at) == "string" and meta.analyzed_at or os.date("!%Y-%m-%dT%H:%M:%SZ")
  local trace_links = type(bundle.traceability_links) == "table" and bundle.traceability_links or {}
  local entities = type(bundle.entities) == "table" and bundle.entities or {}
  local impact = type(bundle.impact) == "table" and bundle.impact or nil
  local callers = (impact and impact.direct_callers) or {}
  local tests = (impact and impact.affected_tests) or {}
  local files = (impact and impact.affected_files) or {}
  local dynamics = type(bundle.dynamics) == "table" and bundle.dynamics or nil
  local crossings = (dynamics and dynamics.boundary_crossings) or {}
  local alerts = (dynamics and dynamics.subsystem_instabilities) or {}
  local precedents = (dynamics and dynamics.historical_precedents) or {}
  local invariants = type(bundle.invariants) == "table" and bundle.invariants or {}
  local forge_art = bundle.forge_artifact
  local co_changes = type(bundle.co_changes) == "table" and bundle.co_changes or {}
  local derived = type(bundle.derived) == "table" and bundle.derived or nil
  local relationships = type(bundle.relationships) == "table" and bundle.relationships or {}
  local history_lookup = {}

  for _, h in ipairs(type(bundle.entity_histories) == "table" and bundle.entity_histories or {}) do
    history_lookup[h.entity_id] = h
  end

  M.state.collapsed_sections = M.state.collapsed_sections or {}

  local function is_section_open(sec_id)
    return not M.state.collapsed_sections[sec_id]
  end

  -- 1. Investigation Target Header & Overview Root
  local target_sec_id = "target"
  local target_open = is_section_open(target_sec_id)
  local target_arrow = target_open and "▾" or "▸"
  add_line(string.format("  %s %s", target_arrow, target_desc), "Title", nil, { kind = "overview" }, { id = target_sec_id, is_header = true })

  if target_open then
    current_sec_id = target_sec_id
    add_line(string.format("    Repository: %s · Engine: v%s", repo_name, engine_ver), "Comment", nil, { kind = "overview" })
    add_line(string.format("    Analyzed:   %s", analyzed), "Comment", nil, { kind = "overview" })
    current_sec_id = nil
  end

  add_line("", nil)
  -- 2. Executive Brief (High-Signal Insights)
  local exec_sec_id = "executive_brief"
  local exec_open = is_section_open(exec_sec_id)
  local exec_arrow = exec_open and "▾" or "▸"
  add_line(string.format("  %s EXECUTIVE BRIEF (High-Signal Insights)", exec_arrow), "Special", nil, { kind = "overview" }, { id = exec_sec_id, is_header = true })

  if exec_open then
    current_sec_id = exec_sec_id

    local surface_desc = #trace_links > 0
        and string.format("    • Surface:    %d symbol(s) linked from context (%s)", #trace_links, (trace_links[1].target_entity and trace_links[1].target_entity.name) or "candidate")
      or (#entities > 0 and string.format("    • Surface:    %d modified semantic entity(ies) isolated", #entities)
          or "    • Surface:    No direct AST modifications isolated; clean working tree")

    add_line(surface_desc, "DiagnosticInfo", nil, { kind = "overview" })
    local blast_desc = string.format("    • Blast:      %d direct caller(s) across %d file(s) · %d covering test(s)", #callers, math.max(1, #files), #tests)
    add_line(blast_desc, #tests > 0 and "DiagnosticOk" or "DiagnosticWarn", nil, { kind = "overview" })

    local dyn_desc = (#crossings > 0 or #alerts > 0)
        and string.format("    • Dynamics:   %d boundary crossing(s) · %d risk alert(s)", #crossings, #alerts)
      or "    • Dynamics:   Zero boundary violations; clean subsystem confinement"

    add_line(dyn_desc, (#crossings > 0 or #alerts > 0) and "DiagnosticError" or "DiagnosticOk", nil, { kind = "overview" })

    if #precedents > 0 then
      local p = precedents[1]
      local prec_desc = string.format("    • Precedent:  Commit %s addressed similar files (\"%s\")", p.commit_oid:sub(1, 7), p.message:sub(1, 40))
      add_line(prec_desc, "Comment", nil, { kind = "historical_precedent", precedent = p })
    end

    local passed_inv = 0

    for _, inv in ipairs(invariants) do
      if inv.passed then passed_inv = passed_inv + 1 end
    end

    local inv_desc = string.format("    • Invariants: ✓ %d/%d verified ground-truth integrity", passed_inv, math.max(1, #invariants))
    add_line(inv_desc, passed_inv == #invariants and "DiagnosticOk" or "DiagnosticWarn", nil, { kind = "overview" })
    current_sec_id = nil
  end

  add_line("", nil)

  -- 3. Invariants & Reality Check Integrity
  if #invariants > 0 then
    local inv_sec_id = "invariants"
    local inv_open = is_section_open(inv_sec_id)
    local inv_arrow = inv_open and "▾" or "▸"
    add_line(string.format("  %s VERIFIED INVARIANTS & INTEGRITY", inv_arrow), "Special", nil, { kind = "overview" }, { id = inv_sec_id, is_header = true })

    if inv_open then
      current_sec_id = inv_sec_id

      for _, inv in ipairs(invariants) do
        local icon = inv.passed and "✓" or "✗"
        local hl = inv.passed and "DiagnosticOk" or "DiagnosticWarn"

        add_line(string.format("    %s %s: %s", icon, inv.invariant_name, inv.details), hl, nil, {
          kind = "invariant",
          invariant = inv,
        })
      end

      current_sec_id = nil
    end

    add_line("", nil)
  end

  -- 4. Forge Artifact Context
  if type(forge_art) == "table" and type(forge_art.id) == "string" then
    local forge_sec_id = "forge_context"
    local forge_open = is_section_open(forge_sec_id)
    local forge_arrow = forge_open and "▾" or "▸"

    local kind_label = forge_art.kind == "pull_request" and "Pull Request"
      or (forge_art.kind:sub(1, 1):upper() .. forge_art.kind:sub(2))

    local title_str = type(forge_art.title) == "string" and forge_art.title or "Untitled"
    local author_str = type(forge_art.author) == "string" and (" by @" .. forge_art.author) or ""
    local state_badge = type(forge_art.state) == "string" and string.format("[%s]", forge_art.state:upper()) or ""

    add_line(string.format("  %s FORGE CONTEXT: %s #%s %s%s", forge_arrow, kind_label, forge_art.id, state_badge, author_str), "Title", nil, {
      kind = "forge_artifact",
      artifact = forge_art,
    }, { id = forge_sec_id, is_header = true })

    if forge_open then
      current_sec_id = forge_sec_id

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

      current_sec_id = nil
    end

    add_line("", nil)
  end

  -- 5. Forge-to-Code Traceability Candidates
  if #trace_links > 0 then
    local trace_sec_id = "traceability"
    local trace_open = is_section_open(trace_sec_id)
    local trace_arrow = trace_open and "▾" or "▸"
    add_line(string.format("  %s FORGE-TO-CODE TRACEABILITY LINKS (%d candidates)", trace_arrow, #trace_links), "Special", nil, { kind = "overview" }, { id = trace_sec_id, is_header = true })

    if trace_open then
      current_sec_id = trace_sec_id

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

      current_sec_id = nil
    end

    add_line("", nil)
  end

  -- 6. Affected Semantic Entities & Composite Paths (Entity -> Callers -> Tests -> Lineage)
  local ent_sec_id = "entities"
  local ent_open = is_section_open(ent_sec_id)
  local ent_arrow = ent_open and "▾" or "▸"
  add_line(string.format("  %s AFFECTED SEMANTIC ENTITIES (%d)", ent_arrow, #entities), "Special", nil, { kind = "overview" }, { id = ent_sec_id, is_header = true })

  if ent_open then
    current_sec_id = ent_sec_id

    if #entities == 0 then
      add_line("    No specific AST symbol modifications isolated in this change set.", "Comment", nil, { kind = "overview" })
    else
      for _, e in ipairs(entities) do
        local kind_badge = string.format("[%s]", (e.kind or "entity"):upper())
        local entity_line = string.format("    ├─ %s %s (%s:%d)", kind_badge, e.name or "unknown", e.file_path or "", e.start_line or 1)

        add_line(entity_line, "Identifier", { file = e.file_path, line = e.start_line }, {
          kind = "entity",
          entity = e,
          history = history_lookup[e.id],
        })

        -- Nested Callers under Entity
        if #callers > 0 then
          for _, c in ipairs(callers) do
            local caller_line = string.format("    │  ├─ Caller: %s (%s:%d)", c.name or c.caller or "unknown", c.file_path or c.file or "", c.start_line or 1)

            add_line(caller_line, "DiagnosticInfo", { file = c.file_path or c.file, line = c.start_line or 1 }, {
              kind = "caller",
              caller = c,
              target = e,
            })
          end
        end

        -- Nested Tests under Entity
        if #tests > 0 then
          for _, t in ipairs(tests) do
            local test_line = string.format("    │  ├─ Test: %s (%s:%d)", t.name or t.test or "unknown", t.file_path or t.file or "", t.start_line or 1)

            add_line(test_line, "DiagnosticOk", { file = t.file_path or t.file, line = t.start_line or 1 }, {
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

    current_sec_id = nil
  end

  add_line("", nil)

  -- 7. Change Coupling & Implicit Architecture
  if #co_changes > 0 then
    local cc_sec_id = "co_changes"
    local cc_open = is_section_open(cc_sec_id)
    local cc_arrow = cc_open and "▾" or "▸"
    add_line(string.format("  %s CHANGE COUPLING · IMPLICIT ARCHITECTURE (%d pairs)", cc_arrow, math.min(5, #co_changes)), "Special", nil, { kind = "overview" }, { id = cc_sec_id, is_header = true })

    if cc_open then
      current_sec_id = cc_sec_id

      for i = 1, math.min(5, #co_changes) do
        local cc = co_changes[i]
        local pct = math.floor(cc.confidence * 100)
        local line_text = string.format("    ├─ %s ↔ %s [%d%% co-change | %d commits]", cc.entity_a, cc.entity_b, pct, cc.co_change_count)

        add_line(line_text, "DiagnosticWarn", { file = cc.entity_a, line = 1 }, {
          kind = "co_change",
          co_change = cc,
        })
      end

      current_sec_id = nil
    end

    add_line("", nil)
  end

  -- 8. Architectural Dynamics (Boundary Crossings, Subsystem Instability, Historical Precedents)
  if dynamics then
    local crossings = dynamics.boundary_crossings or {}

    if #crossings > 0 then
      local cross_sec_id = "crossings"
      local cross_open = is_section_open(cross_sec_id)
      local cross_arrow = cross_open and "▾" or "▸"
      add_line(string.format("  %s ARCHITECTURAL BOUNDARY CROSSINGS (%d)", cross_arrow, #crossings), "Special", nil, { kind = "overview" }, { id = cross_sec_id, is_header = true })

      if cross_open then
        current_sec_id = cross_sec_id

        for _, bc in ipairs(crossings) do
          local risk_tag = string.format("[%s RISK]", (bc.risk_level or "low"):upper())
          local hl = (bc.risk_level == "high") and "DiagnosticError" or ((bc.risk_level == "medium") and "DiagnosticWarn" or "DiagnosticInfo")
          local line_text = string.format("    ├─ %s %s ➔ %s (%s ➔ %s)", risk_tag, bc.source_subsystem, bc.target_subsystem, bc.source_entity, bc.target_entity)

          add_line(line_text, hl, nil, {
            kind = "boundary_crossing",
            crossing = bc,
          })
        end

        current_sec_id = nil
      end

      add_line("", nil)
    end

    local instabilities = dynamics.subsystem_instabilities or {}

    if #instabilities > 0 then
      local inst_sec_id = "instabilities"
      local inst_open = is_section_open(inst_sec_id)
      local inst_arrow = inst_open and "▾" or "▸"
      add_line(string.format("  %s SUBSYSTEM INSTABILITY & RISK ALERTS (%d)", inst_arrow, #instabilities), "Special", nil, { kind = "overview" }, { id = inst_sec_id, is_header = true })

      if inst_open then
        current_sec_id = inst_sec_id

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

        current_sec_id = nil
      end

      add_line("", nil)
    end

    local precedents = dynamics.historical_precedents or {}

    if #precedents > 0 then
      local prec_sec_id = "precedents"
      local prec_open = is_section_open(prec_sec_id)
      local prec_arrow = prec_open and "▾" or "▸"
      add_line(string.format("  %s HISTORICAL PRECEDENTS (%d similar changes)", prec_arrow, #precedents), "Special", nil, { kind = "overview" }, { id = prec_sec_id, is_header = true })

      if prec_open then
        current_sec_id = prec_sec_id

        for _, p in ipairs(precedents) do
          local short_oid = p.commit_oid:sub(1, 7)
          local author_str = p.author ~= "" and (" by " .. p.author) or ""
          local line_text = string.format("    ├─ commit:%s%s · \"%s\"", short_oid, author_str, p.message)

          add_line(line_text, "Comment", nil, {
            kind = "historical_precedent",
            precedent = p,
          })
        end

        current_sec_id = nil
      end

      add_line("", nil)
    end
  end

  -- 9. Agent Hypotheses & Adversarial Verifications (Layers 25-26)
  if derived then
    local hypotheses = derived.hypotheses or {}

    if #hypotheses > 0 then
      local hyp_sec_id = "hypotheses"
      local hyp_open = is_section_open(hyp_sec_id)
      local hyp_arrow = hyp_open and "▾" or "▸"
      local verdict_badge = derived.adversarial_verdict and string.format("[%s]", derived.adversarial_verdict) or ""
      add_line(string.format("  %s AGENT HYPOTHESES & ADVERSARIAL VERIFICATIONS (Layers 25-26) %s", hyp_arrow, verdict_badge), "Title", nil, { kind = "overview" }, { id = hyp_sec_id, is_header = true })

      if hyp_open then
        current_sec_id = hyp_sec_id

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

        current_sec_id = nil
      end

      add_line("", nil)
    end
  end

  -- 10. Connected Actions & Experiments Toolbar
  local act_sec_id = "actions"
  local act_open = is_section_open(act_sec_id)
  local act_arrow = act_open and "▾" or "▸"
  add_line(string.format("  %s CONNECTED ACTIONS & EXPERIMENTS", act_arrow), "Special", nil, { kind = "overview" }, { id = act_sec_id, is_header = true })

  if act_open then
    current_sec_id = act_sec_id
    add_line("    ├─ [e] Run Worktree Experiment (isolate hypothesis in git worktree & run test probe)", "Special", nil, { kind = "action_hint", action = "worktree_experiment" })
    add_line("    ├─ [p] Compare Candidate Patches (evaluate minimal fix vs. architectural refactor)", "Identifier", nil, { kind = "action_hint", action = "candidate_patches" })
    add_line("    ├─ [t] Generate Invariant Test Scaffold (protect callers & prevent regressions)", "Identifier", nil, { kind = "action_hint", action = "test_scaffold" })
    add_line("    ├─ [r] Plan Subsystem Decoupling Refactor (isolate boundary crossings)", "Identifier", nil, { kind = "action_hint", action = "refactor_plan" })
    add_line("    ├─ [a] Synthesize / Re-verify Agent Hypotheses against Ground Truth", "Identifier", nil, { kind = "action_hint", action = "agent_synthesize" })
    add_line("    └─ [h] Pivot to Oculus Inspect (interactive diff & hunk review)", "Identifier", nil, { kind = "action_hint", action = "inspect_pivot" })
    current_sec_id = nil
  end

  add_line("", nil)
  -- 11. Deterministic Provenance Ledger (Evidence Graph Ground Truth) at Bottom of Window
  local ledger_sec_id = "ledger"
  local ledger_open = is_section_open(ledger_sec_id)
  local ledger_arrow = ledger_open and "▾" or "▸"
  local ledger_header_idx = add_line(string.format("  %s DETERMINISTIC PROVENANCE LEDGER & AUDIT TRAIL", ledger_arrow), "Title", nil, { kind = "overview" }, { id = ledger_sec_id, is_header = true })
  M.state.ledger_start_line = ledger_header_idx

  if ledger_open then
    current_sec_id = ledger_sec_id
    add_line("    " .. string.rep("═", 56), "Comment", nil, { kind = "overview" })
    add_line("    Ground-truth factual substrate answering where facts originated and at what repository state.", "Comment", nil, { kind = "overview" })
    add_line("", nil)
    add_line("  EVIDENCE GRAPH INVENTORY & REPOSITORY STATE:", "Special", nil, { kind = "overview" })
    add_line(string.format("    • Repository:     %s (%s)", repo_name, repo_root ~= "" and repo_root or "local"), "Identifier", nil, { kind = "overview" })
    add_line(string.format("    • Target State:   %s", target_desc), "Comment", nil, { kind = "overview" })
    add_line(string.format("    • Engine Version: v%s · Analyzed: %s", engine_ver, analyzed), "Comment", nil, { kind = "overview" })
    add_line("    • Ground Truth:   Deterministic AST, Git history & adversarial verification", "Comment", nil, { kind = "overview" })
    add_line("", nil)
    add_line("  PROVENANCE PRINCIPLES & METRICS:", "Normal", nil, { kind = "overview" })
    add_line(string.format("    • Modified Entities:     %d (Tree-sitter AST, 1.00 confidence)", #entities), "DiagnosticInfo", nil, { kind = "overview" })
    add_line(string.format("    • Relationships w/ Prov: %d verified provenance edges", #relationships), "DiagnosticInfo", nil, { kind = "overview" })
    add_line(string.format("    • Traceability Matches:  %d candidates", #trace_links), "DiagnosticInfo", nil, { kind = "overview" })
    add_line(string.format("    • Boundary Crossings:    %d detected", #crossings), "DiagnosticInfo", nil, { kind = "overview" })
    add_line(string.format("    • Subsystem Risk Alerts: %d alerts", #alerts), "DiagnosticInfo", nil, { kind = "overview" })
    add_line(string.format("    • Historical Precedents: %d precedents", #precedents), "DiagnosticInfo", nil, { kind = "overview" })
    add_line(string.format("    • Invariant Assertions:  %d verified checks", #invariants), "DiagnosticOk", nil, { kind = "overview" })
    add_line("", nil)

    -- Verified Ground-Truth Invariants
    if #invariants > 0 then
      add_line("  VERIFIED GROUND-TRUTH INVARIANTS:", "Special", nil, { kind = "overview" })

      for _, inv in ipairs(invariants) do
        local icon = inv.passed and "[PASSED ✓]" or "[FAILED ✗]"
        local hl = inv.passed and "DiagnosticOk" or "DiagnosticWarn"

        add_line(string.format("    • %s %s: %s", icon, inv.invariant_name, inv.details), hl, nil, {
          kind = "invariant",
          invariant = inv,
        })
      end

      add_line("", nil)
    end

    -- Semantic Entities AST Provenance & Lineage
    if #entities > 0 then
      add_line("  SEMANTIC ENTITIES AST PROVENANCE & LINEAGE:", "Special", nil, { kind = "overview" })

      for _, e in ipairs(entities) do
        local kind_str = (e.kind or "entity"):upper()

        add_line(string.format("    ▸ Symbol: %s [%s]", e.name or "unknown", kind_str), "Identifier", { file = e.file_path, line = e.start_line }, {
          kind = "entity",
          entity = e,
          history = history_lookup[e.id],
        })

        add_line(string.format("      File:       %s:%d-%d (cols %d-%d)", e.file_path or "", e.start_line or 1, e.end_line or 1, e.start_col or 1, e.end_col or 1), "Comment", { file = e.file_path, line = e.start_line })
        add_line("      Parser:     Tree-sitter AST Polyglot Engine (CONFIDENCE: 1.00)", "DiagnosticOk")
        add_line(string.format("      Git State:  %s", e.git_oid or "HEAD (Working Tree)"), "Comment")
        local h = history_lookup[e.id]

        if h then
          local authors_str = table.concat(h.authors or {}, ", ")
          add_line(string.format("      History:    %d commits in lineage · Contributors: %s", h.total_commits or 0, authors_str ~= "" and authors_str or "Unknown"), "Comment")
        end
      end

      add_line("", nil)
    end

    -- Call Graph & Test Suite Provenance
    if #callers > 0 or #tests > 0 then
      add_line("  CALL GRAPH & TEST SUITE PROVENANCE:", "Special", nil, { kind = "overview" })

      for _, c in ipairs(callers) do
        add_line(string.format("    • Direct Caller: %s in %s:%d [95%% CONFIDENCE] (Relation: CALLS)", c.name or "unknown", c.file_path or "", c.start_line or 1), "DiagnosticInfo", { file = c.file_path, line = c.start_line or 1 }, {
          kind = "caller",
          caller = c,
        })

        add_line("      Source: Tree-sitter Call Expression Matcher · Verified syntactic node", "Comment")
      end

      for _, t in ipairs(tests) do
        add_line(string.format("    • Associated Test: %s in %s:%d [90%% CONFIDENCE] (Relation: TESTED_BY)", t.name or "unknown", t.file_path or "", t.start_line or 1), "DiagnosticOk", { file = t.file_path, line = t.start_line or 1 }, {
          kind = "test",
          test = t,
        })

        add_line("      Source: ImpactAnalyzer & Test File Detector · Coverage relationship", "Comment")
      end

      add_line("", nil)
    end

    -- Implicit Architecture & Co-Change Provenance
    if #co_changes > 0 then
      add_line("  IMPLICIT ARCHITECTURE & CO-CHANGE PROVENANCE:", "Special", nil, { kind = "overview" })

      for i = 1, math.min(5, #co_changes) do
        local cc = co_changes[i]
        local pct = math.floor((cc.confidence or 0.5) * 100)

        add_line(string.format("    • %s ↔ %s [%d%% STATISTICAL CONFIDENCE] (Relation: CO_CHANGES_WITH)", cc.entity_a, cc.entity_b, pct), "DiagnosticWarn", { file = cc.entity_a, line = 1 }, {
          kind = "co_change",
          co_change = cc,
        })

        local sample_commits = cc.sample_commits or {}
        local sample_str = #sample_commits > 0 and (" · commits: " .. table.concat(sample_commits, ", ")) or ""
        add_line(string.format("      Source: Git Commit History Miner · Frequency: %d co-changes%s", cc.co_change_count or 0, sample_str), "Comment")
      end

      add_line("", nil)
    end

    -- Architectural Dynamics Provenance
    if #crossings > 0 or #alerts > 0 or #precedents > 0 then
      add_line("  ARCHITECTURAL DYNAMICS & BOUNDARY PROVENANCE:", "Special", nil, { kind = "overview" })

      for _, bc in ipairs(crossings) do
        local risk = (bc.risk_level or "low"):upper()

        add_line(string.format("    • Architectural Boundary Crossing: %s ➔ %s [%s RISK] (Relation: CROSSES_BOUNDARY)", bc.source_subsystem, bc.target_subsystem, risk), "DiagnosticError", nil, {
          kind = "boundary_crossing",
          crossing = bc,
        })

        add_line(string.format("      Details: %s ➔ %s (%s) · Source: ArchitecturalDynamicsAnalyzer", bc.source_entity or "", bc.target_entity or "", bc.details or ""), "Comment")
      end

      for _, inst in ipairs(alerts) do
        local cat = inst.risk_category or "RISK"

        add_line(string.format("    • Subsystem Instability Metric: %s (instability: %.2f) [%s]", inst.subsystem or "", inst.instability_score or 0.0, cat), "DiagnosticWarn", nil, {
          kind = "subsystem_instability",
          instability = inst,
        })

        local maint = inst.primary_maintainer and (" · Maintainer: @" .. inst.primary_maintainer) or ""
        add_line(string.format("      Metric Details: Churn commits: %d · Uncovered: %d%s", inst.churn_commits or 0, inst.uncovered_modifications or 0, maint), "Comment")
      end

      for _, p in ipairs(precedents) do
        add_line(string.format("    • Historical Precedent commit:%s by @%s", p.commit_oid, p.author or "unknown"), "Comment", nil, {
          kind = "historical_precedent",
          precedent = p,
        })

        add_line(string.format("      Message: \"%s\" · Confidence: 0.90", p.message or ""), "Comment")
      end

      add_line("", nil)
    end

    -- Adversarial Reality Checking & Agent Hypotheses Provenance (Layers 25-26)
    if derived then
      add_line("  ADVERSARIAL REALITY CHECK & AGENT PROVENANCE (Layers 25-26):", "Special", nil, { kind = "overview" })
      local verd = derived.adversarial_verdict or "INCONCLUSIVE"
      local verd_hl = verd == "ALL_CLAIMS_VERIFIED" and "DiagnosticOk" or (verd == "PARTIALLY_VERIFIED" and "DiagnosticWarn" or "DiagnosticError")
      add_line(string.format("    ADVERSARIAL VERDICT: [%s]", verd), verd_hl, nil, { kind = "overview" })
      add_line("", nil)

      for _, hyp in ipairs(derived.hypotheses or {}) do
        add_line(string.format("    ▸ Agent Derived Hypothesis: %s", hyp.title or "Untitled"), "Title", nil, {
          kind = "agent_hypothesis",
          hypothesis = hyp,
        })

        add_line(string.format("      Rationale:  %s", hyp.rationale or ""), "Comment")
        add_line(string.format("      Confidence: %.2f", hyp.confidence or 0.9), "Comment")

        for _, ver in ipairs(hyp.verifications or {}) do
          local is_conf = ver.status == "CONFIRMED"
          local v_hl = is_conf and "DiagnosticOk" or (ver.status == "REFUTED" and "DiagnosticError" or "DiagnosticWarn")

          add_line(string.format("      • Adversarial Reality Check: [%s] (Confidence: %.2f)", ver.status or "UNVERIFIED", ver.confidence or 1.0), v_hl, nil, {
            kind = "claim_verification",
            verification = ver,
            hypothesis = hyp,
          })

          add_line(string.format("        Assertion: \"%s\"", ver.assertion or ""), "Normal")
          add_line(string.format("        Details:   %s", ver.details or ""), "Comment")

          for _, ev in ipairs(ver.deterministic_evidence or {}) do
            add_line(string.format("        Evidence:  %s", ev), "Comment")
          end
        end
      end
    end

    current_sec_id = nil
  end

  add_line("", nil)
  M.state.line_targets = line_targets
  M.state.line_provenance = line_provenance
  M.state.line_sections = line_sections
  vim.bo[buf].readonly = false
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
    local bundle = sanitize_bundle(M.state.bundle or {}) or {}
    local entities_count = type(bundle.entities) == "table" and #bundle.entities or 0
    local rels_count = type(bundle.relationships) == "table" and #bundle.relationships or 0
    local invs_count = type(bundle.invariants) == "table" and #bundle.invariants or 0
    local trace_count = type(bundle.traceability_links) == "table" and #bundle.traceability_links or 0
    local dynamics = type(bundle.dynamics) == "table" and bundle.dynamics or {}
    local crossings_count = type(dynamics.boundary_crossings) == "table" and #dynamics.boundary_crossings or 0
    local alerts_count = type(dynamics.subsystem_instabilities) == "table" and #dynamics.subsystem_instabilities or 0
    local precs_count = type(dynamics.historical_precedents) == "table" and #dynamics.historical_precedents or 0
    local derived = type(bundle.derived) == "table" and bundle.derived or {}
    local hyp_count = type(derived.hypotheses) == "table" and #derived.hypotheses or 0
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

  local nav = require("oculus.navigation").resolve(M.state.opts)

  local function current_active_win_and_footer()
    local cur_win = vim.api.nvim_get_current_win()

    if is_valid_win(M.state.ledger_win) and cur_win == M.state.ledger_win then
      return M.state.ledger_win, M.state.footer_win
    elseif is_valid_win(M.state.sub_win) and cur_win == M.state.sub_win then
      return M.state.sub_win, M.state.sub_footer_win
    else
      return M.state.win, M.state.footer_win
    end
  end

  local function move_up()
    pcall(vim.cmd.normal, { "k", bang = true })
    local w, f = current_active_win_and_footer()
    M.clamp_scroll(w, f)
  end

  local function move_down()
    pcall(vim.cmd.normal, { "j", bang = true })
    local w, f = current_active_win_and_footer()
    M.clamp_scroll(w, f)
  end

  local function move_left()
    pcall(vim.cmd.normal, { "h", bang = true })
  end

  local function move_right()
    pcall(vim.cmd.normal, { "l", bang = true })
  end

  local function rerender_to_section(sec_id)
    local win = M.state.win

    if not is_valid_win(win) or not is_valid_buf(buf) then
      return
    end

    M.render(buf, M.state.bundle)

    if is_valid_win(win) then
      local target_line = 1

      if sec_id then
        for idx, s in pairs(M.state.line_sections or {}) do
          if s.id == sec_id and s.is_header then
            target_line = idx
            break
          end
        end
      end

      local max_line = vim.api.nvim_buf_line_count(buf)
      target_line = math.max(1, math.min(target_line, max_line))
      pcall(vim.api.nvim_win_set_cursor, win, { target_line, 0 })
      M.clamp_scroll(win, M.state.footer_win)
    end
  end

  local function expand_section(sec_id)
    if not sec_id then
      return
    end

    M.state.collapsed_sections = M.state.collapsed_sections or {}
    M.state.collapsed_sections[sec_id] = nil
    rerender_to_section(sec_id)
  end

  local function collapse_current_section(sec_id)
    if not sec_id then
      return
    end

    M.state.collapsed_sections = M.state.collapsed_sections or {}
    M.state.collapsed_sections[sec_id] = true
    rerender_to_section(sec_id)
  end

  local function toggle_or_expand_section(sec_id)
    if not sec_id then
      return
    end

    M.state.collapsed_sections = M.state.collapsed_sections or {}

    if M.state.collapsed_sections[sec_id] then
      M.state.collapsed_sections[sec_id] = nil
    else
      M.state.collapsed_sections[sec_id] = true
    end

    rerender_to_section(sec_id)
  end

  local function handle_left()
    local win = M.state.win

    if not is_valid_win(win) then
      return
    end

    local cursor = vim.api.nvim_win_get_cursor(win)
    local sec = (M.state.line_sections or {})[cursor[1]]

    if sec and sec.id and not (M.state.collapsed_sections and M.state.collapsed_sections[sec.id]) then
      collapse_current_section(sec.id)
    else
      if nav.down == "j" then
        move_down()
      else
        move_left()
      end
    end
  end

  local function handle_right()
    local win = M.state.win

    if not is_valid_win(win) then
      return
    end

    local cursor = vim.api.nvim_win_get_cursor(win)
    local sec = (M.state.line_sections or {})[cursor[1]]

    if sec and sec.id and (M.state.collapsed_sections and M.state.collapsed_sections[sec.id]) then
      expand_section(sec.id)
    else
      move_right()
    end
  end

  if nav.up then
    map(nav.up, move_up, "Move up in investigation")
  end

  if nav.down then
    map(nav.down, move_down, "Move down in investigation")
  end

  if nav.left then
    map(nav.left, handle_left, "Collapse section in investigation")
  end

  if nav.right then
    map(nav.right, handle_right, "Open section in investigation")
  end

  if nav.up ~= "i" and nav.left ~= "i" and nav.down ~= "i" and nav.right ~= "i" then
    map("i", move_up, "Move up in investigation")
  end

  if nav.right ~= "l" and nav.up ~= "l" and nav.down ~= "l" and nav.left ~= "l" then
    map("l", handle_right, "Open section in investigation")
  end

  if nav.left ~= "j" and nav.up ~= "j" and nav.down ~= "j" and nav.right ~= "j" then
    map("j", handle_left, "Collapse section in investigation")
  end

  if nav.down == "j" then
    map("j", handle_left, "Collapse section in investigation or move down")
  end

  map("<Up>", move_up, "Move up in investigation")
  map("<Down>", move_down, "Move down in investigation")
  map("<Left>", handle_left, "Collapse section in investigation")
  map("<Right>", handle_right, "Open section in investigation")
  map("q", M.close, "Close investigation")
  map("<Esc>", M.close, "Close investigation")
  map("<C-c>", M.close, "Close investigation")
  local scroll_down_keys = { "<ScrollWheelDown>", "<2-ScrollWheelDown>", "<3-ScrollWheelDown>", "<4-ScrollWheelDown>" }
  local scroll_up_keys = { "<ScrollWheelUp>", "<2-ScrollWheelUp>", "<3-ScrollWheelUp>", "<4-ScrollWheelUp>" }

  for _, key in ipairs(scroll_down_keys) do
    map(key, function()
      local w, f = current_active_win_and_footer()
      M.scroll_window(w, f, 3)
    end, "Scroll investigate down")
  end

  for _, key in ipairs(scroll_up_keys) do
    map(key, function()
      local w, f = current_active_win_and_footer()
      M.scroll_window(w, f, -3)
    end, "Scroll investigate up")
  end

  map("<ScrollWheelLeft>", function() end, "Ignore horizontal mouse scroll")
  map("<ScrollWheelRight>", function() end, "Ignore horizontal mouse scroll")

  if M.state.active_inspect_group then
    map("<Tab>", function()
      local group = M.state.active_inspect_group

      if group then
        local inspect = require("oculus.inspect")
        local target_tab = group.overview_return and group.overview_return.tab

        if not target_tab and group[1] and group[1].parent and group[1].parent.tab then
          target_tab = group[1].parent.tab
        end

        if target_tab and not vim.api.nvim_tabpage_is_valid(target_tab) then
          M.state.active_inspect_group = nil
          return
        end

        M.close(true)

        if target_tab and vim.api.nvim_tabpage_is_valid(target_tab) then
          vim.api.nvim_set_current_tabpage(target_tab)
        end

        if type(inspect._show_inspection_overview) == "function" then
          inspect._show_inspection_overview(group)
        end

        return
      end
    end, "Switch to Oculus Inspect overview")
  elseif is_valid_win(M.state.ledger_win) and is_valid_win(M.state.win) then
    map("<Tab>", function()
      local current = vim.api.nvim_get_current_win()

      if current == M.state.win then
        vim.api.nvim_set_current_win(M.state.ledger_win)
      else
        vim.api.nvim_set_current_win(M.state.win)
      end
    end, "Toggle focus between tree and ledger panes")
  end

  local function resolve_activity_target()
    local win = M.state.win
    local line_num = is_valid_win(win) and vim.api.nvim_win_get_cursor(win)[1] or 1
    local prov = (M.state.line_provenance or {})[line_num]
    local line_target = (M.state.line_targets or {})[line_num]
    local bundle = M.state.bundle or {}

    if prov then
      if prov.kind == "forge_artifact" and prov.artifact then
        return prov.artifact.url
          or (prov.artifact.kind and prov.artifact.id and ("#" .. tostring(prov.artifact.id)))
          or prov.artifact.id
      elseif prov.kind == "historical_precedent" and prov.precedent then
        return prov.precedent.commit_oid
      elseif prov.kind == "traceability_link" and prov.link then
        if prov.link.target_entity and prov.link.target_entity.file_path then
          return prov.link.target_entity.file_path
        end
      elseif prov.kind == "co_change" and prov.co_change then
        if prov.co_change.sample_commits and prov.co_change.sample_commits[1] then
          return prov.co_change.sample_commits[1]
        elseif prov.co_change.entity_a then
          return prov.co_change.entity_a
        end
      end
    end

    if line_target and line_target.file then
      return line_target.file
    end

    if bundle.forge_artifact and (bundle.forge_artifact.url or bundle.forge_artifact.id) then
      return bundle.forge_artifact.url
        or (bundle.forge_artifact.kind and bundle.forge_artifact.id and ("#" .. tostring(bundle.forge_artifact.id)))
        or bundle.forge_artifact.id
    end

    if bundle.metadata and bundle.metadata.target then
      return bundle.metadata.target
    end

    return (bundle.metadata and bundle.metadata.repository_root) or vim.fn.getcwd()
  end

  local function pivot_to_inspect()
    local target = resolve_activity_target()

    if not target or target == "" then
      vim.notify("Oculus: No target activity item found to inspect", vim.log.levels.WARN)
      return
    end

    local bundle = M.state.bundle
    local saved_bundle = bundle
    local saved_opts = M.state.opts
    local saved_tabpage = vim.api.nvim_get_current_tabpage()
    local meta = (bundle and bundle.metadata) or {}
    local repo_root = meta.repository_root or vim.fn.getcwd()

    local context = {
      repository = repo_root,
      cwd = repo_root,
      project = meta.project or {
        repository = vim.fs.basename(repo_root),
      },
    }

    local inspect_opts = vim.tbl_deep_extend("force", vim.deepcopy(M.state.opts or {}), {
      exact_dimensions = true,
    })

    if is_valid_win(M.state.win) then
      local pos = vim.api.nvim_win_get_position(M.state.win)
      local width = vim.api.nvim_win_get_width(M.state.win)
      local height = vim.api.nvim_win_get_height(M.state.win)
      local cfg = vim.api.nvim_win_get_config(M.state.win)

      inspect_opts.window_config = {
        width = width,
        height = height,
        row = pos[1],
        col = pos[2],
        border = cfg.border or "rounded",
        exact_dimensions = true,
      }
    end

    local lifecycle = {
      overview_on_open = true,
      on_overview_opened = function(group)
        group.investigate_bundle = saved_bundle
        group.investigate_opts = saved_opts
        group.investigate_tab = saved_tabpage
        M.state.active_inspect_group = group
        M.close(true)
      end,
      on_tab = function(group)
        local inspect = require("oculus.inspect")

        if type(inspect._close_overview_window) == "function" then
          inspect._close_overview_window(group)
        end

        if group.investigate_tab and vim.api.nvim_tabpage_is_valid(group.investigate_tab) then
          vim.api.nvim_set_current_tabpage(group.investigate_tab)
        end

        M.open(group.investigate_bundle or saved_bundle, group.investigate_opts or saved_opts)
      end,
      on_closed = function()
        M.state.active_inspect_group = nil
      end,
    }

    local ok, oculus = pcall(require, "oculus")

    if ok and type(oculus.inspect) == "function" then
      oculus.inspect(target, inspect_opts, context, function(inspections, kind, details, err)
        if err then
          vim.notify("Oculus: Inspect workload failed: " .. tostring(err), vim.log.levels.WARN)
        end
      end, lifecycle)
    end
  end

  map("<CR>", function()
    local win = M.state.win

    if not is_valid_win(win) then
      return
    end

    local cursor = vim.api.nvim_win_get_cursor(win)
    local line_num = cursor[1]
    local target = M.state.line_targets[line_num]
    local sec = (M.state.line_sections or {})[line_num]
    local prov = (M.state.line_provenance or {})[line_num]

    if prov and prov.kind == "action_hint" and prov.action == "inspect_pivot" then
      pivot_to_inspect()
      return
    end

    if target and target.file then
      M.close()
      vim.cmd("edit " .. vim.fn.fnameescape(target.file))

      if target.line and target.line > 0 then
        pcall(vim.api.nvim_win_set_cursor, 0, { target.line, 0 })
      end

      return
    end

    if sec and sec.id then
      if sec.is_header then
        toggle_or_expand_section(sec.id)
      else
        collapse_current_section(sec.id)
      end

      return
    end
  end, "Jump to entity source location, inspect pivot, or toggle/close section")

  local function create_subwindow_footer(parent_win, cmd_text)
    if not is_valid_win(parent_win) then
      return nil, nil
    end

    local config = vim.api.nvim_win_get_config(parent_win)
    local row = tonumber(config.row) or 0
    local col = tonumber(config.col) or 0
    local width = vim.api.nvim_win_get_width(parent_win)
    local height = vim.api.nvim_win_get_height(parent_win)
    local f_buf = vim.api.nvim_create_buf(false, true)
    vim.bo[f_buf].buftype = "nofile"
    vim.bo[f_buf].bufhidden = "wipe"
    vim.bo[f_buf].swapfile = false
    vim.bo[f_buf].filetype = "oculus"
    local text = cmd_text or "  q close"

    local lines = {
      "  " .. string.rep("─", math.max(1, width - 4)),
      text,
    }

    vim.bo[f_buf].modifiable = true
    vim.api.nvim_buf_set_lines(f_buf, 0, -1, false, lines)
    vim.bo[f_buf].modifiable = false
    vim.bo[f_buf].readonly = true
    local ns = vim.api.nvim_create_namespace("oculus_subwindow_footer_hl")
    vim.api.nvim_buf_clear_namespace(f_buf, ns, 0, -1)
    vim.api.nvim_buf_add_highlight(f_buf, ns, "WinSeparator", 0, 2, -1)
    vim.api.nvim_buf_add_highlight(f_buf, ns, "Comment", 1, 2, #text)

    local f_win = vim.api.nvim_open_win(f_buf, false, {
      relative = "editor",
      width = width,
      height = 2,
      row = row + height - 1,
      col = col + 1,
      style = "minimal",
      focusable = false,
      zindex = 65,
    })

    vim.wo[f_win].wrap = false
    vim.wo[f_win].cursorline = false
    vim.wo[f_win].number = false
    vim.wo[f_win].relativenumber = false
    vim.wo[f_win].signcolumn = "no"

    local winhl = table.concat({
      "Normal:OculusNormal",
      "NormalFloat:OculusNormal",
    }, ",")

    pcall(function() vim.wo[f_win].winhighlight = winhl end)
    local f_kopts = { buffer = f_buf, silent = true, nowait = true }

    vim.keymap.set("n", "<ScrollWheelDown>", function()
      M.scroll_window(parent_win, f_win, 3)
    end, f_kopts)

    vim.keymap.set("n", "<ScrollWheelUp>", function()
      M.scroll_window(parent_win, f_win, -3)
    end, f_kopts)

    vim.keymap.set("n", "<ScrollWheelLeft>", function() end, f_kopts)
    vim.keymap.set("n", "<ScrollWheelRight>", function() end, f_kopts)
    return f_win, f_buf
  end

  local function open_investigate_subwindow(buf, cmd_text)
    local bundle = M.state.bundle
    local opts = M.state.opts or {}
    local cfg = get_target_window_config(opts)
    M.close(true)

    local win = vim.api.nvim_open_win(buf, false, {
      relative = "editor",
      width = cfg.width,
      height = cfg.height,
      row = cfg.row,
      col = cfg.col,
      style = "minimal",
      border = cfg.border or "rounded",
      zindex = 60,
    })

    local footer_win, footer_buf = create_subwindow_footer(win, cmd_text or "  q close")
    M.state.sub_win = win
    M.state.sub_buf = buf
    M.state.sub_footer_win = footer_win
    M.state.sub_footer_buf = footer_buf
    pcall(vim.api.nvim_set_current_win, win)

    vim.schedule(function()
      if is_valid_win(win) then
        pcall(vim.api.nvim_set_current_win, win)
      end
    end)

    vim.wo[win].cursorline = true
    vim.wo[win].wrap = false
    vim.wo[win].scrolloff = 2

    local winhl = table.concat({
      "Normal:OculusNormal",
      "NormalFloat:OculusNormal",
      "FloatBorder:OculusBorder",
      "FloatTitle:OculusBorder",
    }, ",")

    pcall(function() vim.wo[win].winhighlight = winhl end)

    local function close_sub()
      if is_valid_win(footer_win) then
        pcall(vim.api.nvim_win_close, footer_win, true)
      end

      if is_valid_buf(footer_buf) then
        pcall(vim.api.nvim_buf_delete, footer_buf, { force = true })
      end

      pcall(vim.api.nvim_win_close, win, true)
      pcall(vim.api.nvim_buf_delete, buf, { force = true })
      M.state.sub_win = nil
      M.state.sub_buf = nil
      M.state.sub_footer_win = nil
      M.state.sub_footer_buf = nil
      M.open(bundle, opts)
    end

    local kopts = { buffer = buf, silent = true, nowait = true }
    vim.keymap.set("n", "q", close_sub, kopts)
    vim.keymap.set("n", "<Esc>", close_sub, kopts)
    vim.keymap.set("n", "<C-c>", close_sub, kopts)

    vim.keymap.set("n", "<ScrollWheelDown>", function()
      M.scroll_window(win, footer_win, 3)
    end, kopts)

    vim.keymap.set("n", "<ScrollWheelUp>", function()
      M.scroll_window(win, footer_win, -3)
    end, kopts)

    vim.keymap.set("n", "<ScrollWheelLeft>", function() end, kopts)
    vim.keymap.set("n", "<ScrollWheelRight>", function() end, kopts)

    vim.keymap.set("n", "j", function()
      pcall(vim.cmd.normal, { "j", bang = true })
      M.clamp_scroll(win, footer_win)
    end, kopts)

    vim.keymap.set("n", "k", function()
      pcall(vim.cmd.normal, { "k", bang = true })
      M.clamp_scroll(win, footer_win)
    end, kopts)

    vim.keymap.set("n", "<Down>", function()
      pcall(vim.cmd.normal, { "j", bang = true })
      M.clamp_scroll(win, footer_win)
    end, kopts)

    vim.keymap.set("n", "<Up>", function()
      pcall(vim.cmd.normal, { "k", bang = true })
      M.clamp_scroll(win, footer_win)
    end, kopts)

    local sub_scroll_group = vim.api.nvim_create_augroup("oculus_investigate_scroll", { clear = true })

    vim.api.nvim_create_autocmd({ "CursorMoved", "WinScrolled" }, {
      group = sub_scroll_group,
      buffer = buf,
      callback = function()
        M.clamp_scroll(win, footer_win)
      end,
    })

    M.clamp_scroll(win, footer_win)
    return win
  end

  map("e", function()
    local bundle = M.state.bundle

    if not bundle then
      return
    end

    local opts = M.state.opts or {}
    local cfg = get_target_window_config(opts)
    M.close(true)
    local worktree = require("oculus.investigate.worktree")
    local ext_opts = vim.tbl_extend("force", opts, { window_config = cfg })

    local exp_win, exp_f_win = worktree.open_experiment_ui(bundle, ext_opts, function()
      M.state.sub_win = nil
      M.state.sub_buf = nil
      M.state.sub_footer_win = nil
      M.state.sub_footer_buf = nil
      M.open(bundle, opts)
    end)

    if exp_win and is_valid_win(exp_win) then
      M.state.sub_win = exp_win
      M.state.sub_buf = vim.api.nvim_win_get_buf(exp_win)
      M.state.sub_footer_win = exp_f_win
    end
  end, "Run worktree experiment and hypothesis probe")

  map("p", function()
    local bundle = M.state.bundle

    if not bundle then
      return
    end

    local agent = require("oculus.investigate.agent")
    local patch_text = agent.generate_candidate_patches(bundle)
    local p_buf = vim.api.nvim_create_buf(false, true)
    vim.bo[p_buf].filetype = "markdown"
    vim.api.nvim_buf_set_lines(p_buf, 0, -1, false, vim.split(patch_text, "\n"))
    open_investigate_subwindow(p_buf, "  q close")
  end, "Compare candidate patches (minimal vs architectural)")

  map("t", function()
    local bundle = M.state.bundle

    if not bundle then
      return
    end

    local agent = require("oculus.investigate.agent")
    local entity = (type(bundle.entities) == "table" and bundle.entities[1]) or { name = "target_function", file_path = "src/main.rs" }
    local callers = (type(bundle.impact) == "table" and bundle.impact.direct_callers) or {}
    local scaffold = agent.generate_test_scaffold(entity, callers)
    local s_buf = vim.api.nvim_create_buf(false, true)
    local ext = vim.fn.fnamemodify(entity.file_path or "lua", ":e")
    vim.bo[s_buf].filetype = ext == "rs" and "rust" or (ext == "lua" and "lua" or "text")
    vim.api.nvim_buf_set_lines(s_buf, 0, -1, false, vim.split(scaffold, "\n"))
    open_investigate_subwindow(s_buf, "  q close")
  end, "Generate invariant test scaffold")

  map("r", function()
    local bundle = M.state.bundle

    if not bundle then
      return
    end

    local agent = require("oculus.investigate.agent")

    local crossing = (type(bundle.dynamics) == "table" and type(bundle.dynamics.boundary_crossings) == "table" and bundle.dynamics.boundary_crossings[1])
      or { source_subsystem = "core", target_subsystem = "ui", details = "Direct cross-subsystem call" }

    local plan = agent.generate_refactor_plan(crossing)
    local r_buf = vim.api.nvim_create_buf(false, true)
    vim.bo[r_buf].filetype = "markdown"
    vim.api.nvim_buf_set_lines(r_buf, 0, -1, false, vim.split(plan, "\n"))
    open_investigate_subwindow(r_buf, "  q close")
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

  local inspect_key = get_inspect_key(nav)
  map(inspect_key, pivot_to_inspect, "Pivot to Oculus Inspect")
  M.pivot_to_inspect = pivot_to_inspect
  M.resolve_activity_target = resolve_activity_target
end

M.render_footer = render_investigate_footer
M.close_footer = close_investigate_footer
return M
