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

local function valid_view(value)
  assert(type(value) == "table" and value.schema_version == 1 and value.kind == "selected_change", "Invalid investigation")
  assert(type(value.investigation_id) == "string" and type(value.observation) == "table", "Missing investigation identity")
  assert(vim.tbl_contains({ "completed", "unsupported", "failed" }, value.status), "Invalid investigation status")

  for _, key in ipairs({ "reports", "limitations", "experiments", "evidence" }) do
    assert(type(value[key]) == "table" and vim.islist(value[key]), "Missing investigation " .. key)
  end

  if value.reasoning ~= nil and value.reasoning ~= vim.NIL then
    assert(type(value.reasoning) == "table" and value.reasoning.schema_version == 1, "Invalid investigation reasoning")

    for _, key in ipairs({ "claims", "relations", "obligations" }) do
      assert(type(value.reasoning[key]) == "table" and vim.islist(value.reasoning[key]), "Missing reasoning " .. key)
    end
  end
end

-- Both the catalog and details are projections of durable engine records.
function M.open(config, nexus_config, id, submission)
  if M.state and not M.state.closed then M.state.close() end
  config = vim.deepcopy(config or {})
  config.store = vim.fn.fnamemodify(config.store or vim.fn.stdpath("data") .. "/oculus/plexus", ":p")
  local state = { config = config, generation = 0, targets = {}, source_win = vim.api.nvim_get_current_win(), decisions = {} }
  M.state = state
  vim.cmd("botright vnew")
  state.win, state.buf = vim.api.nvim_get_current_win(), vim.api.nvim_get_current_buf()
  vim.bo[state.buf].buftype, vim.bo[state.buf].bufhidden = "nofile", "wipe"
  vim.bo[state.buf].swapfile, vim.bo[state.buf].filetype = false, "oculus-investigations"
  vim.wo[state.win].wrap, vim.wo[state.win].number, vim.wo[state.win].relativenumber = true, false, false

  local function status(message)
    if state.closed or not vim.api.nvim_buf_is_valid(state.buf) then return end
    vim.bo[state.buf].modifiable = true
    vim.api.nvim_buf_set_lines(state.buf, 2, 3, false, { "  " .. text(message) })
    vim.bo[state.buf].modifiable = false
  end

  local function failure(message)
    state.error = tostring(message)
    status("Error: " .. state.error)
    vim.notify("Oculus investigations: " .. state.error, vim.log.levels.WARN)
  end

  function state.cancel()
    state.generation = state.generation + 1
    if state.pending then state.pending.cancel() end
    state.pending, state.busy = nil, false
    status("Stopped waiting; previously stored investigations remain in the catalog.")
  end

  function state.close()
    if state.closed then return end
    state.cancel()
    state.closed = true

    if vim.api.nvim_win_is_valid(state.win) then
      if not pcall(vim.api.nvim_win_close, state.win, true) then
        vim.api.nvim_win_set_buf(state.win, vim.api.nvim_create_buf(true, false))
      end
    end
  end

  vim.api.nvim_create_autocmd("WinClosed", { pattern = tostring(state.win), once = true, callback = state.close })
  vim.api.nvim_create_autocmd("BufWipeout", { buffer = state.buf, once = true, callback = state.close })

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

  local function header(title)
    return {
      "  PLEXUS · " .. title,
      "  Enter source · h promote · s select · d defer · x dismiss · n queue · p compose · r reload · q close",
      "  Ready",
      "",
    }
  end

  local function obligation_resolution(obligation)
    if type(obligation) ~= "table" then return nil end
    if type(obligation.resolving_evidence) == "string" and obligation.resolving_evidence ~= "" then
      return obligation.resolving_evidence
    end
    if type(obligation.resolution) == "string" and obligation.resolution ~= "" then
      return obligation.resolution
    end

    local kind = obligation.kind or ""
    local label = obligation.label or ""

    if kind == "signature" or kind == "replacement_signature" then
      return "compiler verification of matching callable signature"
    elseif kind == "normalizer_fixture" then
      return "fixture execution against the captured normalizer"
    elseif kind == "consumer_integration" then
      return "adapted consumer build and link against provider head"
    elseif kind == "behavior" or kind == "behavioral_equivalence" then
      return "passing behavioral test cases across consumer call sites"
    elseif kind == "runtime_behavior" then
      return "runtime execution trace or differential test run"
    elseif kind == "wrapper_implementation" or kind == "implementation" then
      return "concrete C ABI wrapper implementation"
    elseif kind == "native_link" then
      return "successful native C/Zig link without unresolved symbols"
    elseif kind == "native_cases" or kind == "cases" then
      return "passing execution cases with matching exit code and output"
    elseif kind == "composition_execution" then
      return "conforming component instantiation and value agreement across runtimes"
    elseif kind == "adapted_build" then
      return "consumer build passing against the adapted call sites"
    elseif kind == "consumer_tests" then
      return "passing consumer test suite on adapted calls"
    elseif kind ~= "" then
      return kind:gsub("_", " ") .. " evidence or test verification"
    elseif label ~= "" then
      return "evidence verifying " .. label:lower()
    end
    return "reproducible evidence verifying this obligation"
  end

  local function decisions_file(investigation_id)
    if not investigation_id or type(investigation_id) ~= "string" then return nil end
    local base = config.decisions_dir or (config.store and (config.store .. "/decisions")) or (vim.fn.stdpath("state") .. "/oculus-decisions")
    pcall(vim.fn.mkdir, base, "p")
    local safe_id = investigation_id:gsub("[^%w_-]", "_")
    return base .. "/" .. safe_id .. ".json"
  end

  function state.load_decisions(investigation_id)
    state.decisions = state.decisions or {}
    if not investigation_id then return end
    local file = decisions_file(investigation_id)
    if file and vim.fn.filereadable(file) == 1 then
      local ok, lines = pcall(vim.fn.readfile, file)
      if ok and lines and #lines > 0 then
        local ok_json, data = pcall(vim.json.decode, table.concat(lines, "\n"))
        if ok_json and type(data) == "table" then
          for k, v in pairs(data) do
            state.decisions[k] = state.decisions[k] or v
          end
        end
      end
    end
    if type(config.investigation_decisions) == "table" and type(config.investigation_decisions[investigation_id]) == "table" then
      for k, v in pairs(config.investigation_decisions[investigation_id]) do
        state.decisions[k] = state.decisions[k] or v
      end
    end
    if state.view and state.view.evidence then
      for _, item in ipairs(state.view.evidence) do
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
  end

  function state.save_decisions()
    if not state.view or not state.view.investigation_id then return end
    local file = decisions_file(state.view.investigation_id)
    if file then
      pcall(vim.fn.writefile, { vim.json.encode(state.decisions) }, file)
    end
    if type(config.investigation_decisions) == "table" then
      config.investigation_decisions[state.view.investigation_id] = vim.deepcopy(state.decisions)
      if config.state_file then
        pcall(require("oculus.storage").save, config.state_file, config)
      end
    end
  end

  local function show(value)
    valid_view(value)
    if value.investigation_id then
      state.load_decisions(value.investigation_id)
      for opp_id, dec in pairs(state.decisions or {}) do
        local exists = false
        for _, item in ipairs(value.evidence or {}) do
          if item.kind == "developer_decision" and item.opportunity_id == opp_id then
            exists = true
            break
          end
        end
        if not exists then
          value.evidence = value.evidence or {}
          table.insert(value.evidence, {
            kind = "developer_decision",
            opportunity_id = opp_id,
            status = dec.status or dec.decision,
            decision = dec.decision or dec.status,
            validation_id = "developer:" .. (dec.actor or "developer"),
            actor = dec.actor or "developer",
            diagnostic = dec.diagnostic or dec.rationale,
            rationale = dec.rationale or dec.diagnostic,
            created_unix_nanos = dec.created_unix_nanos or tostring(vim.uv.hrtime()),
          })
        end
      end
    end
    local lines, targets = header("CHANGE INVESTIGATION"), {}
    local observation = value.observation
    lines[#lines + 1] = "  " .. text(value.status) .. " · " .. text(value.intent)
    if observation.analysis == "c_zig" then lines[#lines + 1] = "  Analysis: C/C++ ABI → Zig" end
    lines[#lines + 1] = "  Producer: " .. text(observation.repository)
    lines[#lines + 1] = "  Revisions: " .. text(observation.base) .. " → " .. text(observation.head)
    lines[#lines + 1] = "  Consumer: " .. text(observation.consumer_repository) .. " @ " .. text(observation.consumer_revision)

    if observation.analysis == "c_zig" then
      lines[#lines + 1] = "  Header: " .. text(observation.producer_header) .. " · language " .. text(observation.header_language)
      lines[#lines + 1] = "  Zig source: " .. text(observation.consumer_source)
    end

    lines[#lines + 1] = "  Committed sources only; uncommitted edits are excluded."
    lines[#lines + 1] = "  Investigation: " .. text(value.investigation_id)
    for _, limitation in ipairs(value.limitations) do lines[#lines + 1] = "  Limit: " .. text(limitation) end
    local evidence = {}

    for _, item in ipairs(value.evidence) do
      evidence[item.opportunity_id] = evidence[item.opportunity_id] or {}
      table.insert(evidence[item.opportunity_id], item)
    end

    local experiments = {}
    for _, item in ipairs(value.experiments) do experiments[item.opportunity_id] = item end
    local reasoning = type(value.reasoning) == "table" and value.reasoning or {}
    local obligations, claims = {}, {}

    for _, obligation in ipairs(reasoning.obligations or {}) do
      obligations[obligation.opportunity_id] = obligations[obligation.opportunity_id] or {}
      table.insert(obligations[obligation.opportunity_id], obligation)
    end

    for _, claim in ipairs(reasoning.claims or {}) do
      if type(claim.opportunity_id) == "string" then
        claims[claim.opportunity_id] = claims[claim.opportunity_id] or {}
        table.insert(claims[claim.opportunity_id], claim)
      else
        for opportunity_id, finding_obligations in pairs(obligations) do
          for _, obligation in ipairs(finding_obligations) do
            if vim.tbl_contains(claim.obligations or {}, obligation.id) then
              claims[opportunity_id] = claims[opportunity_id] or {}
              table.insert(claims[opportunity_id], claim)
              break
            end
          end
        end
      end
    end

    local count = 0

    for _, report in ipairs(value.reports) do
      assert(type(report.opportunities) == "table", "Missing report opportunities")
      lines[#lines + 1] = ""
      lines[#lines + 1] = "  Report: " .. text(report.report_id) .. " · rule " .. text(report.rule_version)

      for _, opportunity in ipairs(report.opportunities) do
        count = count + 1
        local target = { opportunity = opportunity, experiment = experiments[opportunity.id], source = opportunity.consumer_location }
        local start = #lines + 1
        local dec = state.decisions and state.decisions[opportunity.id]
        local title_suffix = dec and (" · [" .. (dec.status or dec.decision):upper() .. "]") or ""
        lines[#lines + 1] = "  " .. text(opportunity.title) .. " · " .. text(opportunity.status) .. title_suffix
        lines[#lines + 1] = "    " .. text(opportunity.explanation)

        if dec then
          local note = dec.diagnostic or dec.rationale
          local note_text = (note and note ~= "") and (" · " .. text(note)) or ""
          lines[#lines + 1] = "    Decision: " .. text(dec.status or dec.decision) .. " · by " .. text(dec.actor or "developer") .. note_text
        end

        if type(opportunity.substitution) == "table" then
          lines[#lines + 1] = "    Candidate substitution: " .. text(opportunity.substitution.previous_path)
            .. " → " .. text(opportunity.substitution.replacement_path)
        end

        local source = opportunity.consumer_location or {}
        lines[#lines + 1] = "    Source: " .. text(source.path) .. ":" .. text(source.line)

        for _, step in ipairs(opportunity.evidence_path or {}) do
          lines[#lines + 1] = "    " .. text(step.relation) .. " → " .. text(step.description)

          if type(step.source) == "table" then
            lines[#lines + 1] = "      " .. text(step.source.path) .. ":" .. text(step.source.line)
            targets[#lines] = { opportunity = opportunity, experiment = target.experiment, source = step.source }
          end
        end

        for _, claim in ipairs(claims[opportunity.id] or {}) do
          lines[#lines + 1] = "    Claim: " .. text(claim.status) .. " · " .. text(claim.statement)
          lines[#lines + 1] = "      Rule: " .. text(claim.rule_version)

          for _, support in ipairs(claim.support or {}) do
            lines[#lines + 1] = "      Support: " .. text(support.kind) .. " · " .. text(support.artifact)

            if type(support.source) == "table" then
              lines[#lines + 1] = "        " .. text(support.source.path) .. ":" .. text(support.source.line)
              targets[#lines] = { opportunity = opportunity, experiment = target.experiment, source = support.source }
            end
          end
        end

        for _, obligation in ipairs(obligations[opportunity.id] or {}) do
          lines[#lines + 1] = "    Obligation: " .. text(obligation.label) .. " · " .. text(obligation.status)
          local resolution = obligation_resolution(obligation)
          if resolution then
            lines[#lines + 1] = "      Resolves with: " .. text(resolution)
          end
          for _, artifact in ipairs(obligation.evidence or {}) do lines[#lines + 1] = "      Evidence: " .. text(artifact) end
        end

        for _, limitation in ipairs(opportunity.limitations or {}) do lines[#lines + 1] = "    Limit: " .. text(limitation) end

        lines[#lines + 1] = target.experiment and ("    n: " .. text(target.experiment.label))
          or (observation.analysis == "c_zig" and "    Native preparation requires explicit sources and behavioral cases."
            or "    No supported experiment for this finding.")

        if observation.analysis == "c_zig" then lines[#lines + 1] = "    p: prepare a C/Zig composition from selected sources and behavioral cases." end

        if opportunity.kind == "candidate_substitution" then
          lines[#lines + 1] = "    p: adapt the consumer's calls and test them against the producer before and after the change."
        end

        lines[#lines + 1] = "    h: promote to hypothesis · s: select · d: defer · x: dismiss"

        local attempts = evidence[opportunity.id] or {}
        local execution_attempts = vim.tbl_filter(function(r) return r.kind ~= "developer_decision" end, attempts)
        if #execution_attempts > 0 then lines[#lines + 1] = "    Evidence attempts: " .. #execution_attempts end

        for _, result in ipairs(attempts) do
          lines[#lines + 1] = "    Evidence: " .. text(result.status) .. " · " .. text(result.validation_id)
          if type(result.diagnostic) == "string" and result.diagnostic ~= "" then
            if result.kind == "developer_decision" then
              lines[#lines + 1] = "      Rationale: " .. text(result.diagnostic)
            else
              lines[#lines + 1] = "      " .. text(result.diagnostic)
            end
          end
          if type(result.scope) == "string" and result.scope ~= "" then lines[#lines + 1] = "      Scope: " .. text(result.scope) end

          local function artifact_row(label, artifact)
            if type(artifact) ~= "string" then return end
            lines[#lines + 1] = "        " .. label .. ": " .. text(artifact) .. " · Enter to inspect"
            targets[#lines] = { opportunity = opportunity, source = { artifact = artifact, digest = artifact, path = label, line = 1, column = 1 } }
          end

          for _, case in ipairs(result.cases or {}) do
            lines[#lines + 1] = "      Case: " .. text(case.label or case.name) .. " · " .. text(case.status or case.verdict)

            if result.kind == "rust_call_site_adaptation" then
              lines[#lines + 1] = "        Before the change: " .. text(case.baseline) .. " · adapted after: " .. text(case.adapted)

              if type(case.adapted) == "table" then
                artifact_row("stdout", case.adapted.stdout)
                artifact_row("stderr", case.adapted.stderr)
              end
            elseif result.kind == "c_zig_composition" then
              lines[#lines + 1] = "        Expected exit: " .. text(case.expected_exit) .. " · actual: " .. text(case.actual_exit)
              lines[#lines + 1] = "        Expected stdout: " .. text(case.expected_stdout)
              artifact_row("stdout", case.stdout)
              artifact_row("stderr", case.stderr)
            else
              lines[#lines + 1] = "        Expected: " .. text(case.expected) .. " · actual: " .. text(case.actual)
            end
          end

          if result.kind == "rust_call_site_adaptation" then
            lines[#lines + 1] = "      Adaptation needed: " .. text(result.adaptation_needed) .. " · adapted build: " .. text(result.adapted_build)

            for _, step in ipairs(result.steps or {}) do
              if not step.phase:match("_case$") then
                lines[#lines + 1] = "      " .. text(step.phase) .. ": " .. text(step.name) .. " · " .. (step.success and "succeeded" or "failed")
                artifact_row("stderr", step.stderr)
              end
            end

            for _, unresolved in ipairs(result.unresolved or {}) do lines[#lines + 1] = "      Unresolved: " .. text(unresolved) end
          end

          if result.kind == "c_zig_composition" then
            lines[#lines + 1] = "      Native link: " .. text(result.link_status)

            for _, step in ipairs(result.steps or {}) do
              if step.phase ~= "behavior" then
                lines[#lines + 1] = "      " .. text(step.phase) .. ": " .. text(step.name) .. " · " .. (step.success and "succeeded" or "failed")
                artifact_row("stderr", step.stderr)
              end
            end

            for _, unresolved in ipairs(result.unresolved or {}) do lines[#lines + 1] = "      Unresolved: " .. text(unresolved) end
          end
        end

        local execution_attempts = vim.tbl_filter(function(r) return r.kind ~= "developer_decision" end, attempts)

        if #execution_attempts > 0 then
          local compiler = (type(opportunity.validation) == "table" and opportunity.validation.kind == "rust_function_signature")
            or (target.experiment and target.experiment.kind == "rust_function_signature")

          local adapted = vim.iter(execution_attempts):any(function(result) return result.kind == "rust_call_site_adaptation" end)

          lines[#lines + 1] = adapted and "      Selected consumer tests only; behavioral equivalence remains unverified and relationship remains inferred."
            or compiler and "      Scoped to compiler signature checks; behavior remains unverified and relationship remains inferred."
            or (observation.analysis == "c_zig" and "      Selected cases only; general equivalence remains unverified and relationship remains inferred."
              or "      Scoped to this fixture; relationship remains inferred.")
        elseif #attempts > 0 then
          lines[#lines + 1] = "      Developer decision recorded; relationship remains inferred."
        end

        for row = start, #lines do targets[row] = targets[row] or target end
        lines[#lines + 1] = ""
      end

      for _, limitation in ipairs(report.limitations or {}) do lines[#lines + 1] = "  Limit: " .. text(limitation) end
      for _, delta in ipairs(report.deltas or {}) do lines[#lines + 1] = "  API delta: " .. text(delta.kind) .. " · " .. text(delta.path) end
    end

    if count == 0 then
      lines[#lines + 1] = value.status == "completed" and "  No opportunities matched the supported rules."
        or "  Analysis unavailable for this scope; see reasons above."
    end

    state.view, state.targets, state.mode = value, targets, "investigation"
    local cur
    if vim.api.nvim_win_is_valid(state.win) then
      cur = vim.api.nvim_win_get_cursor(state.win)
    end
    set_lines(state.buf, lines)
    if cur and vim.api.nvim_win_is_valid(state.win) then
      local max_line = vim.api.nvim_buf_line_count(state.buf)
      pcall(vim.api.nvim_win_set_cursor, state.win, { math.min(cur[1], max_line), cur[2] })
    end
  end

  function state.load(investigation_id)
    request({ "investigation", investigation_id, config.store }, show)
  end

  function state.catalog()
    request({ "investigations", config.store }, function(value)
      assert(type(value.investigations) == "table" and vim.islist(value.investigations), "Missing investigation catalog")
      local lines, targets = header("INVESTIGATION CATALOG"), {}

      for _, item in ipairs(value.investigations) do
        assert(type(item.investigation_id) == "string" and type(item.observation) == "table", "Invalid catalog entry")
        local start = #lines + 1
        lines[#lines + 1] = "  " .. text(item.status) .. " · " .. text(item.intent)
        if item.observation.analysis == "c_zig" then lines[#lines + 1] = "    Analysis: C/C++ ABI → Zig" end
        lines[#lines + 1] = "    " .. text(item.observation.repository) .. " → " .. text(item.observation.consumer_repository)
        lines[#lines + 1] = "    " .. text(item.observation.base) .. " → " .. text(item.observation.head)
        lines[#lines + 1] = "    " .. text(item.investigation_id)
        for row = start, #lines do targets[row] = item end
        lines[#lines + 1] = ""
      end

      if #value.investigations == 0 then lines[#lines + 1] = "  No investigations. Use :OculusInvestigate or gI on local activity." end
      state.catalog_value, state.targets, state.mode = value, targets, "catalog"
      set_lines(state.buf, lines)
    end)
  end

  function state.refresh()
    if state.mode == "investigation" then state.load(state.view.investigation_id) else state.catalog() end
  end

  local function selected(target)
    return target or state.targets[vim.api.nvim_win_get_cursor(state.win)[1]]
  end

  local function source_window()
    if not vim.api.nvim_win_is_valid(state.source_win)
      or vim.api.nvim_win_get_config(state.source_win).relative ~= ""
      or vim.bo[vim.api.nvim_win_get_buf(state.source_win)].modified then
      vim.api.nvim_set_current_win(state.win)
      vim.cmd("leftabove vnew")
      state.source_win = vim.api.nvim_get_current_win()
    end

    return state.source_win
  end

  function state.navigate(target)
    target = selected(target)
    if not target then status("Place the cursor on an investigation or finding."); return end
    if state.mode == "catalog" then state.load(target.investigation_id); return end
    local location = target.source

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
      vim.api.nvim_set_current_win(win)
      status(message)
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
    target = selected(target)

    if state.mode ~= "investigation" or not target or not target.experiment then
      status("The selected finding has no supported experiment.")
      return
    end

    require("oculus.nexus").open(nexus_config, config, {
      kind = "discovery_validation", investigation_id = state.view.investigation_id,
      opportunity_id = target.opportunity.id, artifact_store = config.store,
    })
  end

  function state.compose(target, path)
    target = selected(target)
    local finding = state.mode == "investigation" and target and target.opportunity
    local c_zig = finding and state.view.observation.analysis == "c_zig"
    local rust = finding and target.opportunity.kind == "candidate_substitution" and not c_zig

    if not c_zig and not rust then
      status("Select a C/Zig finding or a Rust substitution finding to prepare a composition.")
      return
    end

    local options = { native = true, kind = rust and "rust" or "c_zig",
      investigation_id = state.view.investigation_id, opportunity_id = target.opportunity.id }

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

        local request = vim.json.encode({ schema_version = 1, investigation_id = options.investigation_id,
          opportunity_id = options.opportunity_id, tests = vim.split(vim.trim(value), "%s+") })

        local file = vim.fn.stdpath("state") .. "/oculus-adaptations/" .. vim.fn.sha256(request) .. ".json"
        vim.fn.mkdir(vim.fn.fnamemodify(file, ":h"), "p")
        if vim.fn.writefile({ request }, file) ~= 0 then status("Could not write the adaptation request."); return end
        open(file)
      end)
    else vim.ui.input({ prompt = "C/Zig composition request (sources and cases): ", completion = "file" }, open) end
  end

  local function record_decision(target, decision_name, rationale)
    target = selected(target)
    if state.mode ~= "investigation" or not target or not target.opportunity then
      status("Place the cursor on an opportunity to steer it.")
      return false
    end

    local opp_id = target.opportunity.id
    local actor = (vim.env.USER and vim.env.USER ~= "") and vim.env.USER or "developer"
    local now = tostring(vim.uv.hrtime())
    local item = {
      kind = "developer_decision",
      opportunity_id = opp_id,
      status = decision_name,
      decision = decision_name,
      validation_id = "developer:" .. actor,
      actor = actor,
      diagnostic = (type(rationale) == "string" and vim.trim(rationale) ~= "") and vim.trim(rationale) or nil,
      rationale = (type(rationale) == "string" and vim.trim(rationale) ~= "") and vim.trim(rationale) or nil,
      created_unix_nanos = now,
    }

    state.decisions = state.decisions or {}
    state.decisions[opp_id] = item

    state.view.evidence = vim.tbl_filter(function(e)
      return not (e.kind == "developer_decision" and e.opportunity_id == opp_id)
    end, state.view.evidence or {})
    table.insert(state.view.evidence, item)

    state.save_decisions()
    show(state.view)
    return true
  end

  function state.promote(target, note)
    target = selected(target)
    if state.mode ~= "investigation" or not target or not target.opportunity then
      status("Place the cursor on an opportunity to steer it.")
      return
    end

    if note ~= nil then
      if record_decision(target, "promoted", note) then
        status("Opportunity promoted to hypothesis.")
      end
      return
    end

    vim.ui.input({ prompt = "Promote to hypothesis (optional note): " }, function(input)
      if state.closed or input == nil then return end
      if record_decision(target, "promoted", input) then
        status("Opportunity promoted to hypothesis.")
      end
    end)
  end

  function state.select_opportunity(target, note)
    target = selected(target)
    if state.mode ~= "investigation" or not target or not target.opportunity then
      status("Place the cursor on an opportunity to steer it.")
      return
    end

    if note ~= nil then
      if record_decision(target, "selected", note) then
        status("Opportunity selected for active investigation.")
      end
      return
    end

    vim.ui.input({ prompt = "Selection rationale (optional note): " }, function(input)
      if state.closed or input == nil then return end
      if record_decision(target, "selected", input) then
        status("Opportunity selected for active investigation.")
      end
    end)
  end

  function state.defer(target, reason)
    target = selected(target)
    if state.mode ~= "investigation" or not target or not target.opportunity then
      status("Place the cursor on an opportunity to steer it.")
      return
    end

    if reason ~= nil then
      if record_decision(target, "deferred", reason) then
        status("Opportunity deferred.")
      end
      return
    end

    vim.ui.input({ prompt = "Reason for deferral (optional note): " }, function(input)
      if state.closed or input == nil then return end
      if record_decision(target, "deferred", input) then
        status("Opportunity deferred.")
      end
    end)
  end

  function state.dismiss(target, reason)
    target = selected(target)
    if state.mode ~= "investigation" or not target or not target.opportunity then
      status("Place the cursor on an opportunity to steer it.")
      return
    end

    if reason ~= nil then
      if record_decision(target, "dismissed", reason) then
        status("Opportunity dismissed.")
      end
      return
    end

    vim.ui.input({ prompt = "Reason for dismissal (optional note): " }, function(input)
      if state.closed or input == nil then return end
      if record_decision(target, "dismissed", input) then
        status("Opportunity dismissed.")
      end
    end)
  end

  function state.clear_decision(target)
    target = selected(target)
    if state.mode ~= "investigation" or not target or not target.opportunity then
      status("Place the cursor on an opportunity to steer it.")
      return
    end

    local opp_id = target.opportunity.id
    if not (state.decisions and state.decisions[opp_id]) then
      status("No decision recorded for this opportunity.")
      return
    end

    state.decisions[opp_id] = nil
    state.view.evidence = vim.tbl_filter(function(e)
      return not (e.kind == "developer_decision" and e.opportunity_id == opp_id)
    end, state.view.evidence or {})

    state.save_decisions()
    show(state.view)
    status("Developer decision cleared.")
  end

  local maps = {
    ["<CR>"] = function() state.navigate() end,
    n = function() state.queue() end,
    p = function() state.compose() end,
    h = function() state.promote() end,
    s = function() state.select_opportunity() end,
    d = function() state.defer() end,
    x = function() state.dismiss() end,
    u = function() state.clear_decision() end,
    r = state.refresh,
    g = state.catalog,
    c = state.cancel,
    ["<C-c>"] = state.cancel,
    q = state.close,
    ["<Esc>"] = state.close,
  }

  for key, callback in pairs(maps) do vim.keymap.set("n", key, callback, { buffer = state.buf, silent = true, nowait = true }) end
  set_lines(state.buf, header("INVESTIGATIONS"))

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

  local function header_language()
    ask("header_language", "Header language (c or c++): ", "c", function()
      if request.header_language ~= "c" and request.header_language ~= "c++" then
        vim.notify("Oculus: header language must be c or c++.", vim.log.levels.WARN)
        return
      end

      consumer()
    end)
  end

  local function producer_input()
    if c_zig then ask("producer_header", "Producer standalone header (relative to repository): ", "include/api.h", header_language)
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
