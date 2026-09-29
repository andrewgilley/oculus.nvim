-- The project boards linked to a project (GitHub Projects), listed like the
-- milestones: open boards first, the selected one described in the preview.
local github = require("oculus.github")
local codeberg = require("oculus.codeberg")
local M = {}

function M.setup(window, board_view, internal)
  local function date(timestamp)
    return type(timestamp) == "string"
        and timestamp:match("^(%d%d%d%d%-%d%d%-%d%d)")
      or nil
  end

  function board_view.preview_items(board, width)
    local updated = date(board.updated_at)

    local items = {
      [2] = { "PROJECT", "Title" },
      [4] = { board.title, "Identifier" },
      [5] = {
        (board.state == "closed" and "Closed" or "Open")
          .. (updated and (" · updated " .. updated) or ""),
        "Comment",
      },
      [6] = {
        ("%d item%s%s"):format(
          board.items or 0,
          board.items == 1 and "" or "s",
          board.owner and (" · @" .. board.owner) or ""
        ),
        "Comment",
      },
    }

    for index, line in ipairs(internal.wrapped_preview_text(board.description, width, 6)) do
      items[7 + index] = { line, "Comment" }
    end

    return items
  end

  function board_view.queue_preview(board)
    if window.state.view ~= "boards" or not board then
      return
    end

    local key = "board:" .. tostring(board.id)

    if window.state.preview_key == key then
      return
    end

    window.state.preview_key = key
    local window_width = vim.api.nvim_win_get_width(window.state.win)
    local left_width = internal.preview_left_width(window_width)
    local preview_width = math.max(15, window_width - left_width - 5)
    internal.render_preview_panel(board_view.preview_items(board, preview_width), { offset = 3 })
  end

  function board_view.selected_index(boards)
    for index, board in ipairs(boards or {}) do
      if board.id == window.state.selected_board then
        return index
      end
    end

    return boards and boards[1] and 1 or nil
  end

  function board_view.render()
    local list = window.state.project_boards

    if not list or not internal.is_valid_win(window.state.win) then
      return
    end

    internal.stop_activity_page_loading()
    internal.close_activity_footer()
    window.state.view = "boards"
    window.state.line_targets = {}
    window.state.preview_key = nil
    local project = list.project
    local window_width = vim.api.nvim_win_get_width(window.state.win)
    local left_width = internal.preview_left_width(window_width)
    local window_height = vim.api.nvim_win_get_height(window.state.win)
    local sidebar_visible = internal.is_sidebar_visible()
    local tab_text, tab_ranges = internal.project_tab_line("boards", window_width - 2)

    local lines = {
      "",
      ("  %s · %s"):format(internal.project_title(project), internal.provider_name(project)),
      tab_text,
      "",
    }

    local headings = {}
    local comment_lines = {}
    local error_line
    local boards = list.boards or {}

    if list.loading and not list.boards then
      lines[#lines + 1] = "  Loading projects…"
      comment_lines[#comment_lines + 1] = #lines
    elseif list.error then
      lines[#lines + 1] = "  Could not load projects"
      error_line = #lines

      for _, line in ipairs(internal.wrapped_preview_text(list.error, left_width - 4, 4)) do
        lines[#lines + 1] = "  " .. line
        comment_lines[#comment_lines + 1] = #lines
      end
    elseif list.unsupported then
      lines[#lines + 1] = "  " .. list.unsupported
      comment_lines[#comment_lines + 1] = #lines
    elseif #boards == 0 then
      lines[#lines + 1] = "  No projects are linked to this repository."
      comment_lines[#comment_lines + 1] = #lines
    else
      local rows = {}
      local counts = { open = 0, closed = 0 }

      for _, board in ipairs(boards) do
        counts[board.state] = counts[board.state] + 1
      end

      for _, section in ipairs({
        { state = "open", heading = "OPEN" },
        { state = "closed", heading = "CLOSED" },
      }) do
        if counts[section.state] > 0 then
          if #rows > 0 then
            rows[#rows + 1] = { kind = "blank" }
          end

          rows[#rows + 1] = {
            kind = "heading",
            text = ("%s (%d)"):format(section.heading, counts[section.state]),
          }

          for _, board in ipairs(boards) do
            if board.state == section.state then
              rows[#rows + 1] = { kind = "board", board = board }
            end
          end
        end
      end

      local selected = boards[board_view.selected_index(boards)]
      window.state.selected_board = selected.id
      local selected_row = 1

      for index, row in ipairs(rows) do
        if row.board == selected then
          selected_row = index
          break
        end
      end

      local capacity = math.max(
        3,
        window_height - #lines - (sidebar_visible and 0 or 2)
      )

      local offset = math.min(
        math.max(1, window.state.board_offset or 1),
        math.max(1, #rows - capacity + 1)
      )

      if selected_row < offset then
        offset = selected_row
      elseif selected_row >= offset + capacity then
        offset = selected_row - capacity + 1
      end

      if offset > 1
        and offset == selected_row
        and rows[offset - 1].kind == "heading"
      then
        offset = offset - 1
      end

      window.state.board_offset = offset

      for index = offset, math.min(#rows, offset + capacity - 1) do
        local row = rows[index]

        if row.kind == "blank" then
          lines[#lines + 1] = ""
        elseif row.kind == "heading" then
          lines[#lines + 1] = "  " .. row.text
          headings[#headings + 1] = #lines
        else
          lines[#lines + 1] = internal.pad_cell(
            "  " .. internal.trim_to_width(row.board.title, left_width - 3),
            left_width
          )

          window.state.line_targets[#lines] = {
            kind = "board",
            board = row.board,
          }
        end
      end
    end

    local commands_line = internal.footer(lines, left_width)
    internal.set_lines(lines)
    internal.paint_footer(commands_line)
    vim.wo[window.state.win].cursorline = false
    internal.paint_project_header(lines[2], tab_ranges)

    for _, line in ipairs(headings) do
      internal.highlight(line, 2, -1, "OculusSectionTitle")
    end

    for _, line in ipairs(comment_lines) do
      internal.highlight(line, 2, -1, "Comment")
    end

    if error_line then
      internal.highlight(error_line, 2, -1, "DiagnosticError")
    end

    local selected_line

    for line, target in pairs(window.state.line_targets) do
      internal.highlight(line, 2, -1, "Identifier")

      if target.board.id == window.state.selected_board then
        selected_line = line
      end
    end

    if selected_line then
      vim.api.nvim_win_set_cursor(window.state.win, { selected_line, 0 })
      board_view.queue_preview(window.state.line_targets[selected_line].board)
    else
      internal.render_preview_panel({ [2] = { "PROJECT", "Title" } }, { offset = 3 })
    end

    internal.update_contributor_selection()
    internal.render_sidebar()
  end

  function board_view.select_adjacent(direction)
    local list = window.state.project_boards
    local boards = list and list.boards or {}
    local index = board_view.selected_index(boards)

    if not index then
      return
    end

    index = ((index - 1 + direction) % #boards) + 1
    window.state.selected_board = boards[index].id
    board_view.render()
  end

  function board_view.load(project, force)
    window.state.request_id = window.state.request_id + 1
    local request_id = window.state.request_id
    local key = internal.project_issue_filter_key(project)
    local previous = window.state.project_boards
    local same = previous and previous.key == key

    if not same then
      window.state.selected_board = nil
      window.state.board_offset = 1
    end

    window.state.project_boards = {
      key = key,
      project = project,
      loading = true,
      boards = same and previous.boards or nil,
    }

    board_view.render()
    local provider = project.provider == "codeberg" and codeberg or github

    if type(provider.repository_projects) ~= "function" then
      window.state.project_boards.loading = false

      window.state.project_boards.unsupported = internal.provider_name(project)
        .. " does not list project boards."

      board_view.render()
      return
    end

    local request_opts = vim.tbl_extend(
      "force",
      window.state.opts,
      { force = force or false }
    )

    provider.repository_projects(project.repository, request_opts, function(boards, err)
      if request_id ~= window.state.request_id
        or window.state.view ~= "boards"
        or not internal.is_valid_win(window.state.win)
      then
        return
      end

      window.state.project_boards = {
        key = key,
        project = project,
        loading = false,
        error = err and tostring(err) or nil,
        boards = boards or {},
      }

      board_view.render()
    end)
  end
end

return M
