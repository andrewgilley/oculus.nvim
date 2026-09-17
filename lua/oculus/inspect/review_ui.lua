-- The review threads of an inspected pull request as they appear in the
-- editor: the end-of-line labels, the thread float, the comments loaded into
-- the files themselves, thread navigation, and the sidebar counts. The threads
-- themselves, and where each one belongs, come from oculus.inspect.review.
local github = require("oculus.github")
local codeberg = require("oculus.codeberg")
local browser = require("oculus.browser")
local patch = require("oculus.inspect.patch")
local review = require("oculus.inspect.review")
local M = {}

function M.setup(inspect, internal)
  -- Pull request review threads: end-of-line labels on commented lines, a
  -- thread float, navigation between threads, sidebar counts and the overview's
  -- review sections.
  inspect._review = {
    ns = vim.api.nvim_create_namespace("oculus_inspect_review"),
    augroup = vim.api.nvim_create_augroup("oculus_inspect_review", { clear = true }),
    default_keys = {
      next = "]r",
      previous = "[r",
      open = "<leader>oc",
      chunk = "<C-r>",
    },
  }

  function inspect._review.set_review_highlights()
    vim.api.nvim_set_hl(0, "OculusInspectThread", {
      link = "DiagnosticInfo",
      default = true,
    })

    vim.api.nvim_set_hl(0, "OculusInspectThreadResolved", {
      link = "Comment",
      default = true,
    })

    vim.api.nvim_set_hl(0, "OculusInspectThreadHeader", {
      link = "Title",
      default = true,
    })

    vim.api.nvim_set_hl(0, "OculusInspectThreadBody", {
      link = "Comment",
      default = true,
    })

    vim.api.nvim_set_hl(0, "OculusInspectThreadGutter", {
      link = "LineNr",
      default = true,
    })
  end

  function inspect._review.display_rows(lines, width)
    local rows = 0

    for _, line in ipairs(lines) do
      rows = rows + math.max(1, math.ceil(vim.fn.strdisplaywidth(line) / width))
    end

    return rows
  end

  function inspect._review.close_float(endpoint)
    local float = endpoint and endpoint.review_float

    if not float then
      return
    end

    endpoint.review_float = nil

    for _, win in ipairs({ float.footer_win, float.win }) do
      if win and vim.api.nvim_win_is_valid(win) then
        pcall(vim.api.nvim_win_close, win, true)
      end
    end
  end

  -- The columns a window spends on its fold, sign and number columns.
  function inspect._review.gutter_width(win)
    if not win or not vim.api.nvim_win_is_valid(win) then
      return 0
    end

    local info = vim.fn.getwininfo(win)[1]
    return info and tonumber(info.textoff) or 0
  end

  -- The width available for inline thread text in a window.
  function inspect._review.inline_width(win)
    if not win or not vim.api.nvim_win_is_valid(win) then
      return 60
    end

    return math.max(
      20,
      vim.api.nvim_win_get_width(win)
        - inspect._review.gutter_width(win)
        - 4
    )
  end

  -- The line drawn down the number column beside inline thread text, so the
  -- comments stay tied to the code line they were written on.
  function inspect._review.inline_gutter(win, last)
    local width = inspect._review.gutter_width(win)

    if width < 1 then
      return nil
    end

    local glyph = last and "└" or "│"

    if width == 1 then
      return glyph
    end

    return string.rep(" ", width - 2) .. glyph .. " "
  end

  -- Threads are shown inline for the chunk a file is on, or for the whole file
  -- when it is not focused on one.
  function inspect._review.inline_key(session)
    return session.active_chunk or 0
  end

  -- Whether the view a file is showing has its threads inline: the workflow's
  -- own setting, unless this view was toggled on its own.
  function inspect._review.inline_state(group, session)
    local inline = group ~= nil and group.review_inline == true
    local overrides = session.review_inline_views

    if overrides then
      local override = overrides[inspect._review.inline_key(session)]

      if override ~= nil then
        inline = override
      end
    end

    return inline
  end

  function inspect._review.render_marks(session)
    local placed = session.review_threads or {}
    local group = internal.sidebar_group_for_session(session)
    local inline = inspect._review.inline_state(group, session)

    for _, role in ipairs({ "parent", "change" }) do
      local endpoint = session[role]

      if internal.valid_endpoint(endpoint) then
        vim.api.nvim_buf_clear_namespace(endpoint.buf, inspect._review.ns, 0, -1)
        inspect._review.close_float(endpoint)
        endpoint.review_lines = nil
        endpoint.review_inline_lines = nil
        local by_line = {}
        local line_count = vim.api.nvim_buf_line_count(endpoint.buf)

        for _, thread in ipairs(placed) do
          if thread.side == role then
            local line, chunk_index = review.display_line(
              session,
              role,
              thread.line
            )

            line = math.min(line, line_count)
            local entry = by_line[line]

            if not entry then
              entry = { threads = {}, chunk_index = chunk_index }
              by_line[line] = entry
            end

            entry.threads[#entry.threads + 1] = thread
          end
        end

        if next(by_line) then
          inspect._review.set_review_highlights()
          endpoint.review_lines = by_line
          local inline_lines = nil
          local width = inline and inspect._review.inline_width(endpoint.win) or 0

          for line, entry in pairs(by_line) do
            -- A thread the current view collapses onto a chunk start is not on
            -- the code it was written against, so it keeps the compact label.
            if inline and not entry.chunk_index then
              inline_lines = inline_lines or {}
              inline_lines[line] = true
              local virt_lines = review.inline_lines(entry.threads, width)

              local gutter_group = review.all_resolved(entry.threads)
                  and "OculusInspectThreadResolved"
                or "OculusInspectThreadGutter"

              for index, virt_line in ipairs(virt_lines) do
                local gutter = inspect._review.inline_gutter(
                  endpoint.win,
                  index == #virt_lines
                )

                if gutter then
                  table.insert(virt_line, 1, { gutter, gutter_group })
                end
              end

              vim.api.nvim_buf_set_extmark(endpoint.buf, inspect._review.ns, line - 1, 0, {
                virt_lines = virt_lines,
                virt_lines_leftcol = true,
                priority = 120,
              })
            else
              vim.api.nvim_buf_set_extmark(endpoint.buf, inspect._review.ns, line - 1, 0, {
                virt_text = {
                  {
                    "  " .. review.mark_text(entry.threads, entry.chunk_index),
                    review.all_resolved(entry.threads)
                        and "OculusInspectThreadResolved"
                      or "OculusInspectThread",
                  },
                },
                virt_text_pos = "eol",
                priority = 120,
              })
            end
          end

          endpoint.review_inline_lines = inline_lines
        end
      end
    end
  end

  -- The number of review threads placed in the inspected files.
  function inspect._review.thread_count(group)
    local count = 0

    for _, session in ipairs(group) do
      count = count + #(session.review_threads or {})
    end

    return count
  end

  -- Shows every thread's comments under the code they were written on, or goes
  -- back to the end-of-line labels. Files whose threads sit in other chunks are
  -- rendered whole while the threads are loaded, so each one lands on its own
  -- line; their chunk comes back when the threads are put away.
  function inspect._review.toggle_inline(group)
    if inspect._review.thread_count(group) == 0 then
      vim.notify(
        "Oculus: no review threads in this pull request",
        vim.log.levels.INFO
      )

      return false
    end

    group.review_inline = not group.review_inline

    for _, session in ipairs(group) do
      session.review_inline_views = nil

      if #(session.review_threads or {}) > 0 then
        local chunk = nil

        if group.review_inline then
          if session.focused_chunks then
            session.review_inline_chunk = session.active_chunk
            chunk = session.active_chunk
            internal.render_full_file(session)
          else
            inspect._review.render_marks(session)
          end
        else
          chunk = session.review_inline_chunk
          session.review_inline_chunk = nil

          -- Only put back the chunk this file was showing if it is still whole.
          if chunk
            and session.focused_chunks == false
            and session.hunks
            and session.hunks[chunk]
          then
            internal.render_focused_chunk(session, chunk)
          else
            chunk = nil
            inspect._review.render_marks(session)
          end
        end

        local hunk = chunk and session.hunks and session.hunks[chunk] or nil
        local endpoint = session.change

        if hunk and internal.valid_endpoint(endpoint) then
          local start = group.review_inline
              and hunk.new_start
            or session.focused_start
            or hunk.new_start

          internal.move_cursor_to_line_start(
            endpoint.win,
            start,
            internal.chunk_max_line_for_role(hunk, "change", start)
          )
        end
      end
    end

    internal.refresh_sidebar(group, vim.api.nvim_get_current_tabpage())
    inspect._refresh_virtual_counters(group)

    if internal.overview_window_is_open(group) then
      inspect._overview_ui.render(group)
    end

    return true
  end

  -- Shows or hides the comments of the threads on the chunk a file is showing,
  -- leaving the rest of the inspection as it is.
  function inspect._review.toggle_chunk_inline(group, session, role)
    local endpoint = session[role]

    if not internal.valid_endpoint(endpoint) then
      return false
    end

    if #(session.review_threads or {}) == 0 then
      vim.notify(
        "Oculus: no review threads in this file",
        vim.log.levels.INFO
      )

      return false
    end

    session.review_inline_views = session.review_inline_views or {}

    session.review_inline_views[inspect._review.inline_key(session)] =
      not inspect._review.inline_state(group, session)

    inspect._review.render_marks(session)
    inspect._review.on_cursor_moved(endpoint)
    return true
  end

  function inspect._review.review_float_thread(float)
    local line = vim.api.nvim_win_get_cursor(float.win)[1]
    local thread = float.entry.threads[1]

    for index, start in ipairs(float.starts) do
      if start <= line then
        thread = float.entry.threads[index]
      end
    end

    return thread
  end

  function inspect._review.render_review_float_footer(float)
    local width = vim.api.nvim_win_get_width(float.win)
    local height = vim.api.nvim_win_get_height(float.win)
    local buf = vim.api.nvim_create_buf(false, true)
    vim.bo[buf].buftype = "nofile"
    vim.bo[buf].bufhidden = "wipe"
    vim.bo[buf].swapfile = false

    local lines = {
      " " .. string.rep("─", math.max(1, width - 2)),
      " b browser   q close",
    }

    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.bo[buf].modifiable = false

    vim.api.nvim_buf_set_extmark(buf, inspect._review.ns, 0, 0, {
      end_col = #lines[1],
      hl_group = "Comment",
    })

    float.footer_win = vim.api.nvim_open_win(buf, false, {
      relative = "win",
      win = float.win,
      row = math.max(0, height - 2),
      col = 0,
      width = width,
      height = 2,
      style = "minimal",
      focusable = false,
      noautocmd = true,
      zindex = 81,
    })
  end

  function inspect._review.focus_review_float(endpoint, float)
    local lines = vim.deepcopy(float.lines)
    vim.list_extend(lines, { "", "" })
    vim.bo[float.buf].modifiable = true
    vim.api.nvim_buf_set_lines(float.buf, 0, -1, false, lines)
    vim.bo[float.buf].modifiable = false

    local height = math.max(
      3,
      math.min(
        inspect._review.display_rows(lines, float.width),
        vim.api.nvim_win_get_height(endpoint.win) - 2
      )
    )

    vim.api.nvim_win_set_config(float.win, {
      focusable = true,
      height = height,
    })

    inspect._review.render_review_float_footer(float)

    local function close()
      inspect._review.close_float(endpoint)

      if internal.valid_endpoint(endpoint) then
        vim.api.nvim_set_current_win(endpoint.win)
      end
    end

    local map_opts = { buffer = float.buf, nowait = true, silent = true }
    vim.keymap.set("n", "q", close, map_opts)
    vim.keymap.set("n", "<Esc>", close, map_opts)

    vim.keymap.set("n", "b", function()
      local thread = inspect._review.review_float_thread(float)

      if thread and thread.url then
        local ok, err = browser.open(thread.url, endpoint.browser_config or {})

        if not ok and err then
          vim.notify("Oculus: " .. tostring(err), vim.log.levels.ERROR)
        end
      end
    end, map_opts)

    vim.api.nvim_create_autocmd("WinLeave", {
      group = inspect._review.augroup,
      buffer = float.buf,
      once = true,
      callback = function()
        vim.schedule(function()
          if endpoint.review_float == float then
            inspect._review.close_float(endpoint)
          end
        end)
      end,
    })

    float.focused = true
    endpoint.review_float_focusing = true
    vim.api.nvim_set_current_win(float.win)
    endpoint.review_float_focusing = false
  end

  -- Shows the threads on a line of an inspected file below or above it, and
  -- optionally moves into the float to scroll it.
  function inspect._review.show_float(endpoint, line, focus)
    local entry = internal.valid_endpoint(endpoint)
      and endpoint.review_lines
      and endpoint.review_lines[line]

    if not entry then
      inspect._review.close_float(endpoint)
      return nil
    end

    local current = endpoint.review_float

    if current
      and current.line == line
      and vim.api.nvim_win_is_valid(current.win)
    then
      if focus and not current.focused then
        inspect._review.focus_review_float(endpoint, current)
      end

      return current
    end

    inspect._review.close_float(endpoint)

    -- An activity comment float points at the same comment; the thread replaces it.
    if endpoint.comment_win and vim.api.nvim_win_is_valid(endpoint.comment_win) then
      vim.api.nvim_win_close(endpoint.comment_win, true)
    end

    endpoint.comment_win = nil
    local lines, headers, starts = review.float_lines(entry.threads)
    local main_width = vim.api.nvim_win_get_width(endpoint.win)
    local main_height = vim.api.nvim_win_get_height(endpoint.win)
    local width = math.max(1, math.min(72, main_width - 4))

    local height = math.max(
      1,
      math.min(12, inspect._review.display_rows(lines, width), main_height - 2)
    )

    local buf = vim.api.nvim_create_buf(false, true)
    vim.bo[buf].buftype = "nofile"
    vim.bo[buf].bufhidden = "wipe"
    vim.bo[buf].swapfile = false
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.bo[buf].modifiable = false
    vim.bo[buf].filetype = "markdown"

    for _, header in ipairs(headers) do
      vim.api.nvim_buf_set_extmark(buf, inspect._review.ns, header, 0, {
        end_col = #lines[header + 1],
        hl_group = "OculusInspectThreadHeader",
        priority = 200,
      })
    end

    local screen_line = vim.api.nvim_win_call(endpoint.win, function()
      return vim.fn.winline()
    end)

    local above = screen_line - 1 >= height + 2
    local main_config = vim.api.nvim_win_get_config(endpoint.win)

    local win = vim.api.nvim_open_win(buf, false, {
      relative = "win",
      win = endpoint.win,
      anchor = above and "SW" or "NW",
      bufpos = { line - 1, 0 },
      row = above and 0 or 1,
      col = math.max(0, main_width - width - 2),
      width = width,
      height = height,
      style = "minimal",
      border = "rounded",
      focusable = false,
      noautocmd = true,
      zindex = math.max(80, (tonumber(main_config.zindex) or 0) + 1),
    })

    vim.wo[win].wrap = true
    vim.wo[win].linebreak = true
    vim.b[buf].oculus_inspect_review_thread = true

    endpoint.review_float = {
      win = win,
      buf = buf,
      line = line,
      entry = entry,
      lines = lines,
      starts = starts,
      width = width,
    }

    if focus then
      inspect._review.focus_review_float(endpoint, endpoint.review_float)
    end

    return endpoint.review_float
  end

  function inspect._review.on_cursor_moved(endpoint)
    if not endpoint.review_lines
      or not internal.valid_endpoint(endpoint)
      or vim.api.nvim_get_current_win() ~= endpoint.win
    then
      return
    end

    local line = vim.api.nvim_win_get_cursor(endpoint.win)[1]

    if endpoint.review_lines[line]
      and not (endpoint.review_inline_lines
        and endpoint.review_inline_lines[line])
    then
      inspect._review.show_float(endpoint, line)
    else
      inspect._review.close_float(endpoint)
    end
  end

  function inspect._review.focus_review_thread(group, session, thread)
    local role = thread.side
    local endpoint = session[role]

    if not internal.valid_endpoint(endpoint) then
      return
    end

    local ranges = session.excerpt and session.excerpt[role]
    local source = thread.line or 1

    if ranges then
      source = patch.excerpt_line(ranges, source)
    end

    local chunk_index = patch.revision_hunk_index_at_line(session, role, source)

    if chunk_index
      and not group.review_inline
      and (chunk_index ~= session.active_chunk or not session.focused_chunks)
    then
      internal.focus_inspection_chunk(group, session, role, chunk_index)
    else
      internal.select_endpoint(endpoint, session, role, group)
      internal.refresh_sidebar(group, endpoint.tab)
    end

    local line = math.min(
      review.display_line(session, role, thread.line),
      vim.api.nvim_buf_line_count(endpoint.buf)
    )

    internal.set_change_cursor(endpoint.win, line)

    if not (endpoint.review_inline_lines
      and endpoint.review_inline_lines[line])
    then
      inspect._review.show_float(endpoint, line)
    end
  end

  -- Moves to the next or previous review thread, continuing into the other
  -- inspected files in sidebar order.
  function inspect._review.jump(group, session, role, direction)
    local session_index

    for index, candidate in ipairs(group) do
      if candidate == session then
        session_index = index
      end
    end

    local endpoint = session[role]

    if not session_index or not internal.valid_endpoint(endpoint) then
      return
    end

    local cursor = vim.api.nvim_win_get_cursor(endpoint.win)[1]
    local current = {}

    for _, thread in ipairs(session.review_threads or {}) do
      local line = review.display_line(session, thread.side, thread.line)

      if thread.side ~= role then
        line = internal.map_inspection_line(session, thread.side, role, line)
      end

      current[#current + 1] = { line = line, thread = thread }
    end

    table.sort(current, function(a, b)
      if direction > 0 then
        return a.line < b.line
      end

      return a.line > b.line
    end)

    for _, entry in ipairs(current) do
      if (direction > 0 and entry.line > cursor)
        or (direction < 0 and entry.line < cursor)
      then
        inspect._review.focus_review_thread(group, session, entry.thread)
        return
      end
    end

    local count = #group

    for step = 1, count do
      local index = (session_index - 1 + direction * step) % count + 1
      local candidate = group[index]
      local threads = vim.list_slice(candidate.review_threads or {})

      if #threads > 0 and (candidate ~= session or #current > 0) then
        table.sort(threads, function(a, b)
          if direction > 0 then
            return (a.line or 0) < (b.line or 0)
          end

          return (a.line or 0) > (b.line or 0)
        end)

        inspect._review.focus_review_thread(group, candidate, threads[1])
        return
      end
    end

    vim.notify("Oculus: no review threads in this pull request", vim.log.levels.INFO)
  end

  function inspect._review.map_keys(endpoint, session, role, group)
    -- Only pull requests have review threads.
    if not internal.valid_endpoint(endpoint)
      or not group.overview
      or group.overview.kind ~= "pull_request"
    then
      return
    end

    local function map(lhs, default, callback, description)
      if lhs == nil then
        lhs = default
      end

      if type(lhs) == "string" and lhs ~= "" then
        vim.keymap.set("n", lhs, callback, {
          buffer = endpoint.buf,
          nowait = true,
          silent = true,
          desc = description,
        })
      end
    end

    map(group.next_thread, inspect._review.default_keys.next, function()
      inspect._review.jump(group, session, role, 1)
    end, "Next Oculus review thread")

    map(group.previous_thread, inspect._review.default_keys.previous, function()
      inspect._review.jump(group, session, role, -1)
    end, "Previous Oculus review thread")

    map(group.thread_open, inspect._review.default_keys.open, function()
      local line = vim.api.nvim_win_get_cursor(endpoint.win)[1]

      if not inspect._review.show_float(endpoint, line, true) then
        vim.notify("Oculus: no review thread on this line", vim.log.levels.INFO)
      end
    end, "Open Oculus review thread")

    map(group.chunk_threads, inspect._review.default_keys.chunk, function()
      inspect._review.toggle_chunk_inline(group, session, role)
    end, "Show Oculus review threads on this chunk")

    endpoint.browser_config = group.browser_config
    vim.api.nvim_clear_autocmds({ group = inspect._review.augroup, buffer = endpoint.buf })

    vim.api.nvim_create_autocmd("CursorMoved", {
      group = inspect._review.augroup,
      buffer = endpoint.buf,
      callback = function()
        inspect._review.on_cursor_moved(endpoint)
      end,
    })

    vim.api.nvim_create_autocmd("WinLeave", {
      group = inspect._review.augroup,
      buffer = endpoint.buf,
      callback = function()
        if not endpoint.review_float_focusing then
          inspect._review.close_float(endpoint)
        end
      end,
    })
  end

  function inspect._review.update_sidebar(group)
    if group.kind == "issue" or not group.sidebar_rows then
      return
    end

    local buf = group.sidebar_buf

    local rendered = buf
      and vim.api.nvim_buf_is_valid(buf)
      and group.sidebar_rendered_mode == "files"

    for index, session in ipairs(group) do
      local previous = group.sidebar_rows[index]

      if previous then
        local open, resolved = 0, 0

        for _, thread in ipairs(session.review_threads or {}) do
          if thread.resolved then
            resolved = resolved + 1
          else
            open = open + 1
          end
        end

        local label = open > 0 and ("◆" .. open)
          or resolved > 0 and ("✓" .. resolved)
          or nil

        local row = internal.sidebar_row(
          internal.sidebar_file(session.file),
          group.sidebar_width,
          session.sidebar_version,
          label
        )

        row.line_number = previous.line_number
        row.threads_resolved = open == 0
        group.sidebar_rows[index] = row
        group.sidebar_lines[row.line_number] = row.line

        if rendered then
          vim.bo[buf].modifiable = true

          vim.api.nvim_buf_set_lines(
            buf,
            row.line_number - 1,
            row.line_number,
            false,
            { row.line }
          )

          vim.bo[buf].modifiable = false
        end
      end
    end

    if rendered then
      internal.refresh_sidebar(group, vim.api.nvim_get_current_tabpage())
    end
  end

  function inspect._review.apply(group, info, result, err)
    if group.discarded then
      return
    end

    if not result then
      group.overview.review = { error = tostring(err or "unknown error") }
    else
      local unplaced = review.place(
        group,
        result.threads,
        info.commits,
        info.head_sha
      )

      group.overview.review = {
        reviews = result.reviews,
        checks = result.checks,
        threads = result.threads,
        unplaced = unplaced,
        requested_reviewers = info.requested_reviewers,
        mergeable = info.mergeable,
        mergeable_state = info.mergeable_state,
      }

      for _, session in ipairs(group) do
        inspect._review.render_marks(session)
      end

      inspect._review.update_sidebar(group)

      for _, session in ipairs(group) do
        for _, role in ipairs({ "parent", "change" }) do
          if internal.valid_endpoint(session[role]) then
            inspect._review.on_cursor_moved(session[role])
          end
        end
      end
    end

    if internal.overview_window_is_open(group) then
      inspect._overview_ui.render(group)
    end
  end

  function inspect._review.load(group, info, opts)
    if not info or info.kind ~= "pull_request" then
      return
    end

    local provider = info.forge == "codeberg" and codeberg or github

    provider.pull_request_review(
      info.owner .. "/" .. info.repo,
      info.number,
      info.head_sha,
      opts,
      function(result, err)
        inspect._review.apply(group, info, result, err)
      end
    )
  end

  return inspect._review
end

return M
