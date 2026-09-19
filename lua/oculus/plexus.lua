local M = {}
local client = require("oculus.plexus.client")
local comparison = require("oculus.plexus.comparison")

local function text(value)
  if value == nil or value == vim.NIL then return "—" end
  return tostring(value):gsub("[%c]", " ")
end

local function reference(value)
  if type(value) ~= "table" then return "unresolved" end
  local world = value.world or {}
  return text(world.project) .. "/" .. text(world.world) .. " :: " .. text(value.item)
end

local function lines_for(view)
  assert(type(view.hypothesis_id) == "string", "Missing hypothesis ID")
  assert(type(view.analysis) == "table" and type(view.analysis.subject) == "table", "Missing analysis")
  assert(type(view.bindings) == "table" and type(view.evidence) == "table", "Missing bindings/evidence")

  local lines = {
    "  PLEXUS · " .. text(view.question), "",
    "  Hypothesis: " .. view.hypothesis_id,
    "  Parent: " .. text(view.parent),
    "  Declaration: " .. text(view.analysis.subject.status),
    "  Hypothetical worktree: " .. tostring(view.analysis.hypothetical == true),
    "  Composition execution: " .. text(view.composition_execution),
    "", "  REQUIREMENTS",
  }

  for _, assessment in ipairs(vim.list_extend({ view.analysis.subject }, view.analysis.providers or {})) do
    for _, requirement in ipairs(assessment.requirements or {}) do
      lines[#lines + 1] = "  " .. reference(requirement.evidence)
      lines[#lines + 1] = "    Selected: " .. reference(requirement.selected)

      for _, candidate in ipairs(requirement.candidates or {}) do
        for _, blocker in ipairs(candidate.blockers or {}) do
          lines[#lines + 1] = "    Blocker: " .. text(blocker.kind) .. " · " .. reference(candidate.evidence)
        end
      end
    end
  end

  local targets = {}
  lines[#lines + 1] = ""
  lines[#lines + 1] = "  BINDINGS · place cursor on a binding and press x to run"

  for _, binding in ipairs(view.bindings) do
    local start = #lines + 1
    lines[#lines + 1] = "  " .. text(binding.id) .. " · " .. reference(binding.requirement)
    lines[#lines + 1] = "    Provider: " .. reference(binding.provider) .. " · function: " .. text(binding["function"])
    lines[#lines + 1] = "    Mapping: " .. text(binding.mapping.kind) .. " · " .. text(binding.mapping_check)
    if binding.mapping.description then lines[#lines + 1] = "    " .. text(binding.mapping.description) end
    lines[#lines + 1] = "    Implementation conformance: " .. text(binding.implementation_conformance)
    lines[#lines + 1] = "    Cases obligation: " .. text(binding.cases_obligation)
    lines[#lines + 1] = "    Plan: " .. text(binding.plan)

    if type(binding.runtime) == "table" then
      lines[#lines + 1] = "    Pinned runtime: " .. text(binding.runtime.backend) .. " " .. text(binding.runtime.version)
        .. " · export: " .. text(binding.tested_export)
    end

    lines[#lines + 1] = "    Build: " .. text(binding.build.kind) .. " · " .. text(binding.build.project)
    lines[#lines + 1] = "    Source: " .. text(binding.build.source)
    lines[#lines + 1] = "    Module: " .. text(binding.build.module)

    for _, step in ipairs(binding.relevance_path or {}) do
      lines[#lines + 1] = "    Relevance: " .. reference(step)
    end

    local found = false

    for _, evidence in ipairs(view.evidence) do
      if evidence.attachment.obligation == binding.cases_obligation then
        found = true
        lines[#lines + 1] = "    " .. text(evidence.freshness) .. " · " .. text(evidence.conclusion)
        lines[#lines + 1] = "      Run: " .. text(evidence.attachment.run)

        if evidence.reason ~= vim.NIL and evidence.reason ~= nil then
          lines[#lines + 1] = "      " .. text(evidence.reason)
        end
      end
    end

    if not found then lines[#lines + 1] = "    Cases evidence: unresolved" end
    for row = start, #lines do targets[row] = binding end
    lines[#lines + 1] = ""
  end

  lines[#lines + 1] = "  UNCOVERED REQUIREMENTS"

  for _, requirement in ipairs(view.uncovered_requirements or {}) do
    lines[#lines + 1] = "  " .. reference(requirement.requirement) .. " · " .. text(requirement["function"])
  end

  -- Retain evidence for removed bindings as well as stale evidence on current ones.
  lines[#lines + 1] = ""
  lines[#lines + 1] = "  ALL EVIDENCE (including historical obligations)"

  for _, evidence in ipairs(view.evidence) do
    lines[#lines + 1] = "  " .. text(evidence.attachment.obligation) .. " · " .. text(evidence.freshness)
      .. " · " .. text(evidence.conclusion)

    lines[#lines + 1] = "    " .. text(evidence.attachment.run) .. " · " .. text(evidence.reason)
  end

  lines[#lines + 1] = ""
  lines[#lines + 1] = "  Passing isolated cases does not verify the complete composition."
  lines[#lines + 1] = ""
  lines[#lines + 1] = ""
  lines[#lines + 1] = ""
  return lines, targets
end

local function set_lines(buf, lines)
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
end

local function scratch(filetype)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].filetype = filetype
  vim.bo[buf].swapfile = false
  return buf
end

function M.open(config, manifest, hypothesis_id)
  if M.state and not M.state.closed then M.state.close() end
  config = vim.deepcopy(config or {})
  config.store = vim.fn.fnamemodify(config.store or vim.fn.stdpath("data") .. "/oculus/plexus", ":p")
  local state = { config = config, generation = 0, targets = {} }
  M.state = state
  local receipt_file = vim.fn.stdpath("state") .. "/oculus-plexus/" .. vim.fn.sha256(config.store) .. ".json"
  local width = math.max(20, math.min(vim.o.columns - 4, math.floor(vim.o.columns * 0.92)))
  local height = math.max(6, math.min(vim.o.lines - 4, math.floor(vim.o.lines * 0.82)))
  state.buf = scratch("oculus-plexus")

  state.win = vim.api.nvim_open_win(state.buf, true, {
    relative = "editor", row = 1, col = math.max(0, math.floor((vim.o.columns - width) / 2)),
    width = width, height = height, border = "rounded", style = "minimal",
  })

  vim.wo[state.win].wrap = false
  state.footer_buf = scratch("oculus-plexus")

  state.footer_win = vim.api.nvim_open_win(state.footer_buf, false, {
    relative = "win", win = state.win, row = height - 3, col = 0,
    width = width, height = 3, style = "minimal", focusable = false, zindex = 60,
  })

  local function footer(message)
    if not state.closed and vim.api.nvim_buf_is_valid(state.footer_buf) then
      set_lines(state.footer_buf, {
        "  D discover  m manifest  l load ID  r refresh  R revise",
        "  x run  n Nexus  d compare  J JSON  H history  c cancel  q close",
        "  " .. text(message or ("Backend: " .. (config.backend or "wasmtime"))),
      })
    end
  end

  function state.cancel()
    state.generation = state.generation + 1
    if state.pending then state.pending.cancel() end
    state.pending = nil
    state.busy = false
    footer("Cancelled locally; completed results remain in Plexus history.")
  end

  function state.close()
    if state.closed then return end
    state.cancel()
    state.closed = true

    if state.raw_win and vim.api.nvim_win_is_valid(state.raw_win) then
      vim.api.nvim_win_close(state.raw_win, true)
    end

    for _, win in ipairs({ state.footer_win, state.win }) do
      if vim.api.nvim_win_is_valid(win) then vim.api.nvim_win_close(win, true) end
    end
  end

  vim.api.nvim_create_autocmd("WinClosed", {
    pattern = tostring(state.win), once = true, callback = state.close,
  })

  local function failure(err)
    state.error = tostring(err)
    footer("Error: " .. state.error)
    vim.notify("Oculus Plexus: " .. state.error, vim.log.levels.ERROR)
  end

  local function request(args, callback)
    if state.closed then return end
    if state.busy then footer("An operation is running; c cancels it."); return end
    state.busy = true
    state.generation = state.generation + 1
    local generation = state.generation
    footer("Running " .. args[1] .. "…")

    local handle = client.request(config, args, function(value, err)
      if state.closed or generation ~= state.generation then return end
      state.pending = nil
      state.busy = false
      if err then failure(err); return end
      callback(value)
    end)

    if state.busy and generation == state.generation then state.pending = handle end
  end

  local function accept(view, source_manifest)
    local ok, lines, targets = pcall(lines_for, view)
    if not ok then failure("Invalid hypothesis response: " .. tostring(lines)); return end
    state.view = view
    state.manifest = source_manifest
    state.targets = targets
    state.error = nil
    set_lines(state.buf, lines)
    footer()

    local saved, err = pcall(function()
      vim.fn.mkdir(vim.fn.fnamemodify(receipt_file, ":h"), "p")
      local temporary = receipt_file .. "." .. tostring(vim.uv.os_getpid()) .. ".tmp"
      assert(vim.fn.writefile({ vim.json.encode({ id = view.hypothesis_id, manifest = source_manifest }) }, temporary) == 0)
      assert(vim.uv.fs_rename(temporary, receipt_file))
    end)

    if not saved then failure("View loaded, but could not remember its ID: " .. tostring(err)) end
  end

  function state.load(id, source_manifest)
    request({ "hypothesis", id, config.store }, function(view) accept(view, source_manifest) end)
  end

  function state.prepare(path, revise)
    if type(path) ~= "string" or vim.trim(path) == "" then return end
    path = vim.fn.fnamemodify(path, ":p")
    local args = { "hypothesize", path, config.store }
    if revise and state.view then args = { "revise", state.view.hypothesis_id, path, config.store } end
    request(args, function(view) accept(view, path) end)
  end

  function state.refresh()
    if state.view then state.load(state.view.hypothesis_id, state.manifest) end
  end

  function state.revise()
    if not state.manifest then footer("Use m to select a hypothesis manifest first."); return end
    state.prepare(state.manifest, true)
  end

  function state.run(binding)
    if not state.view then return end
    binding = binding or state.targets[vim.api.nvim_win_get_cursor(state.win)[1]]
    if not binding then footer("Place the cursor on a binding to run its pinned plan."); return end
    local id, path = state.view.hypothesis_id, state.manifest

    request({ "run", binding.plan, config.store }, function(receipt)
      if type(receipt.run_id) ~= "string" then failure("Run response has no run ID"); return end

      request({ "attach", id, binding.cases_obligation, receipt.run_id, config.store }, function(view)
        accept(view, path)
      end)
    end)
  end

  function state.submit(binding)
    if not state.view then return end
    binding = binding or state.targets[vim.api.nvim_win_get_cursor(state.win)[1]]
    if not binding then footer("Place the cursor on a binding to queue its plan in Nexus."); return end

    require("oculus").open_nexus({
      hypothesis_id = state.view.hypothesis_id,
      binding_id = binding.id,
      artifact_store = config.store,
    })
  end

  local function detail(lines, filetype)
    if state.raw_win and vim.api.nvim_win_is_valid(state.raw_win) then
      vim.api.nvim_win_close(state.raw_win, true)
    end

    local buf = scratch(filetype)

    state.raw_win = vim.api.nvim_open_win(buf, true, {
      relative = "win", win = state.win, row = 1, col = 1, width = width - 2,
      height = height - 2, border = "rounded", style = "minimal", zindex = 70,
    })

    vim.wo[state.raw_win].wrap = true
    set_lines(buf, lines)
    vim.keymap.set("n", "q", "<cmd>close<cr>", { buffer = buf, silent = true })
    return buf
  end

  local function raw(value)
    detail({ vim.json.encode(value) }, "json")
  end

  function state.compare(left, right)
    if not comparison.is_artifact(left) or not comparison.is_artifact(right) then
      failure("Comparison requires two sha256 run artifact IDs from this store")
      return
    end

    request({ "compare-runs", left, right, config.store }, function(report)
      local ok, lines = pcall(comparison.lines, report, left, right)
      if not ok then failure("Invalid comparison response: " .. tostring(lines)); return end
      state.comparison = report
      state.error = nil
      local buf = detail(lines, "oculus-plexus-comparison")
      vim.keymap.set("n", "J", function() raw(report) end, { buffer = buf, silent = true })
      footer("Comparison: " .. report.status .. " · investigation and attached evidence preserved")
    end)
  end

  local function prompt(options, callback)
    local generation = state.generation

    vim.ui.input(options, function(value)
      if not state.closed and generation == state.generation and value and value ~= "" then callback(value) end
    end)
  end

  local maps = {
    q = state.close, ["<Esc>"] = state.close, c = state.cancel, ["<C-c>"] = state.cancel,
    r = state.refresh, R = state.revise, x = function() state.run() end,
    n = function() state.submit() end,
    d = function()
      local latest

      for _, evidence in ipairs(state.view and state.view.evidence or {}) do
        local run = type(evidence.attachment) == "table" and evidence.attachment.run
        if comparison.is_artifact(run) then latest = run end
      end

      prompt({ prompt = "Left run artifact ID: ", default = latest }, function(left)
        prompt({ prompt = "Right run artifact ID: " }, function(right) state.compare(vim.trim(left), vim.trim(right)) end)
      end)
    end,
    D = function()
      prompt({ prompt = "Rust discovery manifest: ", completion = "file" }, function(path)
        require("oculus").open_capabilities(path)
      end)
    end,
    m = function() prompt({ prompt = "Hypothesis manifest: ", completion = "file" }, function(path) state.prepare(path, false) end) end,
    l = function() prompt({ prompt = "Hypothesis artifact ID: " }, state.load) end,
    J = function() if state.view then raw(state.view) end end,
    H = function() request({ "history", config.store }, raw) end,
  }

  for key, callback in pairs(maps) do
    vim.keymap.set("n", key, callback, { buffer = state.buf, silent = true, nowait = true })
  end

  set_lines(state.buf, { "  PLEXUS", "", "  m: open a hypothesis manifest · l: load an existing hypothesis ID", "", "  Experiments run only when you press x on a binding." })
  footer()

  if hypothesis_id then
    state.load(hypothesis_id)
  elseif manifest and manifest ~= "" then
    state.prepare(manifest, false)
  elseif vim.fn.filereadable(receipt_file) == 1 then
    local ok, saved = pcall(function() return vim.json.decode(table.concat(vim.fn.readfile(receipt_file), "\n")) end)

    if ok and type(saved) == "table" and type(saved.id) == "string" then
      state.load(saved.id, type(saved.manifest) == "string" and saved.manifest or nil)
    end
  end

  return state
end

return M
