-- Browsing an inspection in oil.nvim: the changed-file markers in an oil
-- listing, the buffer-local mappings that open a changed file in the
-- inspection it belongs to, and the state that keeps an oil window tied to the
-- inspection it was opened from.
local M = {}

function M.setup(inspect, internal)
  local function oil_entry_status(session, role, path, directory)
    local comparable = path:gsub("\\", "/")

    if vim.uv.os_uname().sysname == "Windows_NT" then
      comparable = comparable:lower()
    end

    local prefix = comparable == "" and "" or (comparable .. "/")

    for _, change in ipairs(session.changes or {}) do
      local candidate = internal.change_path_for_role(change, role)

      if candidate then
        candidate = candidate:gsub("\\", "/")

        if vim.uv.os_uname().sysname == "Windows_NT" then
          candidate = candidate:lower()
        end

        if candidate == comparable then
          return change.status
        end

        if directory and candidate:sub(1, #prefix) == prefix then
          return "directory"
        end
      end
    end
  end

  local oil_change_marker = {
    sign = "•",
    highlight = "OculusOilChange",
  }

  local oil_status = {
    A = oil_change_marker,
    C = oil_change_marker,
    D = oil_change_marker,
    M = oil_change_marker,
    R = oil_change_marker,
    T = oil_change_marker,
    directory = oil_change_marker,
  }

  local function decorate_oil_buffer(buf)
    if not vim.api.nvim_buf_is_valid(buf) or vim.bo[buf].filetype ~= "oil" then
      return
    end

    local ok, oil = pcall(require, "oil")

    if not ok then
      return
    end

    local directory = oil.get_current_dir(buf)

    if not directory then
      return
    end

    local preferred_tab

    if vim.api.nvim_get_current_buf() == buf then
      preferred_tab = vim.api.nvim_get_current_tabpage()
    end

    local session, role, relative =
      internal.session_for_directory(directory, preferred_tab)

    vim.api.nvim_buf_clear_namespace(buf, internal.oil_ns, 0, -1)

    if not session then
      return
    end

    for line = 1, vim.api.nvim_buf_line_count(buf) do
      local entry = oil.get_entry_on_line(buf, line)

      if entry and entry.name and entry.name ~= ".." then
        local path = relative == ""
            and entry.name
          or (relative .. "/" .. entry.name)

        local status = oil_entry_status(
          session,
          role,
          path,
          entry.type == "directory"
        )

        local style = oil_status[status]

        if style then
          vim.api.nvim_buf_set_extmark(buf, internal.oil_ns, line - 1, 0, {
            sign_text = style.sign,
            sign_hl_group = style.highlight,
            priority = 50,
          })
        end
      end
    end

    for _, win in ipairs(vim.fn.win_findbuf(buf)) do
      vim.wo[win].signcolumn = "yes"
    end
  end

  local function matching_oil_entry_name(left, right)
    if vim.uv.os_uname().sysname == "Windows_NT" then
      return left:lower() == right:lower()
    end

    return left == right
  end

  local function invoke_oil_mapping(mapping)
    if type(mapping.callback) == "function" then
      mapping.callback()
    elseif type(mapping.rhs) == "string" and mapping.rhs ~= "" then
      vim.api.nvim_feedkeys(
        vim.api.nvim_replace_termcodes(
          mapping.rhs,
          true,
          false,
          true
        ),
        "m",
        false
      )
    end
  end

  -- The inspection in `context`'s group that loaded `name` in `directory`, on
  -- the side the Oil view was opened from unless the file only exists on the
  -- other side (added or deleted files).
  local function inspected_oil_file(context, directory, name)
    local _, _, relative = internal.session_directory(context.session, context.role, directory)

    if relative == nil then
      return
    end

    local path = internal.comparable_path(relative == "" and name or (relative .. "/" .. name))
    local group = context.group or internal.sidebar_group_for_session(context.session) or { context.session }
    local roles = context.role == "parent" and { "parent", "change" } or { "change", "parent" }

    for _, role in ipairs(roles) do
      for _, session in ipairs(group) do
        local file = internal.change_path_for_role({
          status = session.status,
          old_path = session.parent_file,
          new_path = session.change_file,
        }, role)

        if type(file) == "string" and internal.comparable_path(file) == path and internal.valid_endpoint(session[role]) then
          return session, role, group
        end
      end
    end
  end

  local function map_oil_origin_selection(buf, context, oil)
    for _, lhs in ipairs({ "l", "<CR>" }) do
      local original = vim.api.nvim_buf_call(buf, function()
        return vim.fn.maparg(lhs, "n", false, true)
      end)

      if original.buffer == 1
        and original.desc ~= "Select Oculus Inspect Oil entry"
      then
        vim.keymap.set("n", lhs, function()
          local entry = oil.get_cursor_entry()
          local directory = oil.get_current_dir()

          if entry
            and entry.type ~= "directory"
            and directory
            and internal.comparable_path(directory)
              == internal.comparable_path(context.directory)
            and matching_oil_entry_name(entry.name, context.filename)
          then
            oil.close()
            return
          end

          -- Without a local clone the files on disk are empty placeholders, so
          -- only an inspected file opens (in its inspection); any other file
          -- just closes Oil.
          if entry
            and entry.type ~= "directory"
            and directory
            and context.session
            and context.session.remote
          then
            local session, role, group = inspected_oil_file(context, directory, entry.name)
            oil.close()

            if session then
              vim.schedule(function()
                internal.select_endpoint(session[role], session, role, group)
              end)
            end

            return
          end

          invoke_oil_mapping(original)
        end, {
          buffer = buf,
          nowait = true,
          silent = true,
          desc = "Select Oculus Inspect Oil entry",
        })
      end
    end
  end

  local function focus_oil_origin(buf, context, oil)
    local wins = vim.fn.win_findbuf(buf)

    local win = vim.api.nvim_get_current_buf() == buf
        and vim.api.nvim_get_current_win()
      or wins[1]

    if not win or not vim.api.nvim_win_is_valid(win) then
      return
    end

    for line = 1, vim.api.nvim_buf_line_count(buf) do
      local entry = oil.get_entry_on_line(buf, line)

      if entry
        and matching_oil_entry_name(entry.name, context.filename)
      then
        vim.api.nvim_win_set_cursor(win, { line, 0 })
        return true
      end
    end
  end

  local function entered_oil_subdirectory(previous, current)
    if type(previous) ~= "string"
      or previous == ""
      or type(current) ~= "string"
      or current == ""
    then
      return false
    end

    previous = internal.comparable_path(previous)
    current = internal.comparable_path(current)

    return current ~= previous
      and current:sub(1, #previous + 1) == previous .. "/"
  end

  local function first_changed_oil_file_line(
    buf,
    session,
    role,
    relative,
    oil
  )
    local listing_ready = false

    for line = 1, vim.api.nvim_buf_line_count(buf) do
      local entry = oil.get_entry_on_line(buf, line)
      listing_ready = listing_ready or entry ~= nil

      if entry
        and entry.name
        and entry.name ~= ".."
        and entry.type ~= "directory"
      then
        local path = relative == ""
            and entry.name
          or (relative .. "/" .. entry.name)

        local status = oil_entry_status(session, role, path, false)

        if status and status ~= "directory" then
          return line, true
        end
      end
    end

    return nil, listing_ready
  end

  local function focus_first_changed_oil_file(
    buf,
    context,
    directory,
    oil
  )
    local session, role, relative = internal.session_directory(
      context.session,
      context.role,
      directory
    )

    if not session then
      return
    end

    local line, listing_ready = first_changed_oil_file_line(
      buf,
      session,
      role,
      relative,
      oil
    )

    if not line then
      return false, listing_ready
    end

    local wins = vim.fn.win_findbuf(buf)

    local win = vim.api.nvim_get_current_buf() == buf
        and vim.api.nvim_get_current_win()
      or wins[1]

    if not win or not vim.api.nvim_win_is_valid(win) then
      return false, listing_ready
    end

    vim.api.nvim_win_set_cursor(win, { line, 0 })
    return true, true
  end

  local function oil_context_for_window(win)
    local context = internal.oil_window_contexts[win]
    return context and context.active and context or nil
  end

  local function activate_oil_context(context)
    if context.active then
      return
    end

    context.active = true
    local group = context.group

    context.restore_sidebar =
      group and group.sidebar_visible == true or false

    if context.restore_sidebar and internal.close_inspection_sidebar then
      internal.close_inspection_sidebar(group)
    end
  end

  restore_inspection_sidebar_for_buffer = function(buf)
    for _, context in pairs(internal.oil_contexts) do
      if context.source_buf == buf and context.active then
        context.active = false
        internal.oil_window_contexts[context.win] = nil
        local group = context.group

        if context.restore_sidebar
          and group
          and not group.sidebar_visible
          and internal.open_inspection_sidebar
        then
          context.restore_sidebar = false
          local endpoint = context.session and context.session[context.role]
          internal.open_inspection_sidebar(group, endpoint and endpoint.tab or nil)
        end

        return
      end
    end
  end

  local function configure_inspection_oil_buffer(buf)
    if not vim.api.nvim_buf_is_valid(buf)
      or vim.bo[buf].filetype ~= "oil"
    then
      return
    end

    local ok, oil = pcall(require, "oil")

    if not ok then
      return
    end

    local directory = oil.get_current_dir(buf)

    if not directory then
      return
    end

    local wins = vim.fn.win_findbuf(buf)

    local win = vim.api.nvim_get_current_buf() == buf
        and vim.api.nvim_get_current_win()
      or wins[1]

    if not win or not vim.api.nvim_win_is_valid(win) then
      return
    end

    local context = internal.oil_contexts[buf] or oil_context_for_window(win)

    if context then
      internal.oil_contexts[buf] = context

      vim.b[buf].oculus_inspect_oil_origin = {
        directory = context.directory,
        filename = context.filename,
        source_buf = context.source_buf,
      }

      local descended = entered_oil_subdirectory(
        context.current_directory,
        directory
      )

      if descended then
        context.pending_changed_file_directory = directory
      elseif context.pending_changed_file_directory
        and internal.comparable_path(context.pending_changed_file_directory)
          ~= internal.comparable_path(directory)
      then
        context.pending_changed_file_directory = nil
      end

      context.current_directory = directory

      if context.win ~= win then
        internal.oil_window_contexts[context.win] = nil
      end

      context.win = win
      internal.oil_window_contexts[win] = context
      activate_oil_context(context)
      local focused_changed_file = false
      local listing_ready = false

      if context.pending_changed_file_directory
        and internal.comparable_path(context.pending_changed_file_directory)
          == internal.comparable_path(directory)
      then
        focused_changed_file, listing_ready =
          focus_first_changed_oil_file(
            buf,
            context,
            directory,
            oil
          )

        if focused_changed_file or listing_ready then
          context.pending_changed_file_directory = nil
        end
      end

      if not focused_changed_file
        and internal.comparable_path(directory)
          == internal.comparable_path(context.directory)
      then
        focus_oil_origin(buf, context, oil)
      end

      map_oil_origin_selection(buf, context, oil)
      return
    end

    local tab = vim.api.nvim_win_get_tabpage(win)
    local session, role = internal.session_for_directory(directory, tab)
    local endpoint = session and session[role] or nil

    if not endpoint or not vim.api.nvim_buf_is_valid(endpoint.buf) then
      return
    end

    local state = vim.b[endpoint.buf].oculus_inspect
    local source_path = type(state) == "table" and state.source_path or nil

    if type(source_path) ~= "string" or source_path == "" then
      return
    end

    local source_directory = vim.fs.dirname(source_path)

    if internal.comparable_path(directory) ~= internal.comparable_path(source_directory) then
      return
    end

    local context = {
      directory = source_directory,
      filename = vim.fs.basename(source_path),
      source_buf = endpoint.buf,
      session = session,
      role = role,
      current_directory = directory,
      win = win,
    }

    vim.b[buf].oculus_inspect_oil_origin = {
      directory = context.directory,
      filename = context.filename,
      source_buf = context.source_buf,
    }

    local group = internal.sidebar_group_for_session(session)
    context.group = group
    internal.oil_contexts[buf] = context
    activate_oil_context(context)
    internal.oil_window_contexts[win] = context
    focus_oil_origin(buf, context, oil)
    map_oil_origin_selection(buf, context, oil)
  end

  local function highlight_foreground(name, fallback)
    local ok, highlight = pcall(
      vim.api.nvim_get_hl,
      0,
      { name = name, link = false }
    )

    if ok and highlight.fg then
      return highlight.fg
    end

    return fallback
  end

  local function highlight_background(name)
    local ok, highlight = pcall(
      vim.api.nvim_get_hl,
      0,
      { name = name, link = false }
    )

    return ok and highlight.bg or nil
  end

  local function set_oil_highlights()
    local background = highlight_background("Normal")

    vim.api.nvim_set_hl(0, "OculusOilChange", {
      fg = highlight_foreground("WarningMsg", 0xfbd38d),
      bg = background,
      default = true,
    })
  end

  set_oil_highlights()

  vim.api.nvim_create_autocmd("ColorScheme", {
    group = internal.oil_group,
    callback = set_oil_highlights,
  })

  local function queue_oil_decorations(buf)
    vim.schedule(function()
      configure_inspection_oil_buffer(buf)
      decorate_oil_buffer(buf)
    end)
  end

  vim.api.nvim_create_autocmd("User", {
    group = internal.oil_group,
    pattern = "OilEnter",
    callback = function(args)
      local buf = args.data and args.data.buf or vim.api.nvim_get_current_buf()
      queue_oil_decorations(buf)
    end,
  })

  vim.api.nvim_create_autocmd({ "BufEnter", "WinEnter", "TextChanged" }, {
    group = internal.oil_group,
    pattern = "oil://*",
    callback = function(args)
      queue_oil_decorations(args.buf)
    end,
  })

  vim.api.nvim_create_autocmd("BufWipeout", {
    group = internal.oil_group,
    callback = function(args)
      internal.oil_contexts[args.buf] = nil

      for win, state in pairs(internal.rendered_treesitter_contexts) do
        if state.buf == args.buf then
          internal.rendered_treesitter_contexts[win] = nil
        end
      end
    end,
  })

  vim.api.nvim_create_autocmd("WinClosed", {
    group = internal.oil_group,
    callback = function(args)
      local win = tonumber(args.match)

      if win then
        internal.oil_window_contexts[win] = nil
        internal.rendered_treesitter_contexts[win] = nil
      end
    end,
  })

  return {
    entry_status = oil_entry_status,
    entered_subdirectory = entered_oil_subdirectory,
    first_changed_file_line = first_changed_oil_file_line,
  }
end

return M
