local M = {}

local function string_val(v)
  return type(v) == "string" and v ~= "" and v or nil
end

function M.get_suggested_branch(bundle)
  bundle = bundle or {}
  local art = type(bundle.forge_artifact) == "table" and bundle.forge_artifact or nil

  if art and string_val(art.id) then
    local kind = string_val(art.kind) or "issue"
    return string.format("experiment-%s-%s", kind:lower(), art.id)
  end

  local meta = bundle.metadata or {}
  local target = string_val(meta.target)

  if target then
    local clean = target:gsub("[^%w%-_.]+", "-"):sub(1, 12)
    return string.format("experiment-%s", clean)
  end

  return "experiment-hypothesis"
end

function M.get_worktree_dir(repo_root, branch_name)
  local branch_slug = branch_name:gsub("[^%w%-_.]+", "-")
  local parent = vim.fs.dirname(repo_root)
  local name = vim.fs.basename(repo_root)
  return vim.fs.joinpath(parent, name .. "-" .. branch_slug)
end

function M.detect_test_cmd(worktree_dir)
  if vim.fn.filereadable(vim.fs.joinpath(worktree_dir, "Cargo.toml")) == 1 then
    return { "cargo", "test" }
  elseif vim.fn.filereadable(vim.fs.joinpath(worktree_dir, "package.json")) == 1 then
    return { "npm", "test" }
  elseif vim.fn.filereadable(vim.fs.joinpath(worktree_dir, "Makefile")) == 1 then
    return { "make", "test" }
  end

  return { "cargo", "test" }
end

function M.create_worktree(repo_root, branch_name, callback)
  local worktree_dir = M.get_worktree_dir(repo_root, branch_name)

  if vim.uv.fs_stat(worktree_dir) then
    callback(worktree_dir, nil)
    return
  end

  local cmd1 = { "git", "-C", repo_root, "worktree", "add", "-b", branch_name, worktree_dir }

  local function on_cmd1(out1)
    if out1.code == 0 or vim.uv.fs_stat(worktree_dir) then
      callback(worktree_dir, nil)
      return
    end

    -- Branch may already exist; try adding without -b
    local cmd2 = { "git", "-C", repo_root, "worktree", "add", worktree_dir, branch_name }

    local function on_cmd2(out2)
      if out2.code == 0 or vim.uv.fs_stat(worktree_dir) then
        callback(worktree_dir, nil)
      else
        local err = (out2.stderr ~= "" and out2.stderr) or out1.stderr or "failed to create git worktree"
        callback(nil, err)
      end
    end

    if vim.system then
      vim.system(cmd2, { text = true }, on_cmd2)
    else
      local res = vim.fn.system(cmd2)
      on_cmd2({ code = vim.v.shell_error, stderr = res })
    end
  end

  if vim.system then
    vim.system(cmd1, { text = true }, on_cmd1)
  else
    local res = vim.fn.system(cmd1)
    on_cmd1({ code = vim.v.shell_error, stderr = res })
  end
end

function M.run_test_probe(worktree_dir, test_cmd, callback)
  local cmd = test_cmd or M.detect_test_cmd(worktree_dir)

  local function on_exit(output, code)
    callback(output, code)
  end

  if vim.system then
    vim.system(cmd, { cwd = worktree_dir, text = true }, function(out)
      local combined = (out.stdout or "") .. (out.stderr or "")
      on_exit(combined, out.code)
    end)
  else
    local cwd_prev = vim.fn.getcwd()
    vim.cmd("tcd " .. vim.fn.fnameescape(worktree_dir))
    local out = vim.fn.system(cmd)
    local code = vim.v.shell_error
    vim.cmd("tcd " .. vim.fn.fnameescape(cwd_prev))
    on_exit(out, code)
  end
end

