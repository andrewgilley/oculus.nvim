local M = {}
local client = require("oculus.plexus.client")

local function text(value)
  if value == nil or value == vim.NIL then return "—" end
  return tostring(value):gsub("[%c]", " ")
end

local function set_lines(buf, lines)
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
end

local function render(report, validations)
  assert(report.kind == "rust_capability_delta" and type(report.report_id) == "string", "Missing capability report")
  assert(type(report.producer) == "table" and type(report.consumer) == "table", "Missing projects")
  assert(type(report.deltas) == "table" and type(report.opportunities) == "table", "Missing deltas/opportunities")
  local producer = report.producer

  local lines = {
    "  PLEXUS · RUST CAPABILITY OPPORTUNITIES",
    "  Enter source · p validate selected fixture · r rediscover · c cancel · q close",
    "  Ready", "",
    "  " .. text(producer.project) .. " → " .. text(report.consumer.project),
    "  " .. #report.opportunities .. " opportunities · " .. #report.deltas .. " API deltas (listed below)",
  }

  lines[#lines + 1] = ""
  lines[#lines + 1] = "  OPPORTUNITIES · inferred, not implementation support"
  local targets = {}

  for _, opportunity in ipairs(report.opportunities) do
    assert(type(opportunity.id) == "string" and type(opportunity.consumer_location) == "table", "Invalid opportunity")
    local start = #lines + 1
    lines[#lines + 1] = "  " .. text(opportunity.title) .. " · " .. text(opportunity.status)
    lines[#lines + 1] = "    " .. text(opportunity.explanation)
    local source = opportunity.consumer_location
    lines[#lines + 1] = "    Source: " .. text(source.path) .. ":" .. text(source.line)
    lines[#lines + 1] = "    Source digest: " .. text(source.digest)

    for _, step in ipairs(opportunity.evidence_path or {}) do
      lines[#lines + 1] = "    " .. text(step.relation) .. " → " .. text(step.description)

      if type(step.source) == "table" then
        lines[#lines + 1] = "      " .. text(step.source.path) .. ":" .. text(step.source.line)
          .. " · " .. text(step.source.artifact)
      end
    end

    for _, limitation in ipairs(opportunity.limitations or {}) do
      lines[#lines + 1] = "    Limit: " .. text(limitation)
    end

    if type(opportunity.validation) == "table" then
      lines[#lines + 1] = "    p: " .. text(opportunity.validation.label)
    else
      lines[#lines + 1] = "    Validation: no generated fixture"
    end

    local validation = validations[opportunity.id]

    if validation then
      lines[#lines + 1] = "    Fixture result: " .. text(validation.status) .. " · " .. text(validation.validation_id)
      lines[#lines + 1] = "      " .. text(validation.diagnostic)
      lines[#lines + 1] = "      Scoped to this fixture; opportunity remains inferred."
    end

    for row = start, #lines do targets[row] = opportunity end
    lines[#lines + 1] = ""
  end

  if #report.opportunities == 0 then lines[#lines + 1] = "  No opportunities matched the supported rules." end

  for _, limitation in ipairs(report.limitations or {}) do
    lines[#lines + 1] = "  Limit: " .. text(limitation)
  end

  lines[#lines + 1] = ""
  lines[#lines + 1] = "  PROVENANCE"
  lines[#lines + 1] = "  Report: " .. text(report.report_id)
  lines[#lines + 1] = "  Rule: " .. text(report.rule_version)
  lines[#lines + 1] = "  Revisions: " .. text(producer.before_revision) .. " → " .. text(producer.after_revision)
  lines[#lines + 1] = "  Snapshots: " .. text(producer.before_snapshot) .. " → " .. text(producer.after_snapshot)
  lines[#lines + 1] = ""
  lines[#lines + 1] = "  ALL API DELTAS"

  for _, delta in ipairs(report.deltas) do
    lines[#lines + 1] = "  " .. text(delta.kind) .. " · " .. text(delta.path)
  end

  return lines, targets
end

function M.open(config, manifest)
  if M.state and not M.state.closed then M.state.close() end
  assert(type(manifest) == "string" and vim.trim(manifest) ~= "", "A Rust discovery manifest is required")
  config = vim.deepcopy(config or {})
  config.store = vim.fn.fnamemodify(config.store or vim.fn.stdpath("data") .. "/oculus/plexus", ":p")

  local state = {
    config = config, manifest = vim.fn.fnamemodify(manifest, ":p"), generation = 0,
    source_win = vim.api.nvim_get_current_win(), validations = {}, targets = {},
  }

  M.state = state
  -- A normal split preserves the source window and avoids floating border UI.
  vim.cmd("botright vnew")
  state.win, state.buf = vim.api.nvim_get_current_win(), vim.api.nvim_get_current_buf()
  vim.bo[state.buf].buftype = "nofile"
  vim.bo[state.buf].bufhidden = "wipe"
  vim.bo[state.buf].swapfile = false
  vim.bo[state.buf].filetype = "oculus-capabilities"
  vim.wo[state.win].wrap = true
  vim.wo[state.win].number = false
  vim.wo[state.win].relativenumber = false

  local function status(message)
    if state.closed or not vim.api.nvim_buf_is_valid(state.buf) then return end
    vim.bo[state.buf].modifiable = true
    vim.api.nvim_buf_set_lines(state.buf, 2, 3, false, { "  " .. text(message) })
    vim.bo[state.buf].modifiable = false
  end

  local function failure(message)
    state.error = tostring(message)
    status("Error: " .. state.error)
    vim.notify("Oculus capabilities: " .. state.error, vim.log.levels.WARN)
  end

  function state.cancel()
    state.generation = state.generation + 1
    if state.pending then state.pending.cancel() end
    state.pending, state.busy = nil, false
    status("Cancelled locally; previously stored results remain available.")
  end

  function state.close()
    if state.closed then return end
    state.cancel()
    state.closed = true

    if vim.api.nvim_win_is_valid(state.win) then
      local closed = pcall(vim.api.nvim_win_close, state.win, true)
      if not closed then vim.api.nvim_win_set_buf(state.win, vim.api.nvim_create_buf(true, false)) end
    end
  end

  vim.api.nvim_create_autocmd("WinClosed", { pattern = tostring(state.win), once = true, callback = state.close })

  vim.api.nvim_create_autocmd("BufWipeout", {
    buffer = state.buf, once = true, callback = function()
      if state.closed then return end
      state.closed = true
      state.cancel()
    end,
  })

  local function request(arguments, callback)
    if state.closed then return end
    if state.busy then status("An operation is running; c cancels it."); return end
    state.busy = true
    state.generation = state.generation + 1
    local generation = state.generation
    status("Running " .. arguments[1] .. "…")

    local handle = client.request(config, arguments, function(value, err)
      if state.closed or generation ~= state.generation then return end
      state.pending, state.busy = nil, false
      if err then failure(err); return end
      callback(value)
    end)

    if state.busy and generation == state.generation then state.pending = handle end
  end

  local function redraw()
    local ok, lines, targets = pcall(render, state.report, state.validations)
    if not ok then failure("Invalid capability report: " .. tostring(lines)); return false end
    state.targets = targets
    state.error = nil
    set_lines(state.buf, lines)
    return true
  end

  function state.refresh()
    request({ "rust-discover", state.manifest, config.store }, function(report)
      local ok, err = pcall(render, report, {})
      if not ok then failure("Invalid capability report: " .. tostring(err)); return end
      if not state.report or state.report.report_id ~= report.report_id then state.validations = {} end
      state.report = report
      redraw()
    end)
  end

  local function selected(opportunity)
    return opportunity or state.targets[vim.api.nvim_win_get_cursor(state.win)[1]]
  end

  function state.navigate(opportunity)
    if state.closed then return end
    opportunity = selected(opportunity)
    if not opportunity then status("Place the cursor on an opportunity first."); return end
    local location = opportunity.consumer_location

    if type(location.path) ~= "string" or location.path:sub(1, 1) ~= "/"
      or type(location.digest) ~= "string" or not location.digest:match("^sha256:%x+$")
      or type(location.line) ~= "number" or location.line < 1 or location.line % 1 ~= 0
      or type(location.column) ~= "number" or location.column < 1 or location.column % 1 ~= 0 then
      failure("Invalid source location in report.")
      return
    end

    if not vim.api.nvim_win_is_valid(state.source_win) then failure("The adjacent source window was closed."); return end
    local previous = vim.api.nvim_win_get_buf(state.source_win)
    local loaded = vim.fn.bufnr(location.path)

    if vim.bo[previous].modified or (loaded >= 0 and vim.bo[loaded].modified) then
      failure("Source buffer has unsaved changes; save or resolve them before navigating.")
      return
    end

    local file = io.open(location.path, "rb")
    if not file then failure("Source is unavailable: " .. location.path); return end
    local bytes = file:read("*a")
    file:close()

    if "sha256:" .. vim.fn.sha256(bytes) ~= location.digest then
      failure("Stale source: bytes changed since discovery. Rediscover before navigating.")
      return
    end

    local buf = vim.fn.bufadd(location.path)
    vim.fn.bufload(buf)
    -- A loaded, unmodified buffer may still contain old bytes after an external edit.
    vim.api.nvim_buf_call(buf, function() vim.cmd("checktime") end)
    vim.api.nvim_win_set_buf(state.source_win, buf)
    vim.api.nvim_win_set_cursor(state.source_win, { math.min(location.line, vim.api.nvim_buf_line_count(buf)), location.column - 1 })
    vim.api.nvim_set_current_win(state.source_win)
    status("Showing source for " .. text(opportunity.title))
  end

  function state.validate(opportunity)
    if state.closed or not state.report then return end
    opportunity = selected(opportunity)

    if not opportunity or type(opportunity.validation) ~= "table"
      or opportunity.validation.kind ~= "plexus_wit_fixture" then
      status("The selected opportunity has no supported validation fixture.")
      return
    end

    local report_id = state.report.report_id

    request({ "rust-validate", report_id, opportunity.id, config.store }, function(value)
      if value.report_id ~= report_id or value.opportunity_id ~= opportunity.id
        or type(value.validation_id) ~= "string"
        or not vim.tbl_contains({ "reproduced_gap", "accepted", "inconclusive" }, value.status) then
        failure("Invalid scoped validation response.")
        return
      end

      state.validations[opportunity.id] = value
      redraw()
      status("Validation recorded; inference status unchanged.")
    end)
  end

  local maps = {
    ["<CR>"] = function() state.navigate() end, p = function() state.validate() end,
    r = state.refresh, c = state.cancel, ["<C-c>"] = state.cancel, q = state.close, ["<Esc>"] = state.close,
  }

  for key, callback in pairs(maps) do
    vim.keymap.set("n", key, callback, { buffer = state.buf, silent = true, nowait = true })
  end

  set_lines(state.buf, { "  PLEXUS · RUST CAPABILITY OPPORTUNITIES", "  c cancel · q close", "  Preparing discovery…" })
  state.refresh()
  return state
end

return M
