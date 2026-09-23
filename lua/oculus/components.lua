local M = {}
local client = require("oculus.plexus.client")

local function text(value)
  if value == nil or value == vim.NIL then return "—" end
  if type(value) == "table" then return vim.json.encode(value) end
  return tostring(value):gsub("[%c]", " ")
end

local function set_lines(buf, lines)
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
end

local function validate_run(value)
  assert(type(value.run_id) == "string" and type(value.record) == "table", "Missing component run")
  assert(type(value.record.cases) == "table" and type(value.record.runtime) == "table", "Missing component evidence")
end

function M.open(config, nexus_config, options)
  if M.state and not M.state.closed then M.state.close() end
  config, options = vim.deepcopy(config or {}), options or {}
  config.store = vim.fn.fnamemodify(config.store or vim.fn.stdpath("data") .. "/oculus/plexus", ":p")
  local state = { config = config, generation = 0, targets = {} }
  M.state = state
  vim.cmd("botright vnew")
  state.win, state.buf = vim.api.nvim_get_current_win(), vim.api.nvim_get_current_buf()
  vim.bo[state.buf].buftype, vim.bo[state.buf].bufhidden = "nofile", "wipe"
  vim.bo[state.buf].swapfile, vim.bo[state.buf].filetype = false, "oculus-component"
  vim.wo[state.win].wrap, vim.wo[state.win].number, vim.wo[state.win].relativenumber = true, false, false

  local function header(title)
    return { "  PLEXUS · " .. title, "  n queue · h history · Enter source/reopen · d compare · r reload · q close", "  Ready", "" }
  end

  local function status(message)
    if state.closed or not vim.api.nvim_buf_is_valid(state.buf) then return end
    vim.bo[state.buf].modifiable = true
    vim.api.nvim_buf_set_lines(state.buf, 2, 3, false, { "  " .. text(message) })
    vim.bo[state.buf].modifiable = false
  end

  function state.close()
    if state.closed then return end
    state.closed, state.generation = true, state.generation + 1
    if state.pending then state.pending.cancel() end
    if vim.api.nvim_win_is_valid(state.win) then pcall(vim.api.nvim_win_close, state.win, true) end
  end

  vim.api.nvim_create_autocmd("WinClosed", { pattern = tostring(state.win), once = true, callback = state.close })
  vim.api.nvim_create_autocmd("BufWipeout", { buffer = state.buf, once = true, callback = state.close })

  local function request(args, callback)
    if state.closed or state.busy then return end
    state.busy, state.error = true, nil
    state.generation = state.generation + 1
    local generation = state.generation
    status("Loading " .. args[1] .. "…")

    local handle = client.request(config, args, function(value, err)
      if state.closed or generation ~= state.generation then return end
      state.pending, state.busy = nil, false
      local ok, reason = false, err
      if not err then ok, reason = pcall(callback, value) end

      if not ok then
        state.error = tostring(reason)
        status("Error: " .. state.error)
        vim.notify("Oculus component: " .. state.error, vim.log.levels.WARN)
      end
    end)

    if state.busy and generation == state.generation then state.pending = handle end
  end

  local function identity(lines, value, targets)
    lines[#lines + 1] = "  Profile: " .. text(value.profile) .. " · export: " .. text(value.export or "checksum")
    lines[#lines + 1] = "  Runtime identity: " .. text(value.runtime)
    lines[#lines + 1] = "  Archived component: " .. text(value.component)
    lines[#lines + 1] = "  Archived source: " .. text(value.source)
    targets[#lines] = { artifact = value.source, path = "component.wat" }
    lines[#lines + 1] = "  Archived WIT: " .. text(value.wit)
    targets[#lines] = { artifact = value.wit, path = "component.wit" }
  end

  local function render_plan(view)
    assert(view.kind == "component_reference" and type(view.plan_id) == "string", "Missing component plan identity")
    assert(type(view.cases) == "table" and type(view.limits) == "table" and type(view.properties) == "table", "Missing component plan inputs")
    local lines, targets = header("COMPONENT EXPERIMENT · review before queuing"), {}
    lines[#lines + 1] = "  Plan: " .. view.plan_id
    identity(lines, view, targets)
    lines[#lines + 1] = "  Limits: " .. text(view.limits) .. " · memories: " .. text(view.memory_count)
    lines[#lines + 1] = "  Execution properties: " .. text(view.properties)
    lines[#lines + 1] = ""
    lines[#lines + 1] = "  TYPED CASES"

    for _, case in ipairs(view.cases) do
      lines[#lines + 1] = "  " .. text(case.name) .. " · input: " .. text(case.value)
      lines[#lines + 1] = "    Expected: " .. text(case.expected)
    end

    lines[#lines + 1] = ""
    lines[#lines + 1] = "  EVIDENCE SCOPE"
    lines[#lines + 1] = "  " .. text(view.scope)
    for _, blocker in ipairs(view.blockers or {}) do lines[#lines + 1] = "  Blocker: " .. text(blocker) end
    lines[#lines + 1] = "  Preparing and queuing do not execute cases. Nexus owns execution."
    state.view, state.targets, state.mode = view, targets, "plan"
    set_lines(state.buf, lines)
  end

  local function render_run(view)
    validate_run(view)
    local record = view.record
    local lines, targets = header("COMPONENT CASE EVIDENCE"), {}
    lines[#lines + 1] = "  Run: " .. view.run_id
    lines[#lines + 1] = "  Plan: " .. text(record.plan)
    if type(record.plan) == "string" then targets[#lines] = { plan_id = record.plan } end
    lines[#lines + 1] = "  Case conclusion: " .. text(record.conclusion)
    identity(lines, record, targets)
    lines[#lines + 1] = "  Fuel/case: " .. text(record.fuel_per_case) .. " · memory bytes: " .. text(record.memory_bytes)
    lines[#lines + 1] = "  Host grants: " .. text(record.host_grants) .. " · trace: " .. text(record.host_trace)

    for _, result in ipairs(record.cases) do
      lines[#lines + 1] = ""
      lines[#lines + 1] = "  " .. text(result.case.name) .. " · input: " .. text(result.case.value)
      lines[#lines + 1] = "    Expected: " .. text(result.case.expected)
      lines[#lines + 1] = "    Observed: " .. text(result.outcome.value) .. " · outcome: " .. text(result.outcome.status)
      if result.outcome.status == "failed" then lines[#lines + 1] = "    " .. text(result.outcome.stage) .. ": " .. text(result.outcome.message) end
    end

    lines[#lines + 1] = ""
    lines[#lines + 1] = "  EVIDENCE SCOPE"
    lines[#lines + 1] = "  " .. text(record.scope)
    state.run, state.targets, state.mode = view, targets, "run"
    set_lines(state.buf, lines)
  end

  function state.load_plan(id)
    request({ "describe-component-plan", id, config.store }, render_plan)
  end

  function state.load_run(id)
    request({ "component-checksum-run", id, config.store }, render_run)
  end

  function state.prepare(source, cases)
    local args = { "component-plan", vim.fn.fnamemodify(source, ":p"), vim.fn.fnamemodify(cases, ":p"), config.store }
    if config.component_export then vim.list_extend(args, { "--component-export", config.component_export }) end
    request(args, render_plan)
  end

  function state.submit()
    if state.closed or state.busy then return end
    if state.mode ~= "plan" or not state.view then status("Open an archived plan before queuing it."); return end
    if #(state.view.blockers or {}) > 0 then status("Resolve the component blockers before queuing it."); return end
    local submission = { kind = "component_reference", plan_id = state.view.plan_id, artifact_store = config.store }
    state.close()
    require("oculus.nexus").open(nexus_config, config, submission)
  end

  function state.history()
    request({ "component-history", config.store }, function(value)
      assert(type(value.plans) == "table" and type(value.runs) == "table", "Missing component history")
      local lines, targets = header("COMPONENT HISTORY"), {}
      lines[#lines + 1] = "  ARCHIVED PLANS"

      for _, plan in ipairs(value.plans) do
        lines[#lines + 1] = "  " .. text(plan.plan_id) .. " · " .. text(plan.export) .. " · " .. text(plan.runtime.backend)
        targets[#lines] = { plan_id = plan.plan_id }
      end

      lines[#lines + 1] = ""
      lines[#lines + 1] = "  ARCHIVED RUNS"

      for _, run in ipairs(value.runs) do
        validate_run(run)
        lines[#lines + 1] = "  " .. run.run_id .. " · " .. text(run.record.runtime.backend) .. " · " .. text(run.record.conclusion)
        targets[#lines] = run
      end

      lines[#lines + 1] = ""
      lines[#lines + 1] = "  ARCHIVED COMPARISONS"

      for _, comparison in ipairs(value.comparisons or {}) do
        lines[#lines + 1] = "  " .. text(comparison.comparison_id) .. " · runtime agreement: " .. text(comparison.record.conclusion)
        targets[#lines] = { comparison_id = comparison.comparison_id }
      end

      if #value.plans == 0 and #value.runs == 0 then lines[#lines + 1] = "  No experiments. Use :OculusComponent component.wat cases.json to prepare one." end
      state.history_value, state.targets, state.mode = value, targets, "history"
      set_lines(state.buf, lines)
    end)
  end

  function state.navigate()
    local target = state.targets[vim.api.nvim_win_get_cursor(state.win)[1]]
    if not target then return end
    if target.run_id then state.load_run(target.run_id); return end
    if target.comparison_id then state.load_comparison(target.comparison_id); return end
    if target.plan_id then state.load_plan(target.plan_id); return end
    if type(target.artifact) ~= "string" then return end

    request({ "investigation-source", target.artifact, config.store }, function(value)
      assert(type(value.content) == "string" and "sha256:" .. vim.fn.sha256(value.content) == target.artifact, "Archived source digest mismatch")
      vim.api.nvim_set_current_win(state.win)
      vim.cmd("leftabove vnew")
      local buf = vim.api.nvim_get_current_buf()
      vim.bo[buf].buftype, vim.bo[buf].bufhidden = "nofile", "wipe"
      vim.bo[buf].swapfile, vim.bo[buf].filetype = false, vim.filetype.match({ filename = target.path }) or ""
      set_lines(buf, vim.split(value.content, "\n", { plain = true }))
      vim.bo[buf].readonly = true
      vim.b[buf].oculus_archived_source = target.artifact
      status("Showing digest-verified archived " .. target.path)
    end)
  end

  local function accept_comparison(value)
    assert(type(value.comparison_id) == "string" and type(value.record) == "table", "Missing component comparison")
    local record = value.record

    request({ "component-checksum-run", record.left_run, config.store }, function(left)
      validate_run(left)

      request({ "component-checksum-run", record.right_run, config.store }, function(right)
        validate_run(right)
        local lines, targets = header("COMPONENT DIFFERENTIAL EVIDENCE"), {}
        lines[#lines + 1] = "  Comparison: " .. value.comparison_id
        lines[#lines + 1] = "  Runtime agreement: " .. text(record.conclusion)
        lines[#lines + 1] = "  Left case conclusion: " .. text(left.record.conclusion) .. " · " .. text(left.record.runtime.backend)
        targets[#lines] = left
        lines[#lines + 1] = "  Right case conclusion: " .. text(right.record.conclusion) .. " · " .. text(right.record.runtime.backend)
        targets[#lines] = right

        for index, verdict in ipairs(record.cases) do
          local a, b = left.record.cases[index], right.record.cases[index]
          lines[#lines + 1] = ""
          lines[#lines + 1] = "  " .. text(a.case.name) .. " · runtime comparison: " .. text(verdict)
          lines[#lines + 1] = "    Expected: " .. text(a.case.expected)
          lines[#lines + 1] = "    Left outcome: " .. text(a.outcome)
          lines[#lines + 1] = "    Right outcome: " .. text(b.outcome)
        end

        lines[#lines + 1] = ""
        lines[#lines + 1] = "  " .. text(record.scope)
        lines[#lines + 1] = "  Runtime agreement does not establish expected behavior or general Component Model conformance."
        state.comparison, state.targets, state.mode = value, targets, "comparison"
        set_lines(state.buf, lines)
      end)
    end)
  end

  function state.load_comparison(id)
    request({ "component-checksum-comparison", id, config.store }, accept_comparison)
  end

  function state.compare(left, right)
    if not left then
      local selected = state.mode == "run" and state.run or state.targets[vim.api.nvim_win_get_cursor(state.win)[1]]
      if not selected or not selected.run_id then status("Open or select an archived run first."); return end

      vim.ui.input({ prompt = "Compare with archived run ID: " }, function(id)
        if id and vim.trim(id) ~= "" then state.compare(selected.run_id, vim.trim(id)) end
      end)

      return
    end

    request({ "component-checksum-compare", left, right, config.store }, accept_comparison)
  end

  function state.reload()
    if state.mode == "plan" then state.load_plan(state.view.plan_id)
    elseif state.mode == "run" then state.load_run(state.run.run_id)
    elseif state.mode == "comparison" then state.load_comparison(state.comparison.comparison_id)
    else state.history() end
  end

  local maps = { q = state.close, ["<Esc>"] = state.close, n = state.submit, h = state.history,
    ["<CR>"] = state.navigate, d = function() state.compare() end, r = state.reload }

  for key, callback in pairs(maps) do vim.keymap.set("n", key, callback, { buffer = state.buf, silent = true, nowait = true }) end
  set_lines(state.buf, header("COMPONENT EXPERIMENT"))

  if options.plan_id then state.load_plan(options.plan_id)
  elseif options.run_id then state.load_run(options.run_id)
  elseif options.comparison_id then state.load_comparison(options.comparison_id)
  elseif options.source and options.cases then state.prepare(options.source, options.cases)
  else state.history() end

  return state
end

return M
