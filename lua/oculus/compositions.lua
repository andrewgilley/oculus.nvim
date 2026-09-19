local M = {}
local client = require("oculus.plexus.client")
local comparison = require("oculus.plexus.comparison")

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

function M.open(config, nexus_config, input, options)
  if M.state and not M.state.closed then M.state.close() end
  config, options = vim.deepcopy(config or {}), options or {}
  config.store = vim.fn.fnamemodify(config.store or vim.fn.stdpath("data") .. "/oculus/plexus", ":p")
  local state = { config = config, options = options, generation = 0, targets = {}, runs = {} }
  M.state = state
  vim.cmd("botright vnew")
  state.win, state.buf = vim.api.nvim_get_current_win(), vim.api.nvim_get_current_buf()
  vim.bo[state.buf].buftype, vim.bo[state.buf].bufhidden = "nofile", "wipe"
  vim.bo[state.buf].swapfile, vim.bo[state.buf].filetype = false, "oculus-composition"
  vim.wo[state.win].wrap, vim.wo[state.win].number, vim.wo[state.win].relativenumber = true, false, false
  local receipt_file = vim.fn.stdpath("state") .. "/oculus-composition/" .. vim.fn.sha256(config.store) .. ".json"

  local function header(title)
    return { "  PLEXUS · " .. title, "  n queue · h history · Enter source/reopen · d compare · r reload · m manifest · q close", "  Ready", "" }
  end

  local function status(message)
    if state.closed or not vim.api.nvim_buf_is_valid(state.buf) then return end
    vim.bo[state.buf].modifiable = true
    vim.api.nvim_buf_set_lines(state.buf, 2, 3, false, { "  " .. text(message) })
    vim.bo[state.buf].modifiable = false
  end

  function state.close()
    if state.closed then return end
    state.closed = true
    state.generation = state.generation + 1
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
        vim.notify("Oculus composition: " .. state.error, vim.log.levels.WARN)
      end
    end)

    if state.busy and generation == state.generation then state.pending = handle end
  end

  local function render()
    local view = state.view
    local native = state.native
    local rust = view.native_kind == "rust_call_site_adaptation"
    local plan = native and view.composition or view.plan
    local runtime = native and view.runtime or plan.runtime
    local title = rust and "RUST CALL-SITE ADAPTATION" or native and "C/ZIG COMPOSITION" or "LINKED COMPOSITION"
    local lines, targets = header(title), {}
    lines[#lines + 1] = "  " .. text(view.question or "Developer-selected native experiment")
    lines[#lines + 1] = "  Plan: " .. view.plan_id
    lines[#lines + 1] = "  Runtime: " .. text(runtime.backend) .. " " .. text(runtime.version)
    lines[#lines + 1] = "  Runtime identity: " .. text(runtime)
    if native then lines[#lines + 1] = "  Toolchain: " .. text(plan.toolchain) end
    if not native then lines[#lines + 1] = "  Entry: " .. text(view.entry.part) .. " :: " .. text(view.entry.export) end
    lines[#lines + 1] = ""
    lines[#lines + 1] = "  PARTS"

    for _, part in ipairs(plan.parts) do
      lines[#lines + 1] = "  " .. text(part.name) .. " · " .. text(part.role) .. " · " .. text(part.project)
      if part.revision then lines[#lines + 1] = "    Revision: " .. text(part.revision) end
      if part.module then lines[#lines + 1] = "    Module: " .. text(part.module) .. " · source: " .. text(part.source) end
      if part.package then lines[#lines + 1] = "    Package: " .. text(part.package) .. " · " .. text(part.manifest or part.directory) end

      for _, file in ipairs(part.files or {}) do
        lines[#lines + 1] = "    " .. text(file.path) .. " · " .. text(file.artifact)
        targets[#lines] = { artifact = file.artifact, path = file.path }
      end
    end

    lines[#lines + 1] = ""
    lines[#lines + 1] = "  CONNECTIONS"

    for _, link in ipairs(plan.connections) do
      if rust then
        lines[#lines + 1] = "  " .. text(link.importer) .. " calls " .. text(link.previous) .. " → " .. text(link.replacement)
          .. " through " .. text(link.alias)
      elseif native then
        lines[#lines + 1] = "  " .. text(link.symbol) .. " · " .. text(link.kind) .. " · " .. text(link.signature)
      else
        lines[#lines + 1] = "  " .. text(link.importer) .. " → " .. text(link.module) .. " :: " .. text(link.name) .. " · " .. text(link.status)
        lines[#lines + 1] = "    Expected: " .. text(link.expected) .. " · provided: " .. text(link.provided)
        if type(link.reason) == "string" then lines[#lines + 1] = "    " .. text(link.reason) end
      end
    end

    if rust and type(plan.adaptation) == "table" then
      local patch = { artifact = plan.adaptation.patch, path = plan.adaptation.path .. ".diff" }
      lines[#lines + 1] = "  Proposed patch: " .. text(plan.adaptation.path) .. " · " .. text(plan.adaptation.patch)
      targets[#lines] = patch
      lines[#lines + 1] = "    Enter opens the archived patch for review before queuing; the worktree is never changed."
      targets[#lines] = patch

      for _, edit in ipairs(plan.adaptation.edits or {}) do
        lines[#lines + 1] = "    " .. text(edit.line) .. ":" .. text(edit.column) .. " " .. text(edit.original)
          .. " → " .. (edit.replacement == "" and "(removed)" or text(edit.replacement))

        lines[#lines + 1] = "      " .. text(edit.reason)
      end
    elseif type(plan.adaptation) == "table" then
      lines[#lines + 1] = "  Proposed adapter: " .. text(plan.adaptation.path) .. " · " .. text(plan.adaptation.artifact)
      targets[#lines] = { artifact = plan.adaptation.artifact, path = plan.adaptation.path }
      lines[#lines + 1] = "    Enter opens the archived adapter for review before queuing."
      targets[#lines] = targets[#lines - 1]
    end

    lines[#lines + 1] = ""
    lines[#lines + 1] = "  PLANNED CASES"

    for _, case in ipairs(rust and plan.cases or {}) do
      lines[#lines + 1] = "  " .. text(case) .. " · consumer test, before and after the change"
    end

    for _, case in ipairs(not rust and (native and plan.cases or view.cases) or {}) do
      lines[#lines + 1] = "  " .. text(case.name) .. " · arguments: " .. text(case.arguments)

      lines[#lines + 1] = native and ("    Expected stdout: " .. text(case.expected_stdout) .. " · exit: " .. text(case.expected_exit))
        or ("    Expected: " .. text(case.expected))

      if type(case.memory) == "table" then lines[#lines + 1] = "    Memory input: " .. text(case.memory) end
    end

    lines[#lines + 1] = ""
    lines[#lines + 1] = "  OBLIGATIONS AND SCOPE"
    if view.link then lines[#lines + 1] = "  Declared links: " .. text(view.link.status) end
    for _, obligation in ipairs(plan.obligations or {}) do lines[#lines + 1] = "  " .. text(obligation) end
    for _, limitation in ipairs(plan.limitations or {}) do lines[#lines + 1] = "  " .. text(limitation) end

    if native then
      lines[#lines + 1] = rust and "  Execution: trusted local consumer and producer builds with the proposed patch."
        or "  Execution: trusted local native sources and proposed adapter."
    end

    for _, blocker in ipairs(view.blockers or {}) do lines[#lines + 1] = "  Blocker: " .. text(blocker) end
    lines[#lines + 1] = "  Evidence applies to the pinned parts and selected cases. General behavior remains unverified."
    lines[#lines + 1] = ""
    lines[#lines + 1] = "  EXECUTION ATTEMPTS"

    for _, run in ipairs(state.runs) do
      if run.record.plan == view.plan_id then
        local start = #lines + 1
        lines[#lines + 1] = "  " .. text(run.run_id) .. " · " .. text(run.record.conclusion)
        lines[#lines + 1] = "    Runtime links: " .. text(run.record.link.status)
        if type(run.record.execution_error) == "string" then lines[#lines + 1] = "    Error: " .. text(run.record.execution_error) end
        for _, blocker in ipairs(run.record.blockers or {}) do lines[#lines + 1] = "    Blocker: " .. text(blocker) end

        for _, case in ipairs(run.record.cases) do
          lines[#lines + 1] = "    " .. text(case.observation.name) .. " · " .. text(case.verdict)
          lines[#lines + 1] = "      Expected: " .. text(case.expected) .. " · observed: " .. text(case.observation.outcome)
        end

        for row = start, #lines do targets[row] = run end
      end
    end

    if native then lines[#lines + 1] = "  Native attempts return to the originating investigation through Nexus (o)." end
    state.targets, state.mode = targets, "plan"
    set_lines(state.buf, lines)
  end

  local function accept(view, check_selection)
    assert(type(view.plan_id) == "string", "Missing composition plan identity")
    local native = view.native_kind == "c_zig_composition" or view.native_kind == "rust_call_site_adaptation"
    local plan = native and view.composition or view.plan
    assert(type(plan) == "table" and type(plan.parts) == "table" and type(plan.connections) == "table", "Missing composition parts or connections")

    for _, key in ipairs({ "investigation_id", "opportunity_id" }) do
      assert(not check_selection or not options[key] or view[key] == options[key], "Composition request refers to a different " .. key)
    end

    state.view, state.native = view, native
    render()
    vim.fn.mkdir(vim.fn.fnamemodify(receipt_file, ":h"), "p")
    assert(vim.fn.writefile({ vim.json.encode({ plan_id = view.plan_id, native = native }) }, receipt_file) == 0)

    if not native then
      request({ "composition-runs", config.store }, function(value)
        assert(type(value.runs) == "table", "Missing composition history")
        state.runs = value.runs
        render()
      end)
    end
  end

  function state.load(id, native)
    request({ native and "describe-investigation-plan" or "composition", id, config.store }, accept)
  end

  function state.prepare(path)
    if type(path) ~= "string" or vim.trim(path) == "" then return end
    local native = options.native
    if state.view then native = state.native end
    local command = not native and "compose" or options.kind == "rust" and "rust-adapt" or "c-zig-compose"
    request({ command, vim.fn.fnamemodify(path, ":p"), config.store }, function(view) accept(view, native) end)
  end

  function state.submit()
    if not state.view or state.busy then return end
    if state.mode ~= "plan" then status("Open a composition before queuing it."); return end
    if #(state.view.blockers or {}) > 0 then status("Resolve the composition blockers before queuing it."); return end
    local submission = { kind = state.native and "investigation_plan" or "composition", plan_id = state.view.plan_id, artifact_store = config.store }
    state.close()
    require("oculus.nexus").open(nexus_config, config, submission)
  end

  function state.history()
    request({ "composition-runs", config.store }, function(value)
      assert(type(value.runs) == "table", "Missing composition history")
      local lines, targets = header("COMPOSITION HISTORY"), {}
      state.runs = value.runs

      for _, run in ipairs(value.runs) do
        lines[#lines + 1] = "  " .. text(run.record.question) .. " · " .. text(run.record.runtime.backend) .. " · " .. text(run.record.conclusion)
        targets[#lines] = run
        lines[#lines + 1] = "    " .. text(run.run_id) .. " · plan: " .. text(run.record.plan)
        targets[#lines] = run
      end

      if #value.runs == 0 then lines[#lines + 1] = "  No executed compositions. Use m to prepare a manifest." end
      state.targets, state.mode = targets, "history"
      set_lines(state.buf, lines)
    end)
  end

  function state.navigate()
    local target = state.targets[vim.api.nvim_win_get_cursor(state.win)[1]]
    if not target then return end
    if target.record then state.load(target.record.plan, false); return end
    if type(target.artifact) ~= "string" then status("No archived source is available."); return end

    request({ "investigation-source", target.artifact, config.store }, function(value)
      assert(type(value.content) == "string" and "sha256:" .. vim.fn.sha256(value.content) == target.artifact, "Archived source digest mismatch")
      vim.api.nvim_set_current_win(state.win)
      vim.cmd("leftabove vnew")
      local buf = vim.api.nvim_get_current_buf()
      vim.bo[buf].buftype, vim.bo[buf].bufhidden = "nofile", "wipe"
      vim.bo[buf].swapfile = false
      vim.bo[buf].filetype = vim.filetype.match({ filename = target.path }) or ""
      set_lines(buf, vim.split(value.content, "\n", { plain = true }))
      vim.bo[buf].readonly = true
      vim.b[buf].oculus_archived_source = target.artifact
      status("Showing digest-verified archived source: " .. text(target.path))
    end)
  end

  function state.compare(left, right)
    if not left then
      local run = state.targets[vim.api.nvim_win_get_cursor(state.win)[1]]
      if not run or not run.record then status("Place the cursor on an execution attempt."); return end

      vim.ui.input({ prompt = "Compare with archived run ID: " }, function(id)
        if id and vim.trim(id) ~= "" then state.compare(run.run_id, vim.trim(id)) end
      end)

      return
    end

    request({ "compare-runs", left, right, config.store }, function(value)
      local lines = comparison.lines(value, left, right)
      lines[#lines] = "  r returns to the composition · h history · q close"
      set_lines(state.buf, lines)
      state.targets, state.mode = {}, "comparison"
    end)
  end

  local maps = {
    q = state.close, ["<Esc>"] = state.close, n = state.submit, h = state.history,
    ["<CR>"] = state.navigate, d = function() state.compare() end,
    r = function() if state.view then state.load(state.view.plan_id, state.native) else state.history() end end,
    m = function() vim.ui.input({ prompt = "Composition manifest: ", completion = "file" }, state.prepare) end,
  }

  for key, callback in pairs(maps) do vim.keymap.set("n", key, callback, { buffer = state.buf, silent = true, nowait = true }) end
  set_lines(state.buf, header("COMPOSITION"))

  if input then
    if input:match("^sha256:") then state.load(input, options.native) else state.prepare(input) end
  elseif vim.fn.filereadable(receipt_file) == 1 then
    local ok, saved = pcall(vim.json.decode, table.concat(vim.fn.readfile(receipt_file), "\n"))
    if ok and type(saved) == "table" and type(saved.plan_id) == "string" then state.load(saved.plan_id, saved.native) else state.history() end
  else
    state.history()
  end

  return state
end

return M
