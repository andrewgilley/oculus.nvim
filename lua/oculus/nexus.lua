local M = {}
local client = require("oculus.nexus.client")

local function text(value)
  if value == nil or value == vim.NIL then return "—" end
  return tostring(value):gsub("[%c]", " ")
end

local function set_lines(buf, lines)
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
end

local function scratch()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].filetype = "oculus-nexus"
  vim.bo[buf].swapfile = false
  return buf
end

function M.open(config, plexus_config, submission)
  if M.state and not M.state.closed then M.state.close() end
  config = vim.deepcopy(config or {})
  config.state_dir = vim.fn.fnamemodify(config.state_dir or vim.fn.stdpath("data") .. "/oculus/nexus", ":p")
  local state = { config = config, generation = 0, targets = {}, jobs = {}, mode = "jobs" }
  M.state = state
  local width = math.max(20, math.min(vim.o.columns - 4, math.floor(vim.o.columns * 0.92)))
  local height = math.max(6, math.min(vim.o.lines - 4, math.floor(vim.o.lines * 0.82)))
  state.buf = scratch()

  state.win = vim.api.nvim_open_win(state.buf, true, {
    relative = "editor", row = 1, col = math.max(0, math.floor((vim.o.columns - width) / 2)),
    width = width, height = height, border = "rounded", style = "minimal",
  })

  vim.wo[state.win].wrap = false
  state.footer_buf = scratch()

  state.footer_win = vim.api.nvim_open_win(state.footer_buf, false, {
    relative = "win", win = state.win, row = height - 3, col = 0,
    width = width, height = 3, style = "minimal", focusable = false, zindex = 60,
  })

  local function footer(message)
    if state.closed then return end

    set_lines(state.footer_buf, {
      "  r refresh  w work queue  c cancel job  R retry as new job",
      "  o open evidence  s resources  g jobs  q close",
      "  " .. text(message or (state.working and "Worker active; r refreshes progress; c requests cancellation."
        or "Local resources · closing this view does not cancel jobs.")),
    })
  end

  local function failure(err)
    state.error = tostring(err)
    footer("Error: " .. state.error)
    vim.notify("Oculus Nexus: " .. state.error, vim.log.levels.ERROR)
  end

  local function render()
    local lines = { "  NEXUS · local deployment resources", "", "  State: " .. config.state_dir, "" }
    state.targets = {}

    if state.mode == "resources" then
      for _, resource in ipairs(state.resources or {}) do
        lines[#lines + 1] = "  " .. text(resource.id) .. " · " .. text(resource.backend)
          .. " · " .. (resource.available and "available" or "unavailable")

        lines[#lines + 1] = "    " .. text(resource.reason)
        local policy = resource.policy

        if resource.backend == "plexus-native" then
          lines[#lines + 1] = "    Native worker · timeout ms: " .. text(policy.wall_timeout_ms)
        else
          lines[#lines + 1] = "    Guest linear memory bytes: " .. text(policy.max_memory_bytes)
            .. " · fuel/case: " .. text(policy.max_fuel_per_case) .. " · timeout ms: " .. text(policy.wall_timeout_ms)
        end

        lines[#lines + 1] = ""
      end

      if #(state.resources or {}) == 0 then lines[#lines + 1] = "  No resources configured." end
    else
      for _, job in ipairs(state.jobs) do
        local start = #lines + 1
        lines[#lines + 1] = "  " .. text(job.id) .. " · " .. text(job.state) .. " · " .. text(job.resource_id)

        if job.kind == "composition" then
          lines[#lines + 1] = "    Linked composition · open to inspect parts, connections and cases"
        elseif job.kind == "discovery_validation" then
          lines[#lines + 1] = "    Opportunity: " .. text(job.binding_id) .. " · investigation: " .. text(job.hypothesis_id)
          lines[#lines + 1] = "    Evidence investigation: " .. text(job.result_investigation_id)
        else
          lines[#lines + 1] = "    Binding: " .. text(job.binding_id) .. " · hypothesis: " .. text(job.hypothesis_id)
          lines[#lines + 1] = "    Evidence hypothesis: " .. text(job.result_hypothesis_id)
        end

        lines[#lines + 1] = "    Plan: " .. text(job.plan_id)
        lines[#lines + 1] = "    Run: " .. text(job.run_id)
        lines[#lines + 1] = "    Evidence conclusion: " .. text(job.conclusion)
        lines[#lines + 1] = "    Artifact store: " .. text(job.artifact_store)
        if job.cancel_requested then lines[#lines + 1] = "    Cancellation requested" end
        if job.retry_of and job.retry_of ~= vim.NIL then lines[#lines + 1] = "    Retry of: " .. text(job.retry_of) end
        if job.error and job.error ~= vim.NIL then lines[#lines + 1] = "    Error: " .. text(job.error) end
        for row = start, #lines do state.targets[row] = job end
        lines[#lines + 1] = ""
      end

      if #state.jobs == 0 then lines[#lines + 1] = "  No jobs. Press n on a Plexus binding or supported discovery finding." end
    end

    vim.list_extend(lines, { "", "", "" })
    set_lines(state.buf, lines)
    footer()
  end

  function state.close()
    if state.closed then return end
    state.closed = true
    state.generation = state.generation + 1

    for _, win in ipairs({ state.footer_win, state.win }) do
      if vim.api.nvim_win_is_valid(win) then vim.api.nvim_win_close(win, true) end
    end
  end

  vim.api.nvim_create_autocmd("WinClosed", { pattern = tostring(state.win), once = true, callback = state.close })

  function state.refresh(mode)
    if state.closed then return end
    state.mode = mode or state.mode
    state.generation = state.generation + 1
    local generation, requested_mode = state.generation, state.mode
    footer("Loading " .. requested_mode .. "…")
    local command = requested_mode == "resources" and "resources" or "list"

    client.request(config, { command, config.state_dir }, function(value, err)
      if state.closed or generation ~= state.generation then return end
      if err then failure(err); return end
      state.error = nil
      if requested_mode == "resources" then state.resources = value.resources else state.jobs = value.jobs end
      render()
    end)
  end

  local function action(args)
    if state.closed then return end
    if state.busy then footer("A job request is pending."); return end
    state.busy = true
    footer("Requesting " .. args[1] .. "…")

    client.request(config, args, function(value, err)
      if state.closed then return end
      state.busy = false
      if err then failure(err); return end
      state.last_job = value.job
      state.refresh("jobs")
    end)
  end

  function state.submit(value)
    if value.kind == "composition" then
      action({ "submit-composition", value.plan_id, value.artifact_store, config.state_dir })
      return
    end

    if value.kind == "investigation_plan" then
      action({ "submit-investigation-plan", value.plan_id, value.artifact_store, config.state_dir })
      return
    end

    if value.kind == "discovery_validation" then
      action({ "submit-investigation", value.investigation_id, value.opportunity_id, value.artifact_store, config.state_dir })
      return
    end

    action({ "submit", value.hypothesis_id, value.binding_id, value.artifact_store, config.state_dir })
  end

  function state.work()
    if state.closed then return end
    if state.working then footer("Worker active; use r to refresh or c to cancel a job."); return end
    state.working = true
    footer()

    client.request(config, { "work", config.state_dir }, function(_, err)
      if state.closed then return end
      state.working = false
      if err then failure(err); return end
      state.refresh()
    end)
  end

  local function selected(job)
    job = job or state.targets[vim.api.nvim_win_get_cursor(state.win)[1]]
    if not job then footer("Place the cursor on a job.") end
    return job
  end

  function state.cancel(job)
    job = selected(job)
    if job then action({ "cancel", job.id, config.state_dir }) end
  end

  function state.retry(job)
    job = selected(job)
    if job then action({ "retry", job.id, config.state_dir }) end
  end

  function state.open_result(job)
    job = selected(job)
    if not job then return end

    if job.kind == "composition" then
      local result_config = vim.deepcopy(plexus_config or {})
      result_config.store = job.artifact_store
      state.close()
      require("oculus.compositions").open(result_config, config, job.plan_id)
      return
    end

    if job.kind == "discovery_validation" then
      if type(job.result_investigation_id) ~= "string" then footer("No investigation evidence yet."); return end
      local result_config = vim.deepcopy(plexus_config or {})
      result_config.store = job.artifact_store
      state.close()
      require("oculus.investigations").open(result_config, config, job.result_investigation_id)
      return
    end

    if type(job.result_hypothesis_id) ~= "string" then
      footer("No attached evidence yet. The run and any attachment error remain in the job.")
      return
    end

    local result_config = vim.deepcopy(plexus_config or {})
    result_config.store = job.artifact_store
    state.close()
    require("oculus.plexus").open(result_config, nil, job.result_hypothesis_id)
  end

  local maps = {
    q = state.close, ["<Esc>"] = state.close, r = function() state.refresh() end,
    w = state.work, c = function() state.cancel() end, R = function() state.retry() end,
    o = function() state.open_result() end, ["<CR>"] = function() state.open_result() end,
    s = function() state.refresh("resources") end, g = function() state.refresh("jobs") end,
  }

  for key, callback in pairs(maps) do
    vim.keymap.set("n", key, callback, { buffer = state.buf, silent = true, nowait = true })
  end

  render()
  if submission then state.submit(submission) else state.refresh() end
  return state
end

return M