function M.open_experiment_ui(bundle, opts, on_close)
  bundle = bundle or {}
  opts = opts or {}
  local meta = bundle.metadata or {}
  local repo_root = meta.repository_root or vim.fn.getcwd()
  local branch_name = opts.branch_name or M.get_suggested_branch(bundle)
  local worktree_dir = M.get_worktree_dir(repo_root, branch_name)
  local test_cmd = M.detect_test_cmd(repo_root)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].filetype = "markdown"
  local cfg = opts.window_config

  if not cfg then
    local ok_win, inv_win = pcall(require, "oculus.investigate.window")

    if ok_win and type(inv_win.window_config) == "function" then
      cfg = inv_win.window_config(opts)
    end
  end

  local win_w = (cfg and cfg.width) or math.min(100, math.floor(vim.o.columns * 0.82))
  local win_h = (cfg and cfg.height) or math.min(30, math.floor(vim.o.lines * 0.75))
  local row = (cfg and cfg.row) or math.floor((vim.o.lines - win_h) / 2)
  local col = (cfg and cfg.col) or math.floor((vim.o.columns - win_w) / 2)
  local border = (cfg and cfg.border) or "rounded"

  local win = vim.api.nvim_open_win(buf, false, {
    relative = "editor",
    width = win_w,
    height = win_h,
    row = row,
    col = col,
    style = "minimal",
    border = border,
    zindex = 60,
  })

  local f_buf = vim.api.nvim_create_buf(false, true)
  vim.bo[f_buf].buftype = "nofile"
  vim.bo[f_buf].bufhidden = "wipe"
  vim.bo[f_buf].swapfile = false
  vim.bo[f_buf].filetype = "oculus"
  local cmd_text = "  r run probe   o open worktree   p candidate patches   q close"

  local f_lines = {
    "  " .. string.rep("─", math.max(1, win_w - 4)),
    cmd_text,
  }

  vim.bo[f_buf].modifiable = true
  vim.api.nvim_buf_set_lines(f_buf, 0, -1, false, f_lines)
  vim.bo[f_buf].modifiable = false
  vim.bo[f_buf].readonly = true
  local f_ns = vim.api.nvim_create_namespace("oculus_worktree_footer_hl")
  vim.api.nvim_buf_clear_namespace(f_buf, f_ns, 0, -1)
  vim.api.nvim_buf_add_highlight(f_buf, f_ns, "WinSeparator", 0, 2, -1)
  vim.api.nvim_buf_add_highlight(f_buf, f_ns, "Comment", 1, 2, #cmd_text)

  local f_win = vim.api.nvim_open_win(f_buf, false, {
    relative = "editor",
    width = win_w,
    height = 2,
    row = row + win_h - 1,
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
  pcall(vim.api.nvim_set_current_win, win)

  vim.schedule(function()
    if vim.api.nvim_win_is_valid(win) then
      pcall(vim.api.nvim_set_current_win, win)
    end
  end)

  vim.wo[win].cursorline = true
  vim.wo[win].wrap = false

  local state = {
    worktree_dir = worktree_dir,
    branch_name = branch_name,
    is_created = vim.uv.fs_stat(worktree_dir) ~= nil,
    test_output = nil,
    running = false,
  }

  local function render()
    if not vim.api.nvim_buf_is_valid(buf) then
      return
    end

    local lines = {}
    lines[#lines + 1] = "# EXPERIMENTAL WORKTREE & HYPOTHESIS TEST HARNESS"
    lines[#lines + 1] = "Isolate modifications in a separate worktree and verify behavior before patching."
    lines[#lines + 1] = ""
    lines[#lines + 1] = string.format("• Repository:   %s", repo_root)
    lines[#lines + 1] = string.format("• Branch:       %s", state.branch_name)
    lines[#lines + 1] = string.format("• Worktree Dir: %s", state.worktree_dir)
    lines[#lines + 1] = string.format("• Status:       %s", state.is_created and "Provisioned & Ready" or "Not yet provisioned")
    lines[#lines + 1] = string.format("• Test Command: %s", table.concat(test_cmd, " "))
    lines[#lines + 1] = ""
    local derived = bundle.derived or {}
    local hyps = derived.hypotheses or {}

    if #hyps > 0 then
      lines[#lines + 1] = "## HYPOTHESIS UNDER VERIFICATION"
      lines[#lines + 1] = string.format("• %s", hyps[1].title)
      lines[#lines + 1] = string.format("  Rationale: %s", hyps[1].rationale)
      lines[#lines + 1] = ""
    end

    lines[#lines + 1] = "## TEST PROBE RESULTS"

    if state.running then
      lines[#lines + 1] = "Running test probe in isolated worktree... (please wait)"
    elseif state.test_output then
      for _, l in ipairs(vim.split(state.test_output, "\n")) do
        lines[#lines + 1] = "  " .. l
      end
    else
      lines[#lines + 1] = "Press [r] to execute test probe in the isolated worktree."
      lines[#lines + 1] = "Press [o] to open the worktree directory in Neovim."
      lines[#lines + 1] = "Press [p] to compare Candidate Patches (Minimal vs. Architectural)."
    end

    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.bo[buf].modifiable = false
  end

  local function ensure_and_run_test()
    if state.running then
      return
    end

    state.running = true
    render()

    M.create_worktree(repo_root, state.branch_name, function(wt_dir, err)
      if err then
        state.running = false
        state.test_output = "Worktree creation error: " .. tostring(err)
        vim.schedule(render)
        return
      end

      state.is_created = true
      state.worktree_dir = wt_dir

      M.run_test_probe(wt_dir, test_cmd, function(out, code)
        state.running = false

        local status_msg = code == 0 and "✓ PROBE PASSED (All invariants held)"
          or string.format("✗ PROBE FAILED (Exit code %d)", code)

        state.test_output = string.format("%s\n\n%s", status_msg, out:sub(1, 3000))
        vim.schedule(render)
      end)
    end)
  end

  local function open_worktree_editor()
    M.create_worktree(repo_root, state.branch_name, function(wt_dir, err)
      if err then
        vim.notify("Oculus: could not create worktree: " .. tostring(err), vim.log.levels.ERROR)
        return
      end

      vim.schedule(function()
        if vim.api.nvim_win_is_valid(f_win) then
          pcall(vim.api.nvim_win_close, f_win, true)
        end

        if vim.api.nvim_buf_is_valid(f_buf) then
          pcall(vim.api.nvim_buf_delete, f_buf, { force = true })
        end

        pcall(vim.api.nvim_win_close, win, true)
        vim.cmd("tcd " .. vim.fn.fnameescape(wt_dir))

        local target_file = (bundle.entities and bundle.entities[1] and bundle.entities[1].file_path)
          or (bundle.traceability_links and bundle.traceability_links[1] and bundle.traceability_links[1].target_entity and bundle.traceability_links[1].target_entity.file_path)

        if target_file then
          local abs = vim.fs.joinpath(wt_dir, target_file)
          vim.cmd("edit " .. vim.fn.fnameescape(abs))
        else
          vim.cmd("edit .")
        end

        vim.notify(string.format("Oculus: Switched to worktree '%s'", state.branch_name), vim.log.levels.INFO)
      end)
    end)
  end

  local function show_candidate_patches()
    local agent = require("oculus.investigate.agent")
    local patch_text = agent.generate_candidate_patches(bundle)
    local p_buf = vim.api.nvim_create_buf(false, true)
    vim.bo[p_buf].filetype = "markdown"
    vim.api.nvim_buf_set_lines(p_buf, 0, -1, false, vim.split(patch_text, "\n"))

    local p_win = vim.api.nvim_open_win(p_buf, false, {
      relative = "editor",
      width = win_w,
      height = win_h,
      row = row,
      col = col,
      style = "minimal",
      border = border,
      zindex = 60,
    })

    local p_f_buf = vim.api.nvim_create_buf(false, true)
    vim.bo[p_f_buf].buftype = "nofile"
    vim.bo[p_f_buf].bufhidden = "wipe"
    vim.bo[p_f_buf].swapfile = false
    vim.bo[p_f_buf].filetype = "oculus"
    local p_cmd_text = "  q close"

    local p_f_lines = {
      "  " .. string.rep("─", math.max(1, win_w - 4)),
      p_cmd_text,
    }

    vim.bo[p_f_buf].modifiable = true
    vim.api.nvim_buf_set_lines(p_f_buf, 0, -1, false, p_f_lines)
    vim.bo[p_f_buf].modifiable = false
    vim.bo[p_f_buf].readonly = true
    local p_f_ns = vim.api.nvim_create_namespace("oculus_worktree_p_footer_hl")
    vim.api.nvim_buf_clear_namespace(p_f_buf, p_f_ns, 0, -1)
    vim.api.nvim_buf_add_highlight(p_f_buf, p_f_ns, "WinSeparator", 0, 2, -1)
    vim.api.nvim_buf_add_highlight(p_f_buf, p_f_ns, "Comment", 1, 2, #p_cmd_text)

    local p_f_win = vim.api.nvim_open_win(p_f_buf, false, {
      relative = "editor",
      width = win_w,
      height = 2,
      row = row + win_h - 1,
      col = col + 1,
      style = "minimal",
      focusable = false,
      zindex = 65,
    })

    vim.wo[p_f_win].wrap = false
    vim.wo[p_f_win].cursorline = false
    vim.wo[p_f_win].number = false
    vim.wo[p_f_win].relativenumber = false
    vim.wo[p_f_win].signcolumn = "no"

    local winhl = table.concat({
      "Normal:OculusNormal",
      "NormalFloat:OculusNormal",
    }, ",")

    pcall(function() vim.wo[p_f_win].winhighlight = winhl end)
    pcall(vim.api.nvim_set_current_win, p_win)

    vim.schedule(function()
      if vim.api.nvim_win_is_valid(p_win) then
        pcall(vim.api.nvim_set_current_win, p_win)
      end
    end)

    local function close_p()
      if vim.api.nvim_win_is_valid(p_f_win) then
        pcall(vim.api.nvim_win_close, p_f_win, true)
      end

      if vim.api.nvim_buf_is_valid(p_f_buf) then
        pcall(vim.api.nvim_buf_delete, p_f_buf, { force = true })
      end

      pcall(vim.api.nvim_win_close, p_win, true)

      if vim.api.nvim_win_is_valid(win) then
        pcall(vim.api.nvim_set_current_win, win)
      end
    end

    vim.keymap.set("n", "q", close_p, { buffer = p_buf, silent = true, nowait = true })
    vim.keymap.set("n", "<Esc>", close_p, { buffer = p_buf, silent = true, nowait = true })
    vim.keymap.set("n", "<C-c>", close_p, { buffer = p_buf, silent = true, nowait = true })
  end

  local function close_ui()
    if vim.api.nvim_win_is_valid(f_win) then
      pcall(vim.api.nvim_win_close, f_win, true)
    end

    if vim.api.nvim_buf_is_valid(f_buf) then
      pcall(vim.api.nvim_buf_delete, f_buf, { force = true })
    end

    pcall(vim.api.nvim_win_close, win, true)

    if type(on_close) == "function" then
      on_close()
    end
  end

  local map_opts = { buffer = buf, silent = true, nowait = true }
  vim.keymap.set("n", "r", ensure_and_run_test, map_opts)
  vim.keymap.set("n", "o", open_worktree_editor, map_opts)
  vim.keymap.set("n", "p", show_candidate_patches, map_opts)
  vim.keymap.set("n", "q", close_ui, map_opts)
  vim.keymap.set("n", "<Esc>", close_ui, map_opts)
  vim.keymap.set("n", "<C-c>", close_ui, map_opts)
  render()
  return win, f_win
end

return M
